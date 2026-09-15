import SwiftUI
import AppKit

// MARK: - Waveform cache

/// In-memory waveform cache keyed by URL, with in-flight de-duplication so a
/// re-selected row never recomputes (or double-computes) its peaks.
@MainActor
enum WaveformStore {
    private static var cache: [URL: WaveformData] = [:]
    private static var inflight: [URL: Task<WaveformData, Error>] = [:]

    static func cached(_ url: URL) -> WaveformData? { cache[url] }

    static func data(for url: URL) async throws -> WaveformData {
        if let hit = cache[url] { return hit }
        // The load task caches its own result, so a caller being cancelled
        // (selection toggled mid-compute) never discards finished work.
        let task: Task<WaveformData, Error>
        if let pending = inflight[url] {
            task = pending
        } else {
            task = Task {
                let data = try await WaveformLoader.load(url)
                await MainActor.run {
                    cache[url] = data
                    inflight[url] = nil
                }
                return data
            }
            inflight[url] = task
        }
        return try await task.value
    }
}

/// Unsaved cue edits survive selection changes: one editor per file, kept
/// until its edits are saved or reverted.
@MainActor
enum CueEditorStore {
    private static var editors: [URL: CueEditor] = [:]

    static func editor(for url: URL) async -> CueEditor {
        if let existing = editors[url] { return existing }
        let editor = CueEditor(fileURL: url)
        await editor.load()
        editors[url] = editor
        return editor
    }
}

// MARK: - Time formatting

/// "0:04.2" — minutes, zero-padded seconds, tenths.
func timecode(_ time: TimeInterval) -> String {
    let clamped = max(0, time)
    let minutes = Int(clamped) / 60
    let seconds = clamped - Double(minutes * 60)
    return String(format: "%d:%04.1f", minutes, seconds)
}

// MARK: - Detail panel

/// Bottom pane shown for the selected item in any tab: stacked mirrored
/// waveform lanes, in-app transport, click-to-seek, zoom + pan, and keyboard
/// cue editing with an explicit save-to-device flow.
struct SoundDetailView: View {
    let item: InboxItem

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var waveform: WaveformData?
    @State private var reveal: CGFloat = 0
    @State private var cueEditor: CueEditor?
    @State private var queuedForDevice = false

    // Cue interaction
    @State private var selectedCueID: UInt32?
    @State private var draggingCue = false
    @State private var dragOrigin: TimeInterval?
    @State private var unsavedEdits = 0
    @State private var snapToPeak = UserDefaults.standard.bool(forKey: "snapCuesToPeak")

    // Zoom / pan (1×–16×, window anchored on the playhead)
    @State private var zoom: CGFloat = 1
    @State private var viewStart: TimeInterval = 0
    @State private var magnifyBase: CGFloat?
    @State private var panOrigin: TimeInterval?

    @FocusState private var paneFocused: Bool

    private var isCurrent: Bool { model.player.currentURL == item.audioURL }
    private var isPlayingThis: Bool { isCurrent && model.player.isPlaying }
    private var duration: TimeInterval {
        if let waveform, waveform.duration > 0 { return waveform.duration }
        return isCurrent ? model.player.duration : 0
    }
    private var laneCount: Int { max(1, waveform?.lanes.count ?? 1) }
    private var waveformHeight: CGFloat { laneCount == 1 ? 56 : CGFloat(laneCount) * 34 }

    private var visibleDuration: TimeInterval { duration / Double(zoom) }
    private var visibleStart: TimeInterval {
        min(max(0, viewStart), max(0, duration - visibleDuration))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlayingThis)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                header
                waveformArea
                if let transcript = item.transcript, !transcript.isEmpty {
                    Text(transcript)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .focusable(true, interactions: .edit)
        .focusEffectDisabled()
        .focused($paneFocused)
        .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
        .task(id: item.audioURL) { await loadSound() }
        .onChange(of: selectedCueID) { _, newValue in
            CueCommandRelay.shared.hasCueSelection = newValue != nil
        }
        .onAppear {
            registerRelay()
        }
        .onDisappear {
            CueCommandRelay.shared.detach()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.player.toggle(item.audioURL)
            } label: {
                Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
            }
            .buttonStyle(HoverIconButtonStyle())
            .help(isPlayingThis ? "Pause (space)" : "Play (space)")

            Text("\(timecode(isCurrent ? model.player.currentTime : 0)) / \(timecode(duration))")
                .font(.system(size: 11))
                .monospaced()
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if zoom > 1 {
                Text("\(Int(zoom))×")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(TE.orange)
                    .help("Waveform zoom (⌘+ / ⌘− / ⌘0, pinch)")
            }

            if let title = item.title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            } else {
                Text(item.originalName)
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if cueEditor?.isEditable == true {
                Button(snapToPeak ? "snap: peak" : "snap: off") {
                    snapToPeak.toggle()
                    UserDefaults.standard.set(snapToPeak, forKey: "snapCuesToPeak")
                }
                .buttonStyle(HairlineButtonStyle())
                .help("Snap dragged and added cues to the nearest waveform peak (±60ms)")
            }

            if let editor = cueEditor, editor.isEditable, !editor.markers.isEmpty, !editor.dirty {
                Text(cueLabel(count: editor.markers.count))
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.tertiary)
            }

            if let editor = cueEditor, editor.canUndo {
                Button("undo") { undoEdit() }
                    .buttonStyle(HairlineButtonStyle())
                    .help("Undo the last cue edit (⌘Z)")
            }

            if let editor = cueEditor, editor.dirty {
                Text("\(unsavedEdits) unsaved cue edit\(unsavedEdits == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(TE.orange)
                Button("save cues") { requestSave() }
                    .buttonStyle(HairlineButtonStyle())
                    .help("Write cue markers to the file and queue a device push (⌘S)")
                Button("revert") { revertEdits() }
                    .buttonStyle(HairlineButtonStyle())
                    .help("Discard unsaved cue edits")
            }
        }
    }

    private func cueLabel(count: Int) -> String {
        let base = "\(count) cue\(count == 1 ? "" : "s")"
        return queuedForDevice ? base + " · queued for device" : base
    }

    // MARK: Waveform

    private var waveformArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWaveform(context, size: size)
                }
                .mask(alignment: .leading) {
                    Rectangle().frame(width: geo.size.width * reveal)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard duration > 0 else { return }
                    paneFocused = true
                    seek(to: seconds(at: location.x, width: geo.size.width))
                }
                .gesture(panGesture(width: geo.size.width))
                .simultaneousGesture(magnifyGesture)

                if let editor = cueEditor, editor.isEditable, duration > 0 {
                    ForEach(visibleMarkers(editor)) { marker in
                        cueTick(marker: marker, height: geo.size.height)
                            .position(
                                // Clamp inside the clip so a cue at 0:00 (or the
                                // very end) stays visible instead of half-drawn.
                                x: min(max(xPosition(for: marker.seconds, width: geo.size.width), 3),
                                       geo.size.width - 3),
                                y: geo.size.height / 2
                            )
                            .gesture(cueDrag(for: marker, editor: editor, width: geo.size.width))
                    }
                }
            }
            .clipped()
        }
        .frame(height: waveformHeight)
        .overlay(alignment: .bottom) {
            if zoom > 1.01 {
                zoomOverview
                    .padding(.horizontal, 1)
                    .padding(.bottom, 2)
            }
        }
    }

    /// DAW-style overview strip: the whole file as a track, with the visible
    /// window highlighted. Drag it to pan; it exists only while zoomed.
    private var zoomOverview: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let windowStart = duration > 0 ? CGFloat(visibleStart / duration) * width : 0
            let windowWidth = max(10, duration > 0 ? CGFloat(visibleDuration / duration) * width : width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(TE.orange.opacity(0.55))
                    .frame(width: windowWidth)
                    .offset(x: min(windowStart, width - windowWidth))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let fraction = Double(value.location.x / width)
                        viewStart = min(
                            max(0, fraction * duration - visibleDuration / 2),
                            max(0, duration - visibleDuration)
                        )
                    }
            )
            .overlay(alignment: .trailing) {
                Text("\(zoom, format: .number.precision(.fractionLength(0)))× · ⌘0 resets")
                    .font(.system(size: 9))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                    .offset(y: -12)
            }
        }
        .frame(height: 6)
        .help("Zoomed view. The orange window is what you're seeing; drag to pan, ⌘0 to reset.")
    }

    private func visibleMarkers(_ editor: CueEditor) -> [CueMarker] {
        let start = visibleStart
        let end = start + visibleDuration
        return editor.markers.filter { $0.seconds >= start - 0.01 && $0.seconds <= end + 0.01 }
    }

    private func cueTick(marker: CueMarker, height: CGFloat) -> some View {
        let selected = marker.id == selectedCueID
        return VStack(spacing: 0) {
            Circle()
                .fill(TE.orange)
                .frame(width: selected ? 6 : 5, height: selected ? 6 : 5)
            Rectangle()
                .fill(TE.orange)
                .frame(width: selected ? 2 : 1.5)
                .frame(maxHeight: .infinity)
        }
        .opacity(selected ? 1 : 0.62)
        .frame(width: 12, height: selected ? height : height * 0.82)
        .overlay(alignment: .topLeading) {
            if selected {
                Text(timecode(marker.seconds))
                    .font(.system(size: 9, weight: .semibold))
                    .monospaced()
                    .foregroundStyle(TE.orange)
                    .fixedSize()
                    .offset(x: 10, y: -1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onTapGesture {
            selectedCueID = marker.id
            paneFocused = true
        }
    }

    private func cueDrag(for marker: CueMarker, editor: CueEditor, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !draggingCue {
                    editor.beginMove()
                    draggingCue = true
                    dragOrigin = marker.seconds
                    selectedCueID = marker.id
                    paneFocused = true
                }
                // ⌘ = fine mode: 0.1× drag sensitivity, from the drag origin.
                let sensitivity: CGFloat = NSEvent.modifierFlags.contains(.command) ? 0.1 : 1
                let deltaSeconds = Double(value.translation.width * sensitivity / width) * visibleDuration
                editor.move(id: marker.id, to: clampTime((dragOrigin ?? marker.seconds) + deltaSeconds))
            }
            .onEnded { _ in
                draggingCue = false
                dragOrigin = nil
                if snapToPeak,
                   let current = editor.markers.first(where: { $0.id == marker.id }),
                   let snapped = snapTime(near: current.seconds) {
                    editor.move(id: marker.id, to: snapped)
                }
                unsavedEdits += 1
            }
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard zoom > 1, duration > 0, width > 0 else { return }
                if panOrigin == nil { panOrigin = visibleStart }
                let deltaSeconds = Double(value.translation.width / width) * visibleDuration
                viewStart = min(max(0, (panOrigin ?? 0) - deltaSeconds), max(0, duration - visibleDuration))
            }
            .onEnded { _ in panOrigin = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBase == nil { magnifyBase = zoom }
                setZoom((magnifyBase ?? 1) * value.magnification)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    /// Zooms while keeping the playhead (or, when nothing is playing, the
    /// window centre) at the same on-screen position.
    private func setZoom(_ requested: CGFloat) {
        let clamped = min(16, max(1, requested))
        guard duration > 0 else { zoom = clamped; return }
        let oldVisible = duration / Double(zoom)
        let newVisible = duration / Double(clamped)
        let anchor = isCurrent ? model.player.currentTime : visibleStart + oldVisible / 2
        let fraction = oldVisible > 0
            ? min(max((anchor - visibleStart) / oldVisible, 0), 1) : 0.5
        zoom = clamped
        viewStart = min(max(0, anchor - newVisible * fraction), max(0, duration - newVisible))
    }

    private func xPosition(for seconds: TimeInterval, width: CGFloat) -> CGFloat {
        guard visibleDuration > 0 else { return 0 }
        return CGFloat((seconds - visibleStart) / visibleDuration) * width
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return visibleStart + Double(max(0, min(x, width)) / width) * visibleDuration
    }

    private func clampTime(_ time: TimeInterval) -> TimeInterval {
        min(max(0, time), duration > 0 ? duration : time)
    }

    /// Nearest local peak in the cached bucket data within ±60ms, or nil.
    private func snapTime(near seconds: TimeInterval) -> TimeInterval? {
        guard let peaks = waveform?.lanes.first, !peaks.isEmpty, duration > 0 else { return nil }
        let bucketDuration = duration / Double(peaks.count)
        let window = 0.06
        let low = max(0, Int((seconds - window) / bucketDuration))
        let high = min(peaks.count - 1, Int((seconds + window) / bucketDuration))
        guard low <= high else { return nil }
        var bestIndex = low
        var best: Float = -1
        for index in low...high where peaks[index] > best {
            best = peaks[index]
            bestIndex = index
        }
        return (Double(bestIndex) + 0.5) * bucketDuration
    }

    private func seek(to time: TimeInterval) {
        if !isCurrent { model.player.play(item.audioURL) }
        model.player.seek(to: time)
    }

    private func drawWaveform(_ context: GraphicsContext, size: CGSize) {
        let lanes = waveform?.lanes ?? []
        let count = max(1, lanes.count)
        let laneHeight = size.height / CGFloat(count)
        let visStart = visibleStart
        let visDuration = visibleDuration
        let playedX: CGFloat = (isCurrent && visDuration > 0)
            ? CGFloat((model.player.currentTime - visStart) / visDuration) * size.width
            : 0

        let barWidth: CGFloat = 2
        let gap: CGFloat = 1
        let barCount = max(1, Int(size.width / (barWidth + gap)))

        for laneIndex in 0..<count {
            let midY = laneHeight * (CGFloat(laneIndex) + 0.5)
            context.fill(
                Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
                with: .color(TE.hairline)
            )
            guard laneIndex < lanes.count else { continue }
            let peaks = lanes[laneIndex]
            guard !peaks.isEmpty, duration > 0 else { continue }

            // Slice the cached buckets down to the visible window — never
            // recompute audio for zoom.
            let sliceStart = min(peaks.count - 1, max(0, Int(Double(peaks.count) * visStart / duration)))
            let sliceEnd = min(
                peaks.count,
                max(sliceStart + 1, Int((Double(peaks.count) * (visStart + visDuration) / duration).rounded(.up)))
            )
            let sliceCount = sliceEnd - sliceStart

            for bar in 0..<barCount {
                let start = sliceStart + sliceCount * bar / barCount
                let end = max(start + 1, sliceStart + sliceCount * (bar + 1) / barCount)
                var peak: Float = 0
                for index in start..<min(end, sliceEnd) {
                    peak = max(peak, peaks[index])
                }
                let barHeight = max(1.5, CGFloat(peak) * (laneHeight - 6))
                let x = CGFloat(bar) * (barWidth + gap)
                let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                let played = isCurrent && x + barWidth <= playedX
                // Progress is brightness, never hue: orange belongs to cues alone.
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(Color.primary.opacity(played ? 0.92 : 0.3))
                )
            }
        }

        if isCurrent, model.player.currentTime > 0, playedX >= 0, playedX <= size.width {
            context.fill(
                Path(CGRect(x: playedX - 0.5, y: 0, width: 1, height: size.height)),
                with: .color(Color.primary.opacity(0.65))
            )
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let editor = cueEditor else { return .ignored }
        let mods = press.modifiers

        // Space rule: if anything is playing, pause it, full stop — never
        // switch songs. Only when paused does space play the selection
        // (from its selected cue when one exists).
        if press.key == .space {
            if model.player.isPlaying, let playingURL = model.player.currentURL {
                model.player.toggle(playingURL)
            } else if let id = selectedCueID,
                      let marker = editor.markers.first(where: { $0.id == id }) {
                seek(to: marker.seconds)
            } else {
                model.player.toggle(item.audioURL)
            }
            return .handled
        }

        if mods.contains(.command) {
            // ⌘= as an alias for zoom in (the menu owns ⌘+/⌘−/⌘0).
            if press.characters == "=" { setZoom(zoom * 2); return .handled }
            return .ignored
        }
        if mods.contains(.option) || mods.contains(.control) { return .ignored }

        switch press.key {
        case .leftArrow:
            return nudgeSelected(back: true, coarse: mods.contains(.shift)) ? .handled : .ignored
        case .rightArrow:
            return nudgeSelected(back: false, coarse: mods.contains(.shift)) ? .handled : .ignored
        default:
            break
        }

        // Key repeat only makes sense for held-arrow nudging.
        guard press.phase != .repeat else { return .ignored }

        switch press.key {
        case .escape:
            guard selectedCueID != nil else { return .ignored }
            selectedCueID = nil
            return .handled
        case .return:
            seek(to: 0)
            return .handled
        default:
            break
        }

        // , and . jump the playhead between cues — the listening controls,
        // as opposed to Tab which selects for editing.
        if press.characters == "," || press.characters == "." {
            jumpCue(forward: press.characters == ".")
            return .handled
        }

        if !mods.contains(.shift),
           press.characters.count == 1,
           let digit = press.characters.first?.wholeNumberValue,
           (1...9).contains(digit) {
            let sorted = editor.markers.sorted { $0.seconds < $1.seconds }
            guard digit <= sorted.count else { return .handled }
            selectedCueID = sorted[digit - 1].id
            seek(to: sorted[digit - 1].seconds)
            return .handled
        }

        let stroke = KeyStroke(character: normalizedCharacter(press), shift: mods.contains(.shift))
        let bindings = KeyBindings.shared
        if stroke == bindings.stroke(for: .addCue) { addCueAtPlayhead(); return .handled }
        if stroke == bindings.stroke(for: .deleteCue) { deleteSelectedCue(); return .handled }
        if stroke == bindings.stroke(for: .nextCue) { selectAdjacentCue(1); return .handled }
        if stroke == bindings.stroke(for: .prevCue) { selectAdjacentCue(-1); return .handled }
        return .ignored
    }

    private func normalizedCharacter(_ press: KeyPress) -> String {
        switch press.key {
        case .tab: return "\t"
        case .delete, .deleteForward: return "\u{7F}"
        case .return: return "\r"
        default:
            let chars = press.characters.lowercased()
            if chars == "\u{8}" { return "\u{7F}" }
            // Shift-Tab arrives as the legacy backtab character, not tab+shift.
            if chars == "\u{19}" { return "\t" }
            return chars.isEmpty ? String(press.key.character).lowercased() : chars
        }
    }

    // MARK: Cue editing actions

    private func addCueAtPlayhead() {
        guard let editor = cueEditor, editor.isEditable else { return }
        var time = clampTime(isCurrent ? model.player.currentTime : 0)
        if snapToPeak, let snapped = snapTime(near: time) { time = snapped }
        let marker = editor.add(at: time)
        selectedCueID = marker.id
        unsavedEdits += 1
    }

    private func deleteSelectedCue() {
        guard let editor = cueEditor, let id = selectedCueID else { return }
        let sorted = editor.markers.sorted { $0.seconds < $1.seconds }
        let index = sorted.firstIndex { $0.id == id }
        editor.delete(id: id)
        let remaining = editor.markers.sorted { $0.seconds < $1.seconds }
        if let index, !remaining.isEmpty {
            selectedCueID = remaining[min(index, remaining.count - 1)].id
        } else {
            selectedCueID = nil
        }
        unsavedEdits += 1
    }

    /// Timeline navigation, DAW-style: "back" first restarts the cue the
    /// playhead is inside (with a short grace window), pressed again goes to
    /// the one before. No wraparound surprises mid-listen.
    private func jumpCue(forward: Bool) {
        guard let editor = cueEditor else { return }
        let sorted = editor.markers.sorted { $0.seconds < $1.seconds }
        guard !sorted.isEmpty else { return }
        let now = isCurrent ? model.player.currentTime : visibleStart
        let target: CueMarker? = forward
            ? (sorted.first { $0.seconds > now + 0.05 } ?? sorted.first)
            : (sorted.last { $0.seconds < now - 0.5 } ?? sorted.last)
        if let target {
            selectedCueID = target.id
            seek(to: target.seconds)
        }
    }

    private func selectAdjacentCue(_ step: Int) {
        // While listening, tab navigates the timeline like , and . do —
        // selection-ring cycling is an editing behaviour for when paused.
        if isPlayingThis {
            jumpCue(forward: step > 0)
            return
        }
        guard let editor = cueEditor, !editor.markers.isEmpty else { return }
        let sorted = editor.markers.sorted { $0.seconds < $1.seconds }
        if let id = selectedCueID, let index = sorted.firstIndex(where: { $0.id == id }) {
            selectedCueID = sorted[(index + step + sorted.count) % sorted.count].id
        } else {
            selectedCueID = step > 0 ? sorted.first?.id : sorted.last?.id
        }
    }

    /// One key press = one undo step: snapshot, then a single move.
    private func nudgeSelected(back: Bool, coarse: Bool) -> Bool {
        guard let editor = cueEditor, let id = selectedCueID,
              let marker = editor.markers.first(where: { $0.id == id }) else { return false }
        let ms = coarse ? model.nudgeCoarseMs : model.nudgeFineMs
        let delta = Double(ms) / 1000 * (back ? -1 : 1)
        editor.beginMove()
        editor.move(id: id, to: clampTime(marker.seconds + delta))
        unsavedEdits += 1
        return true
    }

    private func undoEdit() {
        guard let editor = cueEditor, editor.canUndo else { return }
        editor.undo()
        unsavedEdits += 1
        sanitizeSelection()
    }

    private func revertEdits() {
        cueEditor?.revert()
        unsavedEdits = 0
        sanitizeSelection()
    }

    private func sanitizeSelection() {
        guard let editor = cueEditor else { selectedCueID = nil; return }
        if let id = selectedCueID, !editor.markers.contains(where: { $0.id == id }) {
            selectedCueID = nil
        }
    }

    // MARK: Save flow

    /// Explicit save: confirm once (with a "Don't ask again" suppression
    /// button), then write the file and queue the device push.
    private func requestSave() {
        guard let editor = cueEditor, editor.dirty else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "suppressCueWriteWarning") {
            let alert = NSAlert()
            alert.messageText = "Write cues to the TP-7?"
            alert.informativeText = "Saving updates this file's cue markers on the device at the next sync. Audio is never modified."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                defaults.set(true, forKey: "suppressCueWriteWarning")
            }
        }
        if editor.save() {
            model.queueDevicePush(for: item)
            queuedForDevice = true
            unsavedEdits = 0
        }
    }

    // MARK: Menu relay

    private func registerRelay() {
        let relay = CueCommandRelay.shared
        relay.hasSound = true
        relay.hasCueSelection = selectedCueID != nil
        relay.editor = cueEditor
        relay.handler = { command in handleCommand(command) }
    }

    private func handleCommand(_ command: CueCommand) {
        switch command {
        case .playPause: model.player.toggle(item.audioURL)
        case .addCue: addCueAtPlayhead()
        case .deleteCue: deleteSelectedCue()
        case .nextCue: selectAdjacentCue(1)
        case .prevCue: selectAdjacentCue(-1)
        case .nudgeEarlier: _ = nudgeSelected(back: true, coarse: false)
        case .nudgeLater: _ = nudgeSelected(back: false, coarse: false)
        case .saveCues: requestSave()
        case .undo: undoEdit()
        case .jumpToStart: seek(to: 0)
        case .zoomIn: setZoom(zoom * 2)
        case .zoomOut: setZoom(zoom / 2)
        case .zoomReset: setZoom(1)
        }
    }

    // MARK: ⌘ HUD


    // MARK: Loading

    /// Unsaved cue edits are preserved per file (CueEditorStore) — switching
    /// selections and coming back finds them waiting, still unsaved.
    private func loadSound() async {
        queuedForDevice = false
        draggingCue = false
        dragOrigin = nil
        selectedCueID = nil
        zoom = 1
        viewStart = 0

        // Editor first — markers should never wait on waveform math.
        let editor = await CueEditorStore.editor(for: item.audioURL)
        cueEditor = editor
        unsavedEdits = editor.dirty ? max(unsavedEdits, 1) : 0
        CueCommandRelay.shared.editor = editor
        paneFocused = true

        if let hit = WaveformStore.cached(item.audioURL) {
            waveform = hit
            reveal = 1
        } else {
            waveform = nil
            reveal = 0
            if let data = try? await WaveformStore.data(for: item.audioURL) {
                guard !Task.isCancelled else { return }
                waveform = data
                if reduceMotion {
                    reveal = 1
                } else {
                    withAnimation(.easeOut(duration: 0.45)) { reveal = 1 }
                }
            }
        }
    }
}
