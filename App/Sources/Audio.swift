import Foundation
import AVFoundation
import Observation
import AudioMetaKit

/// Downsampled peak data for waveform rendering. One lane per stereo pair
/// (or mono channel), so multitrack TP-7 files render as stacked lanes.
struct WaveformData: Sendable, Equatable {
    let lanes: [[Float]]
    let duration: TimeInterval
    let sampleRate: Double
}

enum WaveformLoader {
    static func load(_ url: URL, buckets: Int = 900) async throws -> WaveformData {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else { return WaveformData(lanes: [], duration: 0, sampleRate: format.sampleRate) }
            try file.read(into: buffer)

            let channelCount = Int(format.channelCount)
            let laneCount = max(1, (channelCount + 1) / 2)
            let frameCount = Int(buffer.frameLength)
            let step = max(1, frameCount / buckets)
            var lanes: [[Float]] = []

            for lane in 0..<laneCount {
                let channels = [lane * 2, min(lane * 2 + 1, channelCount - 1)]
                var peaks: [Float] = []
                peaks.reserveCapacity(buckets)
                guard let data = buffer.floatChannelData else { break }
                var frame = 0
                while frame < frameCount {
                    var peak: Float = 0
                    let end = min(frame + step, frameCount)
                    for channel in Set(channels) {
                        let samples = data[channel]
                        for index in frame..<end {
                            peak = max(peak, abs(samples[index]))
                        }
                    }
                    peaks.append(peak)
                    frame = end
                }
                lanes.append(peaks)
            }

            return WaveformData(
                lanes: lanes,
                duration: Double(frameCount) / format.sampleRate,
                sampleRate: format.sampleRate
            )
        }.value
    }
}

/// One shared player for the whole app — selecting/playing anything stops the
/// previous sound (the app has one voice, like the device).
@MainActor
@Observable
final class AudioPlayerController {
    private var player: AVAudioPlayer?
    private(set) var currentURL: URL?
    var isPlaying = false

    var duration: TimeInterval { player?.duration ?? 0 }
    var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }

    func toggle(_ url: URL) {
        if currentURL == url, let player {
            if player.isPlaying { player.pause(); isPlaying = false }
            else { player.play(); isPlaying = true }
            return
        }
        play(url)
    }

    func play(_ url: URL) {
        stop()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        player = newPlayer
        currentURL = url
        newPlayer.play()
        isPlaying = true
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration - 0.05))
        if !player.isPlaying { player.play(); isPlaying = true }
    }

    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
        isPlaying = false
    }
}

struct CueMarker: Identifiable, Equatable, Sendable {
    let id: UInt32
    var seconds: TimeInterval
}

/// Cue editing for one WAV: markers in seconds, move with undo, save writes
/// the local archive file (audio bytes untouched — metadata only) and queues
/// a device push for the next moment the TP-7 is present.
@MainActor
@Observable
final class CueEditor {
    private(set) var markers: [CueMarker] = []
    private(set) var canUndo = false
    private(set) var dirty = false
    private var undoStack: [[CueMarker]] = []
    private var wave: WaveFile?
    private var sampleRate: Double = 96000
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var isEditable: Bool { wave != nil }

    func load() async {
        guard fileURL.pathExtension.lowercased() == "wav" else { return }
        let url = fileURL
        // File read + chunk walk off the main thread — these are 30-45MB files.
        let loaded = await Task.detached(priority: .userInitiated) { () -> WaveFile? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? WaveFile(data: data)
        }.value
        guard let parsed = loaded else { return }
        wave = parsed
        sampleRate = Double(parsed.format?.sampleRate ?? 96000)
        markers = parsed.cues.map {
            CueMarker(id: $0.id, seconds: Double($0.sampleOffset) / sampleRate)
        }
    }

    func beginMove() {
        undoStack.append(markers)
        canUndo = true
    }

    func move(id: UInt32, to seconds: TimeInterval) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].seconds = max(0, seconds)
        dirty = true
    }

    @discardableResult
    func add(at seconds: TimeInterval) -> CueMarker {
        undoStack.append(markers)
        canUndo = true
        let nextId = (markers.map(\.id).max()).map { $0 + 1 } ?? 0
        let marker = CueMarker(id: nextId, seconds: max(0, seconds))
        markers.append(marker)
        markers.sort { $0.seconds < $1.seconds }
        dirty = true
        return marker
    }

    func delete(id: UInt32) {
        guard markers.contains(where: { $0.id == id }) else { return }
        undoStack.append(markers)
        canUndo = true
        markers.removeAll { $0.id == id }
        dirty = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        markers = previous
        canUndo = !undoStack.isEmpty
        dirty = true
    }

    /// Discards unsaved edits, restoring the file's saved cues.
    func revert() {
        guard let wave else { return }
        markers = wave.cues.map {
            CueMarker(id: $0.id, seconds: Double($0.sampleOffset) / sampleRate)
        }
        undoStack = []
        canUndo = false
        dirty = false
    }

    /// Writes the updated cue chunk into the local file. Returns true when a
    /// device push should be queued.
    func save() -> Bool {
        guard dirty, let wave else { return false }
        let cues = markers
            .sorted { $0.seconds < $1.seconds }
            .map { WaveFile.CuePoint(id: $0.id, position: $0.id, sampleOffset: UInt32($0.seconds * sampleRate)) }
        let updated = wave.replacingCues(with: cues)
        do {
            try updated.write(to: fileURL, options: .atomic)
            self.wave = try WaveFile(data: updated)
            dirty = false
            return true
        } catch {
            return false
        }
    }
}
