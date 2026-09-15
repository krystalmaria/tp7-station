import Foundation
import Testing
@testable import InboxKit

@Test func producesVaultNoteWithFrontmatterAndTranscript() {
    let memo = MemoProcessor().process(
        originalName: "2026-09-01_101500_000.wav",
        recordedAt: MemoProcessor.recordedDate(fromFilename: "2026-09-01_101500_000.wav"),
        transcript: "I keep treating hobbies as things to master.",
        title: "Deliberately pointless hobbies",
        summary: "Keep one hobby where enjoyment beats mastery.",
        audioRelativePath: "audio/2026-09-01_101500_000.wav"
    )
    #expect(memo.isSpeech)
    #expect(memo.noteFilename == "2026-09-01-deliberately-pointless-hobbies.md")
    #expect(memo.markdown.contains("source: tp7"))
    #expect(memo.markdown.contains("# Deliberately pointless hobbies"))
    #expect(memo.markdown.contains("## Transcript"))
    #expect(memo.markdown.contains("audio: audio/2026-09-01_101500_000.wav"))
}

@Test func shortTranscriptRoutesAsNonSpeech() {
    let memo = MemoProcessor().process(
        originalName: "2026-09-01_101500_000.wav",
        recordedAt: nil,
        transcript: "  hm  ",
        title: nil,
        summary: nil,
        audioRelativePath: "audio/x.wav"
    )
    #expect(!memo.isSpeech)
}

@Test func fallbackTitleUsesFirstWords() {
    let memo = MemoProcessor().process(
        originalName: "2026-09-01_101500_000.wav",
        recordedAt: nil,
        transcript: "remember to check the ferry timetable for the island trip next weekend",
        title: nil,
        summary: nil,
        audioRelativePath: "audio/x.wav"
    )
    #expect(memo.title == "remember to check the ferry timetable for")
}

@Test func filenameDateParsingHandlesPreClockSyncFiles() {
    #expect(MemoProcessor.recordedDate(fromFilename: "1980-01-01_000020_000.wav") == nil)
    let date = MemoProcessor.recordedDate(fromFilename: "2026-08-29_205704_000.wav")
    #expect(date != nil)
    let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date!)
    #expect(comps.year == 2026)
    #expect(comps.month == 8)
    #expect(comps.day == 29)
    #expect(comps.hour == 20)
}
