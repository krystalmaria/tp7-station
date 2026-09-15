import Foundation

public struct ProcessedMemo: Sendable, Equatable {
    public let title: String
    public let noteFilename: String
    public let markdown: String
    public let isSpeech: Bool
}

/// Turns a transcript into a vault note. Transcription and titling are injected
/// so this stays pure and testable; the app supplies SpeechAnalyzer and
/// FoundationModels implementations.
public struct MemoProcessor: Sendable {
    public init() {}

    /// Transcripts this short are treated as non-speech (a soundscape captured
    /// via the memo button) and routed to the sound lane instead of the vault.
    public static let minimumSpeechCharacters = 12

    public func process(
        originalName: String,
        recordedAt: Date?,
        transcript: String,
        title: String?,
        summary: String?,
        audioRelativePath: String
    ) -> ProcessedMemo {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSpeech = cleaned.count >= Self.minimumSpeechCharacters

        let resolvedTitle = Self.normalizeTitle(title) ?? Self.fallbackTitle(from: cleaned, originalName: originalName)
        let stem = (originalName as NSString).deletingPathExtension
        let datePrefix = stem.split(separator: "_").first.map(String.init) ?? "memo"
        let noteFilename = "\(datePrefix)-\(Self.kebab(resolvedTitle)).md"

        var lines: [String] = []
        lines.append("---")
        lines.append("created: \(recordedAt.map { $0.formatted(Self.isoStyle) } ?? "unknown")")
        lines.append("source: tp7")
        lines.append("type: memo")
        lines.append("audio: \(audioRelativePath)")
        lines.append("original-file: \(originalName)")
        lines.append("---")
        lines.append("")
        lines.append("# \(resolvedTitle)")
        lines.append("")
        if let summary, !summary.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        lines.append(cleaned.isEmpty ? "_(no speech detected)_" : cleaned)
        lines.append("")

        return ProcessedMemo(
            title: resolvedTitle,
            noteFilename: noteFilename,
            markdown: lines.joined(separator: "\n"),
            isSpeech: isSpeech
        )
    }

    static func normalizeTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.#"))
        return cleaned.isEmpty ? nil : cleaned
    }

    static func fallbackTitle(from transcript: String, originalName: String) -> String {
        let words = transcript.split(separator: " ").prefix(7)
        if words.isEmpty {
            return (originalName as NSString).deletingPathExtension
        }
        return words.joined(separator: " ")
    }

    public static func kebab(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, ch in
                if ch == "-" && (result.isEmpty || result.hasSuffix("-")) { return }
                result.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Recording datetime from the TP-7 filename convention
    /// (`YYYY-MM-DD_HHMMSS_NNN.wav`) — the only reliable date carrier.
    /// Pre-clock-sync files (1980 epoch) return nil.
    public static func recordedDate(fromFilename name: String) -> Date? {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "_")
        guard parts.count >= 2 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        guard let date = formatter.date(from: "\(parts[0]) \(parts[1])") else { return nil }
        if let year = Calendar.current.dateComponents([.year], from: date).year, year < 2000 {
            return nil
        }
        return date
    }

    static let isoStyle = Date.ISO8601FormatStyle(timeZone: .current)
}
