import SwiftUI
import AppKit

// MARK: - Actions & keystrokes

/// The single-key cue actions a user may rebind. Space, ⌘S, and ⌘Z stay fixed
/// as system conventions; arrows/digits/return/escape are structural.
enum CueAction: String, CaseIterable, Identifiable {
    case addCue
    case deleteCue
    case nextCue
    case prevCue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .addCue: "add cue"
        case .deleteCue: "delete cue"
        case .nextCue: "next cue"
        case .prevCue: "previous cue"
        }
    }
}

/// One rebindable keystroke: a lowercase character plus an optional shift.
struct KeyStroke: Equatable, Codable {
    var character: String
    var shift: Bool = false

    // Plain words by default — "⇥" and "⎋" read as hieroglyphs. The Settings
    // "symbolic key glyphs" toggle restores classic keycap notation.
    var display: String {
        let symbolic = UserDefaults.standard.bool(forKey: "symbolicKeyGlyphs")
        let name: String
        switch character {
        case "\t": name = symbolic ? "⇥" : "tab"
        case "\u{7F}", "\u{8}": name = symbolic ? "⌫" : "delete"
        case " ": name = symbolic ? "␣" : "space"
        case "\r": name = symbolic ? "↩" : "return"
        case "\u{1B}": name = symbolic ? "⎋" : "esc"
        default: name = character.uppercased()
        }
        return (shift ? "⇧" : "") + name
    }
}

// MARK: - Bindings store

/// Live keyboard bindings for the rebindable cue actions, persisted to
/// UserDefaults. The detail pane, the sound menu, and the ⌘-HUD all read this.
@MainActor
@Observable
final class KeyBindings {
    static let shared = KeyBindings()
    private static let defaultsKey = "cueKeyBindings"

    static let factory: [CueAction: KeyStroke] = [
        .addCue: KeyStroke(character: "m"),
        .deleteCue: KeyStroke(character: "\u{7F}"),
        .nextCue: KeyStroke(character: "\t"),
        .prevCue: KeyStroke(character: "\t", shift: true)
    ]

    /// Keys the fixed scheme owns; recording refuses them.
    static let reservedCharacters: Set<String> = {
        var set: Set<String> = [" ", "\r", "\u{1B}"]
        for digit in 1...9 { set.insert("\(digit)") }
        for scalar in [NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey] {
            if let unicode = UnicodeScalar(scalar) { set.insert(String(Character(unicode))) }
        }
        return set
    }()

    private(set) var strokes: [CueAction: KeyStroke]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: KeyStroke].self, from: data) {
            var merged = Self.factory
            for (raw, stroke) in decoded {
                if let action = CueAction(rawValue: raw) { merged[action] = stroke }
            }
            strokes = merged
        } else {
            strokes = Self.factory
        }
    }

    func stroke(for action: CueAction) -> KeyStroke {
        strokes[action] ?? Self.factory[action] ?? KeyStroke(character: "?")
    }

    /// Rebinds an action. Returns false (and changes nothing) when the stroke
    /// is reserved or already bound to a different action.
    @discardableResult
    func set(_ stroke: KeyStroke, for action: CueAction) -> Bool {
        guard !Self.reservedCharacters.contains(stroke.character) else { return false }
        guard !strokes.contains(where: { $0.key != action && $0.value == stroke }) else { return false }
        strokes[action] = stroke
        persist()
        return true
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: strokes.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Command relay

enum CueCommand {
    case playPause
    case addCue
    case deleteCue
    case nextCue
    case prevCue
    case nudgeEarlier
    case nudgeLater
    case saveCues
    case undo
    case jumpToStart
    case zoomIn
    case zoomOut
    case zoomReset
}

/// Routes sound-menu items to whichever SoundDetailView is on screen, and
/// mirrors just enough of its state for menu enablement.
@MainActor
@Observable
final class CueCommandRelay {
    static let shared = CueCommandRelay()

    var editor: CueEditor?
    var hasSound = false
    var hasCueSelection = false
    var hudVisible = false
    var handler: ((CueCommand) -> Void)?

    func send(_ command: CueCommand) { handler?(command) }

    func detach() {
        editor = nil
        hasSound = false
        hasCueSelection = false
        handler = nil
    }
}

// MARK: - Sound menu

/// The "sound" menu. Single-key actions show their live binding in the item
/// label rather than as a key equivalent — a bare-key menu equivalent would
/// steal typing from every text field in the app.
struct SoundMenuCommands: Commands {
    private var relay: CueCommandRelay { .shared }
    private var bindings: KeyBindings { .shared }

    var body: some Commands {
        CommandMenu("sound") {
            Button("play / pause · ␣") { relay.send(.playPause) }
                .disabled(!relay.hasSound)
            Button("jump to start · ↩") { relay.send(.jumpToStart) }
                .disabled(!relay.hasSound)

            Divider()

            Button("add cue · \(bindings.stroke(for: .addCue).display)") { relay.send(.addCue) }
                .disabled(relay.editor?.isEditable != true)
            Button("delete cue · \(bindings.stroke(for: .deleteCue).display)") { relay.send(.deleteCue) }
                .disabled(!relay.hasCueSelection)
            Button("next cue · \(bindings.stroke(for: .nextCue).display)") { relay.send(.nextCue) }
                .disabled(relay.editor?.markers.isEmpty != false)
            Button("previous cue · \(bindings.stroke(for: .prevCue).display)") { relay.send(.prevCue) }
                .disabled(relay.editor?.markers.isEmpty != false)
            Button("nudge earlier · ← (⇧ coarse)") { relay.send(.nudgeEarlier) }
                .disabled(!relay.hasCueSelection)
            Button("nudge later · → (⇧ coarse)") { relay.send(.nudgeLater) }
                .disabled(!relay.hasCueSelection)

            Divider()

            Button("save cues") { relay.send(.saveCues) }
                .keyboardShortcut("s")
                .disabled(relay.editor?.dirty != true)
            Button("undo cue edit") { relay.send(.undo) }
                .keyboardShortcut("z")
                .disabled(relay.editor?.canUndo != true)

            Divider()

            Button("zoom in") { relay.send(.zoomIn) }
                .keyboardShortcut("+")
                .disabled(!relay.hasSound)
            Button("zoom out") { relay.send(.zoomOut) }
                .keyboardShortcut("-")
                .disabled(!relay.hasSound)
            Button("zoom to fit") { relay.send(.zoomReset) }
                .keyboardShortcut("0")
                .disabled(!relay.hasSound)
        }
    }
}

// MARK: - ⌘ HUD

/// TE-styled overlay listing the active bindings; shown while ⌘ is held alone.
struct CueKeyHUD: View {
    private var bindings: KeyBindings { .shared }

    private var leftColumn: [(String, String)] {
        [
            ("␣", "play / pause"),
            (bindings.stroke(for: .addCue).display, "add cue"),
            (bindings.stroke(for: .deleteCue).display, "delete cue"),
            (bindings.stroke(for: .nextCue).display, "next cue"),
            (bindings.stroke(for: .prevCue).display, "previous cue"),
            ("← →", "nudge (⇧ coarse)"),
            (", .", "jump prev / next cue"),
            ("1–9", "jump to cue N")
        ]
    }

    private var rightColumn: [(String, String)] {
        let symbolic = UserDefaults.standard.bool(forKey: "symbolicKeyGlyphs")
        return [
            (symbolic ? "↩" : "return", "jump to start"),
            (symbolic ? "⎋" : "esc", "deselect cue"),
            ("⌘S", "save cues"),
            ("⌘Z", "undo cue edit"),
            ("⌘+ −", "zoom"),
            ("⌘0", "zoom to fit"),
            ("⌘drag", "fine move")
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                column(leftColumn)
                column(rightColumn)
            }
            Text("delete and nudge act on the selected cue. click a tick or press tab to select")
                .font(.system(size: 10))
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(TE.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TE.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    private func column(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .font(.system(size: 11, weight: .semibold))
                        .monospaced()
                        .foregroundStyle(TE.orange)
                        .gridColumnAlignment(.trailing)
                    Text(row.1)
                        .font(.system(size: 11))
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
