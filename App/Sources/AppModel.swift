import Foundation
import AppKit
import SwiftUI
import Observation
import UserNotifications
import TP7Kit
import InboxKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "system"
        case .light: "light"
        case .dark: "dark"
        }
    }
    /// nil lets SwiftUI/AppKit follow the OS setting, same as today's default.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct InboxItem: Identifiable, Equatable {
    let id: String
    let lane: Lane
    let originalName: String
    let audioURL: URL
    let noteURL: URL?
    let syncedAt: Date
    let sizeBytes: UInt64
    let title: String?
    let transcript: String?
    let summary: String?

    var sentToVault: Bool { noteURL != nil }
}

@MainActor
@Observable
final class AppModel {
    var device: TP7Device?
    var syncing = false
    var statusLine = "Plug in the TP-7 and press Sync."
    /// Set for failures that deserve a dialog, not just a status-line whisper.
    var lastError: String?
    var lastSyncAt: Date?
    /// Drives the success checkmark — never shown after a sync that failed.
    var lastSyncHadFailures = false
    /// Memos that arrived via auto-sync and haven't been looked at — shown as
    /// a count beside the menu-bar icon; cleared when the window comes forward.
    var unseenMemoCount = 0
    /// Set by the menu bar (e.g. playing an item) so the main window can jump
    /// its selection to match; the view consumes and clears it.
    var focusItemID: String?
    var lastSyncLog: [String] = []
    var inboxItems: [InboxItem] = []
    var recordingItems: [InboxItem] = []
    var libraryItems: [InboxItem] = []

    var archivePath: String {
        didSet { UserDefaults.standard.set(archivePath, forKey: "archivePath"); reloadInbox() }
    }
    var vaultInboxPath: String {
        didSet { UserDefaults.standard.set(vaultInboxPath, forKey: "vaultInboxPath") }
    }
    var autoSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: "autoSyncEnabled") }
    }
    /// Off by default: the vault receives memos only when Krystal sends them.
    var autoSendToVault: Bool {
        didSet { UserDefaults.standard.set(autoSendToVault, forKey: "autoSendToVault") }
    }
    var quitFieldKitOnSync: Bool {
        didSet { UserDefaults.standard.set(quitFieldKitOnSync, forKey: "quitFieldKitOnSync") }
    }
    /// Off = memos are archived as audio only, no transcription or titling.
    var transcribeMemos: Bool {
        didSet { UserDefaults.standard.set(transcribeMemos, forKey: "transcribeMemos") }
    }
    /// AI-chat-style titles/summaries via the local model; off = first-words titles.
    var smartTitles: Bool {
        didSet { UserDefaults.standard.set(smartTitles, forKey: "smartTitles") }
    }
    var symbolicKeyGlyphs: Bool {
        didSet { UserDefaults.standard.set(symbolicKeyGlyphs, forKey: "symbolicKeyGlyphs") }
    }
    var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Camera-import style: once a memo is verified in the archive (and
    /// transcribed, when that's on), the device copy is removed.
    var deleteMemosAfterImport: Bool {
        didSet { UserDefaults.standard.set(deleteMemosAfterImport, forKey: "deleteMemosAfterImport") }
    }
    var renameOnDevice: Bool {
        didSet { UserDefaults.standard.set(renameOnDevice, forKey: "renameOnDevice") }
    }
    var syncLibrary: Bool {
        didSet { UserDefaults.standard.set(syncLibrary, forKey: "syncLibrary") }
    }
    var nudgeFineMs: Int {
        didSet { UserDefaults.standard.set(nudgeFineMs, forKey: "nudgeFineMs") }
    }
    var nudgeCoarseMs: Int {
        didSet { UserDefaults.standard.set(nudgeCoarseMs, forKey: "nudgeCoarseMs") }
    }

    let player = AudioPlayerController()

    private let client = TP7Client()
    private let intelligence = Intelligence()

    init() {
        let defaults = UserDefaults.standard
        // App-managed data belongs in Application Support — out of sight,
        // relocatable any time via Settings.
        self.archivePath = defaults.string(forKey: "archivePath")
            ?? ("~/Library/Application Support/tp7-station" as NSString).expandingTildeInPath
        // Empty until the user chooses a folder — vault sending stays off.
        self.vaultInboxPath = defaults.string(forKey: "vaultInboxPath") ?? ""
        self.autoSyncEnabled = defaults.object(forKey: "autoSyncEnabled") as? Bool ?? true
        self.autoSendToVault = defaults.object(forKey: "autoSendToVault") as? Bool ?? false
        self.quitFieldKitOnSync = defaults.object(forKey: "quitFieldKitOnSync") as? Bool ?? true
        self.transcribeMemos = defaults.object(forKey: "transcribeMemos") as? Bool ?? true
        self.smartTitles = defaults.object(forKey: "smartTitles") as? Bool ?? true
        self.symbolicKeyGlyphs = defaults.object(forKey: "symbolicKeyGlyphs") as? Bool ?? false
        self.appearance = defaults.string(forKey: "appearance").flatMap(AppAppearance.init) ?? .system
        self.deleteMemosAfterImport = defaults.object(forKey: "deleteMemosAfterImport") as? Bool ?? false
        self.renameOnDevice = defaults.object(forKey: "renameOnDevice") as? Bool ?? true
        self.syncLibrary = defaults.object(forKey: "syncLibrary") as? Bool ?? true
        self.nudgeFineMs = defaults.object(forKey: "nudgeFineMs") as? Int ?? 10
        self.nudgeCoarseMs = defaults.object(forKey: "nudgeCoarseMs") as? Int ?? 100
        reloadInbox()
        Task { await self.startDevicePolling() }
    }

    var archiveDir: URL { URL(fileURLWithPath: (archivePath as NSString).expandingTildeInPath) }
    var vaultDir: URL { URL(fileURLWithPath: (vaultInboxPath as NSString).expandingTildeInPath) }
    /// Empty path = vault sending off; no vault affordances appear anywhere.
    var vaultConfigured: Bool {
        !vaultInboxPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Device presence

    // Plug-in detection rides the existing 4s poll — a device appearing where
    // none was is the dock event. Switch to IOKit matching notifications if
    // latency or battery ever matters.
    func startDevicePolling() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        while !Task.isCancelled {
            let previous = device
            device = (try? await client.devices())?.first
            let justAppeared = previous == nil && device != nil
            // A device that was already connected but in the wrong mode
            // (e.g. mass-storage) recovering into audio-midi is just as much
            // a "ready to sync" moment as a fresh plug-in — a power-cycle
            // shouldn't need a manual click on top of it.
            let recoveredToSyncableMode = previous != nil && device != nil
                && previous?.mode != "audio-midi" && device?.mode == "audio-midi"
            if (justAppeared || recoveredToSyncableMode), autoSyncEnabled, !syncing {
                await runSync(notify: true)
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func postSyncNotification(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "TP-7 synced"
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Sync pipeline

    func runSync(notify: Bool = false) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        lastSyncLog = []

        if quitFieldKitOnSync {
            for app in NSWorkspace.shared.runningApplications
            where app.localizedName?.lowercased() == "field kit" {
                app.terminate()
                log("Quit field kit (it blocks device access)")
            }
        }

        do {
            statusLine = "Syncing…"
            // Honour deletion tombstones first, and never pull what's on one.
            await applyPendingRemoteDeletes()
            let lanes: [Lane] = syncLibrary ? Lane.allCases : [.memos, .recordings]
            let engine = SyncEngine(
                client: client,
                archiveDir: archiveDir,
                lanes: lanes,
                excludedRemotePaths: pendingRemoteDeletes()
            )
            let summary = try await engine.sync { [weak self] message in
                Task { @MainActor in self?.statusLine = message }
            }

            var vaultNotes = 0
            var importedMemos: [SyncedFile] = []
            for file in summary.newFiles {
                log("\(file.isRefresh ? "Refreshed" : "Pulled") \(file.name) (\(file.lane.rawValue))")
                guard file.lane == .memos, !file.isRefresh else { continue }
                if transcribeMemos {
                    statusLine = "Transcribing \(file.name)…"
                    if await processMemo(file, engine: engine) { vaultNotes += 1 }
                } else {
                    markProcessedWithoutTranscript(file, engine: engine)
                }
                importedMemos.append(file)
            }

            // Memos whose transcription failed on a previous sync (model still
            // downloading, transient error) never got marked processed — retry
            // them here rather than leaving them stuck as a false "no speech".
            if transcribeMemos {
                let attemptedNames = Set(importedMemos.map(\.name))
                let manifest = Manifest(fileURL: engine.manifestURL)
                let pending = manifest.entries.compactMap { key, entry -> SyncedFile? in
                    let parts = key.split(separator: "|")
                    guard parts.count == 2, parts[0] == Lane.memos.rawValue,
                          entry.processedAt == nil, !attemptedNames.contains(String(parts[1]))
                    else { return nil }
                    return SyncedFile(
                        lane: .memos, name: String(parts[1]),
                        localURL: URL(fileURLWithPath: entry.localPath), isRefresh: false
                    )
                }
                for file in pending where FileManager.default.fileExists(atPath: file.localURL.path) {
                    log("Retrying transcription: \(file.name)")
                    statusLine = "Retrying \(file.name)…"
                    if await processMemo(file, engine: engine) { vaultNotes += 1 }
                    importedMemos.append(file)
                }
            }

            if deleteMemosAfterImport && !importedMemos.isEmpty {
                statusLine = "Clearing imported memos from the TP-7. Leave it plugged in…"
                for file in importedMemos {
                    // Only verified-archived files reach this list; the archive
                    // copy is the permanent one, camera-import style.
                    do {
                        try await client.remove("\(file.lane.remoteFolder)/\(file.name)")
                        log("Cleared from device after import: \(file.name)")
                    } catch {
                        log("⚠️ could not clear \(file.name) from device; it will stay until removed manually")
                    }
                }
            }

            statusLine = "Applying queued renames…"
            var queue = RenameQueue(fileURL: archiveDir.appendingPathComponent("rename-queue.json"))
            let applied = await queue.apply(with: client)
            for rename in applied {
                log("Renamed on device → \(rename.newName)")
                reconcileAppliedRename(rename)
            }

            await applyPendingDevicePushes()

            for failure in summary.failures { log("⚠️ \(failure)") }
            statusLine = summaryLine(summary, vaultNotes: vaultNotes)
            lastSyncAt = Date()
            lastSyncHadFailures = !summary.failures.isEmpty
            if notify && !summary.newFiles.isEmpty {
                postSyncNotification(statusLine)
                unseenMemoCount += summary.newFiles.filter { $0.lane == .memos }.count
            }
        } catch {
            statusLine = "Sync failed: \(error.localizedDescription)"
            lastSyncHadFailures = true
            if notify { postSyncNotification(statusLine) }
        }
        reloadInbox()
    }

    private func processMemo(_ file: SyncedFile, engine: SyncEngine) async -> Bool {
        let transcript: String
        do {
            transcript = try await intelligence.transcribe(file.localURL)
        } catch {
            // A thrown error (model still downloading, permission denied,
            // corrupt audio) is not the same as genuine silence — don't mark
            // this memo processed, so the next sync retries transcription
            // instead of it being stuck as a false "no speech" forever.
            log("⚠️ \(file.name): transcription failed (\(error.localizedDescription)) — will retry next sync")
            return false
        }
        let titled = smartTitles ? await intelligence.titleAndSummary(for: transcript) : nil
        let memo = MemoProcessor().process(
            originalName: file.name,
            recordedAt: MemoProcessor.recordedDate(fromFilename: file.name),
            transcript: transcript,
            title: titled?.title,
            summary: titled?.summary,
            audioRelativePath: "audio/\(file.name)"
        )

        var manifest = Manifest(fileURL: engine.manifestURL)
        let key = ManifestKey(lane: .memos, name: file.name)
        if var entry = manifest.entry(for: key) {
            entry.processedAt = Date()
            entry.title = memo.isSpeech ? memo.title : nil
            entry.transcript = transcript
            entry.summary = titled?.summary
            try? manifest.record(key, entry: entry)
        }

        guard memo.isSpeech else {
            log("\(file.name): no speech, left in sound pool")
            return false
        }

        // No point renaming a device copy that import is about to clear.
        if renameOnDevice && !deleteMemosAfterImport {
            var queue = RenameQueue(fileURL: archiveDir.appendingPathComponent("rename-queue.json"))
            try? queue.enqueue(QueuedRename(
                remotePath: "\(file.lane.remoteFolder)/\(file.name)",
                newName: RenameQueue.deviceName(originalName: file.name, title: memo.title)
            ))
        }

        if autoSendToVault && vaultConfigured {
            let sent = writeNoteToVault(key: key)
            log("\(file.name) → \(memo.title)\(sent ? " → memos folder" : "")")
            return sent
        }
        log("\(file.name) → \(memo.title) (in memos, not yet sent)")
        return false
    }

    private func markProcessedWithoutTranscript(_ file: SyncedFile, engine: SyncEngine) {
        var manifest = Manifest(fileURL: engine.manifestURL)
        let key = ManifestKey(lane: .memos, name: file.name)
        if var entry = manifest.entry(for: key) {
            entry.processedAt = Date()
            try? manifest.record(key, entry: entry)
        }
    }

    /// Explicit send: writes the vault note + audio copy for one memo and
    /// remembers it in the manifest. Idempotent — already-sent memos no-op.
    func sendToVault(_ item: InboxItem) {
        guard vaultConfigured, !item.sentToVault else { return }
        let key = ManifestKey(lane: .memos, name: item.originalName)
        if writeNoteToVault(key: key) {
            statusLine = "Sent \"\(item.title ?? item.originalName)\" to your memos folder."
        }
        reloadInbox()
    }

    private func writeNoteToVault(key: ManifestKey) -> Bool {
        var manifest = Manifest(fileURL: archiveDir.appendingPathComponent("manifest.json"))
        guard var entry = manifest.entry(for: key), entry.notePath == nil else { return false }
        let memo = MemoProcessor().process(
            originalName: key.name,
            recordedAt: MemoProcessor.recordedDate(fromFilename: key.name),
            transcript: entry.transcript ?? "",
            title: entry.title,
            summary: entry.summary,
            audioRelativePath: "audio/\(key.name)"
        )
        do {
            let fm = FileManager.default
            let audioDir = vaultDir.appendingPathComponent("audio")
            try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
            let audioDest = audioDir.appendingPathComponent(key.name)
            if !fm.fileExists(atPath: audioDest.path) {
                try fm.copyItem(at: URL(fileURLWithPath: entry.localPath), to: audioDest)
            }
            var noteURL = vaultDir.appendingPathComponent(memo.noteFilename)
            var counter = 2
            while fm.fileExists(atPath: noteURL.path) {
                let stem = (memo.noteFilename as NSString).deletingPathExtension
                noteURL = vaultDir.appendingPathComponent("\(stem)-\(counter).md")
                counter += 1
            }
            try memo.markdown.write(to: noteURL, atomically: true, encoding: .utf8)
            entry.notePath = noteURL.path
            try manifest.record(key, entry: entry)
            return true
        } catch {
            log("⚠️ send failed for \(key.name): \(error.localizedDescription)")
            return false
        }
    }

    /// After a queued rename lands on the device, the archive file and the
    /// manifest key must follow — otherwise the next sync mistakes the renamed
    /// device file for a brand-new memo and pulls a duplicate.
    private func reconcileAppliedRename(_ rename: QueuedRename) {
        guard let lane = Lane.allCases.first(where: { rename.remotePath.hasPrefix($0.remoteFolder + "/") }) else { return }
        let oldName = (rename.remotePath as NSString).lastPathComponent
        let laneDir = archiveDir.appendingPathComponent(lane.rawValue)
        let newURL = laneDir.appendingPathComponent(rename.newName)
        try? FileManager.default.moveItem(at: laneDir.appendingPathComponent(oldName), to: newURL)

        var manifest = Manifest(fileURL: archiveDir.appendingPathComponent("manifest.json"))
        let oldKey = ManifestKey(lane: lane, name: oldName)
        guard var entry = manifest.entry(for: oldKey) else { return }
        entry.localPath = newURL.path
        try? manifest.rename(oldKey, to: ManifestKey(lane: lane, name: rename.newName), entry: entry)
        reloadInbox()
    }

    // MARK: File management (Field Kit parity)

    private func manifestKey(for item: InboxItem) -> ManifestKey? {
        ManifestKey(lane: item.lane, name: item.originalName)
    }

    /// Sets what a memo displays as — distinct from `renameFile`, which
    /// renames the underlying file. Updates the manifest's title directly
    /// (what the inbox row and any future device rename are computed from),
    /// and queues a matching device rename so the two stay in sync, same as
    /// the automatic post-transcription flow. Never touches a note already
    /// sent to the vault — that file is Krystal's from that point on.
    func setMemoTitle(_ item: InboxItem, to rawTitle: String) {
        let newTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty, item.lane == .memos else { return }

        var manifest = Manifest(fileURL: archiveDir.appendingPathComponent("manifest.json"))
        guard let key = manifestKey(for: item), var entry = manifest.entry(for: key) else { return }
        entry.title = newTitle
        try? manifest.record(key, entry: entry)

        if renameOnDevice {
            var queue = RenameQueue(fileURL: archiveDir.appendingPathComponent("rename-queue.json"))
            try? queue.enqueue(QueuedRename(
                remotePath: "\(item.lane.remoteFolder)/\(item.originalName)",
                newName: RenameQueue.deviceName(originalName: item.originalName, title: newTitle)
            ))
        }
        statusLine = "Title updated. Renamed on the device at the next sync."
        reloadInbox()
    }

    /// Renames the file on the device, in the archive, and in the manifest as
    /// one operation. Requires the device — partial renames would make the next
    /// sync re-pull the file as "new".
    func renameFile(_ item: InboxItem, to rawName: String) async -> Bool {
        guard device != nil else {
            statusLine = "Connect the TP-7 to rename files."
            return false
        }
        let forbidden = CharacterSet(charactersIn: "/|\\:")
        var newName = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: forbidden).joined(separator: "-")
        let ext = (item.originalName as NSString).pathExtension
        if !ext.isEmpty, (newName as NSString).pathExtension.lowercased() != ext.lowercased() {
            newName += ".\(ext)"
        }
        guard !newName.isEmpty, newName != item.originalName else { return false }

        let remotePath = "\(item.lane.remoteFolder)/\(item.originalName)"
        do {
            _ = try await client.rename(remotePath, to: newName)
            var queue = RenameQueue(fileURL: archiveDir.appendingPathComponent("rename-queue.json"))
            queue.removePending(remotePath: remotePath)

            let newURL = item.audioURL.deletingLastPathComponent().appendingPathComponent(newName)
            var localMoveFailed = false
            do {
                try FileManager.default.moveItem(at: item.audioURL, to: newURL)
            } catch {
                localMoveFailed = true
            }

            // The device rename already succeeded, so the ledger key must move
            // regardless — otherwise the next sync mistakes the renamed device
            // file for a new one. If the local move failed, point the entry at
            // whichever path the bytes actually live at, never a missing file.
            var manifest = Manifest(fileURL: archiveDir.appendingPathComponent("manifest.json"))
            if let oldKey = manifestKey(for: item), var entry = manifest.entry(for: oldKey) {
                entry.localPath = localMoveFailed ? item.audioURL.path : newURL.path
                try manifest.rename(oldKey, to: ManifestKey(lane: item.lane, name: newName), entry: entry)
            }
            if localMoveFailed {
                statusLine = "Renamed on the TP-7, but the local file couldn't be moved."
                lastError = "\"\(item.originalName)\" was renamed on the device to \"\(newName)\", but the matching file in the archive couldn't be renamed to match. It's still there under its old name."
            } else {
                statusLine = "Renamed → \(newName)"
            }
            reloadInbox()
            return true
        } catch {
            statusLine = "Rename failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes the device copy only — the archived original is always kept.
    /// Returns success so the UI can show a failure loudly instead of a
    /// status line whisper.
    @discardableResult
    func removeFromDevice(_ item: InboxItem) async -> Bool {
        guard device != nil else {
            statusLine = "Connect the TP-7 to remove files."
            return false
        }
        let remotePath = "\(item.lane.remoteFolder)/\(item.originalName)"
        do {
            try await client.remove(remotePath)
            statusLine = "Removed \(item.originalName) from the TP-7. Archive copy kept."
            log("Removed from device: \(item.originalName)")
            return true
        } catch {
            statusLine = "Remove failed: \(error.localizedDescription)"
            lastError = "Removing \(item.originalName) from the device failed. It may help to unplug and replug the TP-7, then try again."
            return false
        }
    }

    /// Full delete: archive copy and ledger immediately; the device copy via
    /// a tombstone that survives until the removal actually lands, so a sync
    /// can never resurrect a deleted file. Notes already sent are untouched.
    func deleteEverywhere(_ item: InboxItem) async {
        let remotePath = "\(item.lane.remoteFolder)/\(item.originalName)"
        try? FileManager.default.removeItem(at: item.audioURL)
        var manifest = Manifest(fileURL: archiveDir.appendingPathComponent("manifest.json"))
        if let key = manifestKey(for: item) {
            try? manifest.remove(key)
        }
        addPendingRemoteDelete(remotePath)
        reloadInbox()

        if device != nil && !syncing {
            await applyPendingRemoteDeletes()
        }
        if pendingRemoteDeletes().contains(remotePath) {
            statusLine = "Deleted \(item.originalName) here; the device copy goes at the next sync."
        } else {
            statusLine = "Deleted \(item.originalName) everywhere."
        }
        log("Deleted: \(item.originalName)")
    }

    // MARK: Deletion tombstones

    private var deleteQueueURL: URL { archiveDir.appendingPathComponent("delete-queue.json") }

    func pendingRemoteDeletes() -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: deleteQueueURL))) ?? [])
    }

    private func addPendingRemoteDelete(_ remotePath: String) {
        var pending = pendingRemoteDeletes()
        pending.insert(remotePath)
        try? JSONEncoder().encode(Array(pending).sorted()).write(to: deleteQueueURL, options: .atomic)
    }

    func applyPendingRemoteDeletes() async {
        guard device != nil else { return }
        var pending = pendingRemoteDeletes()
        guard !pending.isEmpty else { return }
        for remotePath in pending.sorted() {
            do {
                try await client.remove(remotePath)
                pending.remove(remotePath)
                log("Removed from device: \((remotePath as NSString).lastPathComponent)")
            } catch let TP7Error.commandFailed(_, stderr) where stderr.contains("not found") {
                pending.remove(remotePath)   // already gone: tombstone fulfilled
            } catch {
                log("⚠️ device removal pending for \((remotePath as NSString).lastPathComponent); will retry")
            }
        }
        try? JSONEncoder().encode(Array(pending).sorted()).write(to: deleteQueueURL, options: .atomic)
    }

    /// Pushes audio files into the TP-7 library and mirrors them in the archive.
    func addToLibrary(_ urls: [URL]) async {
        guard device != nil else {
            statusLine = "Connect the TP-7 to add songs."
            return
        }
        let laneDir = archiveDir.appendingPathComponent(Lane.library.rawValue)
        try? FileManager.default.createDirectory(at: laneDir, withIntermediateDirectories: true)
        var added = 0
        for url in urls {
            let name = url.lastPathComponent
            do {
                try await client.push(url, to: "/library/\(name)")
                let archived = laneDir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: archived.path) {
                    try? FileManager.default.copyItem(at: url, to: archived)
                }
                var manifest = Manifest(fileURL: archiveDir.appendingPathComponent("manifest.json"))
                let size = fileSize(archived)
                try? manifest.record(
                    ManifestKey(lane: .library, name: name),
                    entry: ManifestEntry(localPath: archived.path, syncedAt: Date(), size: size)
                )
                added += 1
                log("Added to library: \(name)")
            } catch {
                log("⚠️ \(name): \(error.localizedDescription)")
            }
        }
        statusLine = added > 0 ? "Added \(added) song\(added == 1 ? "" : "s") to the library." : statusLine
        reloadInbox()
    }

    // MARK: Cue edits → device

    /// Cue edits change metadata only; the edited archive file is pushed back
    /// over the device copy at the next opportunity.
    func queueDevicePush(for item: InboxItem) {
        let queueURL = archiveDir.appendingPathComponent("push-queue.json")
        var pending = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: queueURL))) ?? []
        let remotePath = "\(item.lane.remoteFolder)/\(item.originalName)"
        if !pending.contains(remotePath) {
            pending.append(remotePath)
            try? JSONEncoder().encode(pending).write(to: queueURL, options: .atomic)
        }
        Task { await self.applyPendingDevicePushes() }
    }

    private func applyPendingDevicePushes() async {
        guard device != nil else { return }
        let queueURL = archiveDir.appendingPathComponent("push-queue.json")
        let pending = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: queueURL))) ?? []
        guard !pending.isEmpty else { return }
        var remaining: [String] = []
        for remotePath in pending {
            let name = (remotePath as NSString).lastPathComponent
            let lane = Lane.allCases.first { remotePath.hasPrefix($0.remoteFolder + "/") } ?? .recordings
            let localURL = archiveDir.appendingPathComponent(lane.rawValue).appendingPathComponent(name)
            do {
                try await client.push(localURL, to: remotePath, overwrite: true)
                log("Cues updated on device → \(name)")
            } catch {
                remaining.append(remotePath)
            }
        }
        try? JSONEncoder().encode(remaining).write(to: queueURL, options: .atomic)
    }

    // MARK: Inbox

    func reloadInbox() {
        let manifest = Manifest(fileURL: archiveDir.appendingPathComponent("manifest.json"))
        func items(for lane: Lane) -> [InboxItem] {
            manifest.entries
                .filter { $0.key.hasPrefix("\(lane.rawValue)|") }
                .map { key, entry in
                    let parts = key.split(separator: "|")
                    return InboxItem(
                        id: key,
                        lane: lane,
                        originalName: parts.count > 1 ? String(parts[1]) : key,
                        audioURL: URL(fileURLWithPath: entry.localPath),
                        noteURL: entry.notePath.map { URL(fileURLWithPath: $0) },
                        syncedAt: entry.syncedAt,
                        sizeBytes: entry.size ?? 0,
                        title: entry.title,
                        transcript: entry.transcript,
                        summary: entry.summary
                    )
                }
                .sorted { $0.originalName > $1.originalName }
        }
        inboxItems = items(for: .memos).sorted { $0.syncedAt > $1.syncedAt }
        recordingItems = items(for: .recordings)
        libraryItems = items(for: .library)
    }

    // MARK: Helpers

    private func summaryLine(_ summary: SyncSummary, vaultNotes: Int) -> String {
        let memos = summary.newFiles.filter { $0.lane == .memos }.count
        let recordings = summary.newFiles.filter { $0.lane == .recordings }.count
        if summary.newFiles.isEmpty && summary.failures.isEmpty {
            return "Nothing new on the TP-7."
        }
        if summary.newFiles.isEmpty, !summary.failures.isEmpty,
           summary.failures.allSatisfy({ $0.contains("mass-storage mode") }) {
            return "TP-7 is in storage mode, not the mode syncing needs. Power-cycle it to sync."
        }
        var parts: [String] = []
        if memos > 0 { parts.append("\(memos) memo\(memos == 1 ? "" : "s") (\(vaultNotes) → memos folder)") }
        if recordings > 0 { parts.append("\(recordings) recording\(recordings == 1 ? "" : "s") archived") }
        if !summary.failures.isEmpty { parts.append("\(summary.failures.count) failed") }
        return parts.joined(separator: " · ")
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func log(_ message: String) {
        lastSyncLog.append(message)
    }
}
