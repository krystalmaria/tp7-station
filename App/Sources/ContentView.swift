import SwiftUI
import AppKit
import InboxKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flagsMonitor: Any?
    @State private var hudTask: Task<Void, Never>?

    var body: some View {
        let relay = CueCommandRelay.shared
        VStack(spacing: 0) {
            DevicePanel()
            Hairline()
            ArchiveTabs()
        }
        .background(TE.ground)
        .frame(minWidth: 560, minHeight: 480)
        .overlay {
            // Window-centred so the full key map is always visible.
            if relay.hudVisible {
                CueKeyHUD().transition(reduceMotion ? .identity : .opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.unseenMemoCount = 0
        }
        .onAppear { installModifierMonitor() }
        .onDisappear { removeModifierMonitor() }
    }

    // The ⌘-HUD lives at window level so it works with or without a
    // selection; holding ⌘ alone for ~0.8s fades the key map in.
    private func installModifierMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { handleFlags(event) }
            return event
        }
    }

    private func removeModifierMonitor() {
        hudTask?.cancel()
        hudTask = nil
        CueCommandRelay.shared.hudVisible = false
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            hudTask?.cancel()
            hudTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    CueCommandRelay.shared.hudVisible = true
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { CueCommandRelay.shared.hudVisible = true }
                }
            }
        } else {
            hudTask?.cancel()
            hudTask = nil
            guard CueCommandRelay.shared.hudVisible else { return }
            if reduceMotion {
                CueCommandRelay.shared.hudVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.15)) { CueCommandRelay.shared.hudVisible = false }
            }
        }
    }
}

enum ArchiveTab: String, CaseIterable {
    case inbox
    case recordings
    case library

    // The device's own vocabulary: memos, recordings, library.
    var title: String {
        self == .inbox ? "memos" : rawValue
    }
}

struct ArchiveTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab: ArchiveTab = .inbox
    @State private var selectedID: String?
    @State private var renameTarget: InboxItem?
    @State private var renameText = ""
    @State private var removeTarget: InboxItem?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(ArchiveTab.allCases, id: \.self) { candidate in
                    TabLabel(
                        title: candidate.title,
                        count: count(for: candidate),
                        active: tab == candidate
                    ) {
                        tab = candidate
                    }
                }
                Spacer()
                if tab == .library {
                    Button {
                        showImporter = true
                    } label: {
                        Text("add songs")
                            .monospaced()
                    }
                    .buttonStyle(HairlineButtonStyle())
                    .disabled(model.device == nil)
                    .help(model.device == nil ? "Connect the TP-7 to add songs" : "Push audio files to the TP-7 library")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Group {
                switch tab {
                case .inbox:
                    if model.inboxItems.isEmpty {
                        EmptyInbox()
                    } else {
                        ItemRows(items: model.inboxItems, showNotes: true, selectedID: $selectedID)
                    }
                case .recordings:
                    if model.recordingItems.isEmpty {
                        EmptyLane(
                            icon: "waveform",
                            line: "no recordings on the reel",
                            steps: [("01", "press ●"), ("02", "press ▶"), ("03", "capture the world")]
                        )
                    } else {
                        ItemRows(items: model.recordingItems, showNotes: false, selectedID: $selectedID)
                    }
                case .library:
                    if model.libraryItems.isEmpty {
                        EmptyLane(
                            icon: "headphones",
                            line: "the library is empty",
                            steps: [("01", "push songs from the mac"), ("02", "listen anywhere")]
                        )
                    } else {
                        ItemRows(items: model.libraryItems, showNotes: false, selectedID: $selectedID)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let item = selectedItem {
                Hairline()
                // .id forces a genuinely fresh view per selection — without
                // it SwiftUI reuses the same instance and focus only catches
                // up once its async load task finishes, so a fast
                // click-then-space could fire against the previous track.
                SoundDetailView(item: item)
                    .id(item.id)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Up/down move the row selection. The detail pane's own onKeyPress
        // handles its keys first and ignores arrows it doesn't use (up/down
        // aren't claimed there), so this bubbles up and fires whether or not
        // the pane currently has focus for cue editing.
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onChange(of: tab) { _, _ in
            // A programmatic focus jump sets tab + selection together; only a
            // user-initiated tab switch clears the selection.
            if model.focusItemID == nil { selectedID = nil }
        }
        .onChange(of: model.focusItemID) { _, focusID in
            guard let focusID else { return }
            for candidate in ArchiveTab.allCases where items(for: candidate).contains(where: { $0.id == focusID }) {
                tab = candidate
                selectedID = focusID
                break
            }
            Task { @MainActor in model.focusItemID = nil }
        }
        .environment(\.fileActions, FileActions(
            rename: { item in
                renameTarget = item
                // Memos are edited by their friendly title — the device
                // filename is derived from it automatically. Recordings and
                // library files have no separate title concept, so this is a
                // plain filename edit for them.
                renameText = item.lane == .memos ? (item.title ?? item.originalName) : item.originalName
            },
            remove: { item in removeTarget = item }
        ))
        .alert(renameTarget?.lane == .memos ? "Rename" : "Rename on the TP-7", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField(renameTarget?.lane == .memos ? "Title" : "Name", text: $renameText)
            Button("Rename") {
                if let item = renameTarget {
                    if item.lane == .memos {
                        model.setMemoTitle(item, to: renameText)
                    } else {
                        Task { _ = await model.renameFile(item, to: renameText) }
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text(renameTarget?.lane == .memos
                ? "Changes what shows here and queues a matching rename on the device. If this memo was already sent to your notes, that note is untouched — edit its heading directly in your vault."
                : "Renames the file on the device and in the archive. The datetime prefix is worth keeping: it's the only record of when it was captured.")
        }
        .confirmationDialog(
            "Remove \"\(removeTarget?.originalName ?? "")\" from the TP-7?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from device only", role: .destructive) {
                if let item = removeTarget {
                    Task { await model.removeFromDevice(item) }
                }
                removeTarget = nil
            }
            Button("Delete everywhere", role: .destructive) {
                if let item = removeTarget {
                    Task { await model.deleteEverywhere(item) }
                }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: {
            Text("\"Remove from device only\" keeps the archived copy on this Mac (the row stays). \"Delete everywhere\" also deletes the archive copy and drops it from the app. Notes already sent are never touched.")
        }
        .alert("That didn't work", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await model.addToLibrary(urls) }
            }
        }
    }

    /// Resolved from the live lists each render, so a send-to-vault or sync
    /// refresh updates the detail pane in place.
    private var selectedItem: InboxItem? {
        guard let selectedID else { return nil }
        return items(for: tab).first { $0.id == selectedID }
    }

    private func items(for tab: ArchiveTab) -> [InboxItem] {
        switch tab {
        case .inbox: model.inboxItems
        case .recordings: model.recordingItems
        case .library: model.libraryItems
        }
    }

    private func count(for tab: ArchiveTab) -> Int {
        items(for: tab).count
    }

    /// Moves the row selection by one, stopping at either end (no wraparound —
    /// matches Mail/Finder list navigation). Selects the first row if nothing
    /// is selected yet. Selection only; it never starts or changes playback.
    private func moveSelection(by step: Int) {
        let list = items(for: tab)
        guard !list.isEmpty else { return }
        guard let currentID = selectedID, let index = list.firstIndex(where: { $0.id == currentID }) else {
            selectedID = list.first?.id
            return
        }
        let next = index + step
        guard list.indices.contains(next) else { return }
        selectedID = list[next].id
    }
}

struct TabLabel: View {
    let title: String
    let count: Int
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : (hovering ? Color.primary.opacity(0.75) : .secondary))
                Text("\(count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(active ? AnyShapeStyle(TE.orange) : AnyShapeStyle(.tertiary))
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? TE.orange : Color.clear)
                    .frame(height: 1.5)
                    .offset(y: 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ItemRows: View {
    let items: [InboxItem]
    let showNotes: Bool
    @Binding var selectedID: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    InboxRow(
                        item: item,
                        showNote: showNotes,
                        selected: selectedID == item.id,
                        activate: { selectedID = item.id }
                    )
                    .onTapGesture {
                        selectedID = selectedID == item.id ? nil : item.id
                    }
                    if item.id != items.last?.id {
                        Hairline().padding(.leading, 20)
                    }
                }
            }
        }
        .animation(.default, value: items)
    }
}

struct EmptyLane: View {
    let icon: String
    let line: String
    let steps: [(String, String)]

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.primary.opacity(0.3))
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach(steps, id: \.0) { step in
                    HStack(spacing: 5) {
                        Text(step.0)
                            .font(.system(size: 11, weight: .semibold))
                            .monospaced()
                            .foregroundStyle(TE.orange)
                        Text(step.1)
                            .font(.system(size: 11))
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
    }
}

struct DevicePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var justSynced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                TapeReel(
                    spinning: model.syncing,
                    size: 38,
                    tint: model.syncing ? TE.orange : .primary.opacity(0.75)
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("tp–7")
                            .font(.system(size: 16, weight: .semibold))
                        Circle()
                            .fill(model.device != nil ? TE.connectedGreen : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        Text(model.device != nil ? "connected" : "disconnected")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(model.device != nil ? TE.connectedGreen : .secondary)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .monospaced()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await model.runSync() }
                } label: {
                    Text(model.syncing ? "syncing" : "sync")
                        .monospaced()
                }
                .buttonStyle(HairlineButtonStyle())
                .disabled(model.device == nil || model.syncing || model.device?.mode == "mass-storage")
                .keyboardShortcut("r")
                .help("Sync the TP-7 (⌘R)")
            }

            if model.device?.mode == "mass-storage" {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(TE.orange)
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    Text("connected in storage mode, not the mode syncing needs. power-cycle it: turn the volume knob fully off, wait a moment, then back on.")
                        .font(.system(size: 11))
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if model.syncing {
                    RecordDot()
                } else if justSynced {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TE.connectedGreen)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(model.statusLine)
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            if !model.lastSyncLog.isEmpty {
                SyncLog(lines: model.lastSyncLog)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .onChange(of: model.syncing) { wasSyncing, isSyncing in
            // Never show the success checkmark after a sync that failed —
            // it read as "it worked" right next to a failure count.
            guard wasSyncing, !isSyncing, !model.lastSyncHadFailures else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { justSynced = true }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { justSynced = false }
            }
        }
    }

    private var subtitle: String {
        if let device = model.device {
            return "\(device.serialNumber ?? "unknown serial") · \(device.mode)"
        }
        return "plug in via usb-c. no button ritual needed"
    }
}

struct RecordDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dot
        } else {
            dot.phaseAnimator([1.0, 0.3]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(TE.orange)
            .frame(width: 7, height: 7)
    }
}

struct SyncLog: View {
    let lines: [String]

    var body: some View {
        DisclosureGroup {
            // One Text view, not one per line: SwiftUI can't drag-select
            // across separate sibling Text views, so a per-line layout
            // silently caps copying at a single line no matter what's in it.
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 11))
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(TE.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TE.hairline, lineWidth: 1))
                .padding(.top, 6)
        } label: {
            Text("last sync")
                .font(.system(size: 11, weight: .medium))
                .monospaced()
                .foregroundStyle(.secondary)
        }
    }
}

struct FileActions {
    var rename: (InboxItem) -> Void = { _ in }
    var remove: (InboxItem) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var fileActions = FileActions()
}

struct InboxRow: View {
    let item: InboxItem
    var showNote: Bool = true
    var selected: Bool = false
    var activate: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.fileActions) private var fileActions
    @State private var hovering = false

    private var isPlayingThis: Bool {
        model.player.currentURL == item.audioURL && model.player.isPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if showNote {
                    if let title = item.title ?? noteTitle {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                    } else if let recorded = MemoProcessor.recordedDate(fromFilename: item.originalName) {
                        Text(recorded.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.transcript != nil ? "no speech detected" : "unprocessed")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.originalName)
                        .font(.system(size: 11))
                        .monospaced()
                        .foregroundStyle(.tertiary)
                } else {
                    Text(item.originalName)
                        .font(.system(size: 13, weight: .medium))
                        .monospaced()
                }
            }

            Spacer()

            if !showNote {
                Text(item.sizeBytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            Button {
                activate()
                model.player.toggle(item.audioURL)
            } label: {
                Image(systemName: isPlayingThis ? "pause.circle" : "play.circle")
            }
            .buttonStyle(HoverIconButtonStyle())
            .help(isPlayingThis ? "Pause" : "Play in app")

            if showNote {
                if item.sentToVault, let noteURL = item.noteURL {
                    Button {
                        NSWorkspace.shared.open(noteURL)
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .buttonStyle(HoverIconButtonStyle())
                    .help("Open this memo's note, in \(model.vaultInboxPath)")
                } else if model.vaultConfigured {
                    Button {
                        model.sendToVault(item)
                    } label: {
                        Image(systemName: "arrow.up.doc")
                    }
                    .buttonStyle(HoverIconButtonStyle())
                    .help((item.transcript?.isEmpty ?? true)
                        ? "No transcript, so it wasn't sent automatically. Click to send anyway."
                        : "Send to memos folder: \(model.vaultInboxPath)")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(
            selected ? Color.primary.opacity(0.06)
                : hovering ? Color.primary.opacity(0.045)
                : Color.clear
        )
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(TE.orange)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") { fileActions.rename(item) }
            if showNote && !item.sentToVault {
                Button("Send to vault") { model.sendToVault(item) }
            }
            Divider()
            Button("Delete…", role: .destructive) { fileActions.remove(item) }
        }
    }

    private var noteTitle: String? {
        guard let noteURL = item.noteURL else { return nil }
        return noteURL.deletingPathExtension().lastPathComponent
            .split(separator: "-").dropFirst(3).joined(separator: " ")
            .capitalized
    }
}

struct EmptyInbox: View {
    var body: some View {
        VStack(spacing: 20) {
            TapeReel(spinning: false, size: 48, tint: .primary.opacity(0.3))
            Text("nothing on the reel")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ritualStep("01", "hold memo")
                ritualStep("02", "speak")
                ritualStep("03", "dock")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
    }

    private func ritualStep(_ number: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.system(size: 11, weight: .semibold))
                .monospaced()
                .foregroundStyle(TE.orange)
            Text(label)
                .font(.system(size: 11))
                .monospaced()
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Device") {
                Toggle("Sync automatically when the TP-7 is plugged in", isOn: $model.autoSyncEnabled)
                    .tint(TE.orange)
                Toggle("Mirror the TP-7 library locally", isOn: $model.syncLibrary)
                    .tint(TE.orange)
                Toggle("Rename memos on the device to their titles", isOn: $model.renameOnDevice)
                    .tint(TE.orange)
                    .disabled(model.deleteMemosAfterImport)
                if model.deleteMemosAfterImport {
                    Text("Paused while \"Remove memos from the TP-7 after import\" is on: imported memos leave the device before a rename could land.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Quit field kit when syncing", isOn: $model.quitFieldKitOnSync)
                    .tint(TE.orange)
            }
            Section("Memos") {
                Toggle("Transcribe memos", isOn: $model.transcribeMemos)
                    .tint(TE.orange)
                if model.transcribeMemos {
                    Toggle("Smart titles and summaries", isOn: $model.smartTitles)
                        .tint(TE.orange)
                        .disabled(!Intelligence.smartTitlesAvailable)
                    Text(Intelligence.smartTitlesStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !Intelligence.smartTitlesAvailable {
                        Button("Open Apple Intelligence settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Toggle("Remove memos from the TP-7 after import", isOn: $model.deleteMemosAfterImport)
                    .tint(TE.orange)
                if model.deleteMemosAfterImport {
                    Text("Camera-import style: once a memo is verified in the archive\(model.transcribeMemos ? " and transcribed" : ""), its device copy is removed. Keep the TP-7 plugged in while the status line says it's clearing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Send memos to the memos folder automatically", isOn: $model.autoSendToVault)
                    .tint(TE.orange)
            }
            Section("Folders") {
                HStack {
                    TextField("Archive folder", text: $model.archivePath)
                    Button("Choose…") {
                        pickFolder(current: model.archivePath) { model.archivePath = $0 }
                    }
                }
                HStack {
                    TextField("Memos folder", text: $model.vaultInboxPath, prompt: Text("empty = memo export off"))
                    Button("Choose…") {
                        pickFolder(current: model.vaultInboxPath) { model.vaultInboxPath = $0 }
                    }
                }
                Text(model.vaultConfigured
                    ? "Memos you send become Markdown notes in this folder (audio copied to its audio/ subfolder). Works beautifully as a folder inside an Obsidian vault."
                    : "No memos folder set. Sending is hidden until you choose one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                ForEach(CueAction.allCases) { action in
                    ShortcutRecorderRow(action: action)
                }
                Stepper(
                    "Fine nudge (ms): \(model.nudgeFineMs)",
                    value: $model.nudgeFineMs, in: 1...500, step: 5
                )
                Stepper(
                    "Coarse nudge (ms): \(model.nudgeCoarseMs)",
                    value: $model.nudgeCoarseMs, in: 10...2000, step: 25
                )
            }
            Section {
                Text("Sent memos become Markdown notes in the memos folder; original audio is copied into its audio/ subfolder. The archive keeps every original pulled from the TP-7.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Interface") {
                Toggle("Symbolic key glyphs", isOn: $model.symbolicKeyGlyphs)
                    .tint(TE.orange)
                Text("Shows shortcuts in classic Mac keycap notation (⇥ ⌫ ⎋) instead of plain words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func pickFolder(current: String, assign: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let expanded = (current as NSString).expandingTildeInPath
        if !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }
        if panel.runModal() == .OK, let url = panel.url {
            assign(url.path)
        }
    }
}

/// One rebindable action row: current key, plus a "record" button that
/// captures the next key press. Duplicate or reserved keys are refused.
struct ShortcutRecorderRow: View {
    let action: CueAction

    @State private var recording = false
    @State private var refused = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.label)
            Spacer()
            if refused {
                Text("key in use")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(TE.orange)
            }
            Text(KeyBindings.shared.stroke(for: action).display)
                .font(.system(size: 12, weight: .medium))
                .monospaced()
                .foregroundStyle(recording ? AnyShapeStyle(TE.orange) : AnyShapeStyle(.secondary))
                .frame(minWidth: 28)
            Button(recording ? "press a key…" : "record") {
                recording ? stopRecording() : startRecording()
            }
            .buttonStyle(HairlineButtonStyle())
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        refused = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { capture(event) }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        defer { stopRecording() }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift).isEmpty,
              var character = event.charactersIgnoringModifiers?.lowercased(),
              character.count == 1
        else { return }
        if character == "\u{1B}" { return } // Escape cancels recording.
        if character == "\u{8}" { character = "\u{7F}" }
        let stroke = KeyStroke(character: character, shift: flags.contains(.shift))
        refused = !KeyBindings.shared.set(stroke, for: action)
    }
}
