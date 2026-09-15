import Foundation
import Testing
@testable import AudioMetaKit

/// Builds a minimal TP-7-shaped WAV: fmt + acid + data (+ optional trailing cue),
/// mirroring the chunk layout observed on real device files.
private func makeWave(cueOffsets: [UInt32] = [], audioBytes: Int = 300) -> Data {
    var d = Data("RIFF????WAVE".utf8)

    var fmt = Data()
    fmt.appendLE(UInt16(1))          // pcm
    fmt.appendLE(UInt16(1))          // mono
    fmt.appendLE(UInt32(48000))
    fmt.appendLE(UInt32(48000 * 3))
    fmt.appendLE(UInt16(3))
    fmt.appendLE(UInt16(24))
    d.append(contentsOf: Array("fmt ".utf8)); d.appendLE(UInt32(fmt.count)); d.append(fmt)

    // acid chunk exactly as the TP-7 writes it (110 BPM, 4/4, root 48)
    let acidHex = "01000000300000800000000000000000040004000000dc42"
    let acid = Data(stride(from: 0, to: acidHex.count, by: 2).map {
        UInt8(acidHex.dropFirst($0).prefix(2), radix: 16)!
    })
    d.append(contentsOf: Array("acid".utf8)); d.appendLE(UInt32(acid.count)); d.append(acid)

    let audio = Data(repeating: 0xAB, count: audioBytes)
    d.append(contentsOf: Array("data".utf8)); d.appendLE(UInt32(audio.count)); d.append(audio)

    if !cueOffsets.isEmpty {
        var body = Data()
        body.appendLE(UInt32(cueOffsets.count))
        for (i, offset) in cueOffsets.enumerated() {
            body.appendLE(UInt32(i)); body.appendLE(UInt32(0))
            body.append(contentsOf: Array("data".utf8))
            body.appendLE(UInt32(0)); body.appendLE(UInt32(0)); body.appendLE(offset)
        }
        d.append(contentsOf: Array("cue ".utf8)); d.appendLE(UInt32(body.count)); d.append(body)
    }

    let riffSize = UInt32(d.count - 8)
    d.replaceSubrange(4..<8, with: riffSize.leBytes)
    return d
}

@Test func parsesFormatAcidAndCues() throws {
    let wave = try WaveFile(data: makeWave(cueOffsets: [48000, 96000]))
    #expect(wave.format == .init(channels: 1, sampleRate: 48000, bitsPerSample: 24))
    #expect(wave.acid?.tempo == 110.0)
    #expect(wave.acid?.meterNumerator == 4)
    #expect(wave.cues.map(\.sampleOffset) == [48000, 96000])
    #expect(wave.cues.map(\.id) == [0, 1])
}

@Test func appendsCuesTrailingWithoutTouchingAudio() throws {
    let original = makeWave(cueOffsets: [147387])
    let originalWave = try WaveFile(data: original)
    let deviceRecord = originalWave.cues[0].rawRecord

    let updated = originalWave.appendingCues(at: [576000, 1152000])
    let reread = try WaveFile(data: updated)

    #expect(reread.cues.count == 3)
    #expect(reread.cues[0].rawRecord == deviceRecord)     // device cue preserved verbatim
    #expect(reread.cues.map(\.id) == [0, 1, 2])           // ids continue from device numbering
    #expect(reread.cues.map(\.sampleOffset) == [147387, 576000, 1152000])

    // cue chunk is trailing, audio untouched
    #expect(reread.chunks.last?.id == "cue ")
    let audioOld = original.subdata(in: originalWave.chunks.first { $0.id == "data" }!.bodyRange)
    let audioNew = updated.subdata(in: reread.chunks.first { $0.id == "data" }!.bodyRange)
    #expect(audioOld == audioNew)

    // RIFF size stays consistent
    #expect(Int(updated.readLE(UInt32.self, at: 4)) == updated.count - 8)
}

@Test func appendingToFileWithNoCuesStartsAtZero() throws {
    let wave = try WaveFile(data: makeWave())
    let reread = try WaveFile(data: wave.appendingCues(at: [1000]))
    #expect(reread.cues.map(\.id) == [0])
    #expect(reread.cues[0].sampleOffset == 1000)
}

@Test func replacesCuesForMoveAndDelete() throws {
    let original = try WaveFile(data: makeWave(cueOffsets: [1000, 2000, 3000]))
    let moved = [
        WaveFile.CuePoint(id: 0, position: 0, sampleOffset: 1500),   // moved
        WaveFile.CuePoint(id: 2, position: 2, sampleOffset: 3000),   // kept, one deleted
    ]
    let reread = try WaveFile(data: original.replacingCues(with: moved))
    #expect(reread.cues.map(\.sampleOffset) == [1500, 3000])
    #expect(reread.cues.map(\.id) == [0, 2])
    #expect(reread.chunks.last?.id == "cue ")
    let audioOld = original.bytes.subdata(in: original.chunks.first { $0.id == "data" }!.bodyRange)
    let updated = original.replacingCues(with: moved)
    let rereadFile = try WaveFile(data: updated)
    let audioNew = updated.subdata(in: rereadFile.chunks.first { $0.id == "data" }!.bodyRange)
    #expect(audioOld == audioNew)
}

@Test func rejectsNonWaveData() {
    #expect(throws: WaveFile.ParseError.self) {
        _ = try WaveFile(data: Data("not a wav at all".utf8))
    }
}
