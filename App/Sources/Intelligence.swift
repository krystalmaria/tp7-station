import Foundation
import AVFoundation
import Speech
import FoundationModels

/// On-device transcription (SpeechAnalyzer) and titling (Foundation Models).
/// Both degrade gracefully: transcription errors surface as empty transcripts
/// (routed to the sound pool), titling falls back to first-words titles.
struct Intelligence: Sendable {

    @MainActor
    static var smartTitlesAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Human-readable status for the Settings caption — makes the "why are my
    /// titles just first words?" mystery visible instead of silent.
    @MainActor
    static var smartTitlesStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Titles and one-line summaries are generated on this Mac by Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Needs Apple Intelligence. Turn it on in System Settings › Apple Intelligence & Siri; until then, titles fall back to the memo's first words."
        default:
            return "Apple Intelligence isn't available on this Mac right now, so titles fall back to the memo's first words."
        }
    }

    func transcribe(_ audioURL: URL) async throws -> String {
        let locale = Locale(identifier: "en_AU")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioURL)

        async let collected: String = transcriber.results.reduce(into: "") { partial, result in
            partial += String(result.text.characters)
        }

        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await collected
    }

    func titleAndSummary(for transcript: String) async -> (title: String, summary: String?)? {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 12 else { return nil }
        guard SystemLanguageModel.default.availability == .available else { return nil }

        do {
            let session = LanguageModelSession(instructions: """
            You title voice memos for a personal notes vault. The title also becomes a \
            filename on a tiny hardware display that truncates after ~14 characters, so \
            put the load-bearing noun FIRST ("pricing wedge doubts", never "some thoughts \
            about the pricing wedge"). Reply with exactly two lines: line 1 is a specific \
            title of at most 7 words, front-loaded, no quotes, no trailing period; line 2 \
            is a one-sentence summary. If the memo is too short to summarise, repeat the \
            gist as the summary.
            """)
            let response = try await session.respond(to: "Voice memo transcript:\n\n\(cleaned)")
            let lines = response.content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = lines.first, !first.isEmpty else { return nil }
            return (title: first, summary: lines.count > 1 ? lines[1] : nil)
        } catch {
            return nil
        }
    }
}
