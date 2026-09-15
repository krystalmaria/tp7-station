import SwiftUI

@main
struct TP7CompanionApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .commands {
            SoundMenuCommands()
        }
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
        } label: {
            // The menu bar renders template-mono, so state reads through
            // symbol choice, pulse, and the unseen count — not colour.
            HStack(spacing: 2) {
                Image(systemName: model.device != nil ? "recordingtape.circle.fill" : "recordingtape.circle")
                    .symbolEffect(.pulse, options: .repeating, isActive: model.syncing)
                if model.unseenMemoCount > 0 {
                    Text("\(model.unseenMemoCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.device != nil ? "TP-7 Connected" : "No TP-7")
        Text(model.statusLine)
        if let lastSyncAt = model.lastSyncAt {
            Text("synced \(lastSyncAt, style: .relative) ago")
        }
        if !model.inboxItems.isEmpty {
            Divider()
            ForEach(model.inboxItems.prefix(3)) { item in
                let playingThis = model.player.currentURL == item.audioURL && model.player.isPlaying
                Button {
                    model.player.toggle(item.audioURL)
                    model.focusItemID = item.id
                } label: {
                    Text("\(playingThis ? "⏸" : "▶") \(item.title ?? item.originalName)")
                }
            }
        }
        Divider()
        Button(model.syncing ? "Syncing…" : "Sync Now") {
            Task { await model.runSync() }
        }
        .disabled(model.device == nil || model.syncing)
        Button("Open tp7-station") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Divider()
        Button("Quit tp7-station") { NSApp.terminate(nil) }
    }
}
