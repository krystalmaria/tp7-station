import Foundation

/// Append-only reader/writer for the WAV metadata the TP-7 actually uses,
/// decoded from real device output (2026-09-01, firmware 1.1.11):
/// - `fmt `: standard PCM format info
/// - `acid`: 24-byte standard chunk carrying tempo/meter (device default 110 BPM, 4/4)
/// - `cue `: standard cue chunk, written by the device TRAILING the `data`
///   chunk, with ids counted from 0. Audio bytes are never touched.
public struct WaveFile: Sendable {
    public struct Format: Sendable, Equatable {
        public let channels: UInt16
        public let sampleRate: UInt32
        public let bitsPerSample: UInt16
    }

    public struct CuePoint: Sendable, Equatable {
        public let id: UInt32
        public let position: UInt32
        public let sampleOffset: UInt32
        /// The verbatim 24-byte record, kept so device-written cues survive
        /// re-serialization byte-for-byte.
        public let rawRecord: Data

        public init(id: UInt32, position: UInt32, sampleOffset: UInt32) {
            self.id = id
            self.position = position
            self.sampleOffset = sampleOffset
            var record = Data()
            record.appendLE(id)
            record.appendLE(position)
            record.append(contentsOf: Array("data".utf8))
            record.appendLE(UInt32(0))
            record.appendLE(UInt32(0))
            record.appendLE(sampleOffset)
            self.rawRecord = record
        }

        init?(rawRecord: Data) {
            guard rawRecord.count == 24 else { return nil }
            self.rawRecord = rawRecord
            self.id = rawRecord.readLE(UInt32.self, at: 0)
            self.position = rawRecord.readLE(UInt32.self, at: 4)
            self.sampleOffset = rawRecord.readLE(UInt32.self, at: 20)
        }
    }

    public struct Acid: Sendable, Equatable {
        public let tempo: Float
        public let meterNumerator: UInt16
        public let meterDenominator: UInt16
        public let rootNote: UInt16
    }

    struct Chunk {
        let id: String
        let bodyRange: Range<Int>
    }

    public let format: Format?
    public let acid: Acid?
    public let cues: [CuePoint]
    let chunks: [Chunk]
    let bytes: Data

    /// All chunk ids in file order — surfaced so unknown TP-7 chunks (loop
    /// data candidates) can be logged and investigated when they appear.
    public var chunkIds: [String] { chunks.map(\.id) }

    public enum ParseError: Error {
        case notRiffWave
        case truncatedChunk(String)
    }

    public init(data: Data) throws {
        guard data.count >= 12,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8)
        else { throw ParseError.notRiffWave }

        var chunks: [Chunk] = []
        var pos = 12
        while pos + 8 <= data.count {
            let id = String(decoding: data.subdata(in: pos..<(pos + 4)), as: UTF8.self)
            let size = Int(data.readLE(UInt32.self, at: pos + 4))
            let bodyStart = pos + 8
            guard bodyStart + size <= data.count else { throw ParseError.truncatedChunk(id) }
            chunks.append(Chunk(id: id, bodyRange: bodyStart..<(bodyStart + size)))
            pos = bodyStart + size + (size & 1)
        }

        var format: Format?
        var acid: Acid?
        var cues: [CuePoint] = []
        for chunk in chunks {
            let body = data.subdata(in: chunk.bodyRange)
            switch chunk.id {
            case "fmt " where body.count >= 16:
                format = Format(
                    channels: body.readLE(UInt16.self, at: 2),
                    sampleRate: body.readLE(UInt32.self, at: 4),
                    bitsPerSample: body.readLE(UInt16.self, at: 14)
                )
            case "acid" where body.count >= 24:
                acid = Acid(
                    tempo: Float(bitPattern: body.readLE(UInt32.self, at: 20)),
                    meterNumerator: body.readLE(UInt16.self, at: 18),
                    meterDenominator: body.readLE(UInt16.self, at: 16),
                    rootNote: body.readLE(UInt16.self, at: 4)
                )
            case "cue " where body.count >= 4:
                let count = Int(body.readLE(UInt32.self, at: 0))
                for index in 0..<count {
                    let start = 4 + index * 24
                    guard start + 24 <= body.count else { break }
                    if let cue = CuePoint(rawRecord: body.subdata(in: start..<(start + 24))) {
                        cues.append(cue)
                    }
                }
            default:
                break
            }
        }

        self.format = format
        self.acid = acid
        self.cues = cues
        self.chunks = chunks
        self.bytes = data
    }

    /// Returns the file with `newCues` appended after any existing cues, in the
    /// device's native shape: one trailing `cue ` chunk after `data`, existing
    /// device-written records preserved verbatim, ids continuing from the
    /// current maximum. Audio bytes are untouched.
    public func appendingCues(at sampleOffsets: [UInt32]) -> Data {
        let nextId = (cues.map(\.id).max()).map { $0 + 1 } ?? 0
        let added = sampleOffsets.enumerated().map { index, offset in
            CuePoint(id: nextId + UInt32(index), position: nextId + UInt32(index), sampleOffset: offset)
        }
        return serialize(cues: cues + added)
    }

    /// Returns the file with the cue chunk replaced wholesale (moved/deleted
    /// markers). Unchanged cues keep their verbatim records; audio untouched.
    public func replacingCues(with newCues: [CuePoint]) -> Data {
        serialize(cues: newCues)
    }

    private func serialize(cues all: [CuePoint]) -> Data {

        var stripped = Data()
        stripped.append(bytes.prefix(12))
        for chunk in chunks where chunk.id != "cue " {
            let size = chunk.bodyRange.count
            stripped.append(bytes.subdata(in: (chunk.bodyRange.lowerBound - 8)..<chunk.bodyRange.lowerBound))
            stripped.append(bytes.subdata(in: chunk.bodyRange))
            if size & 1 == 1 { stripped.append(0) }
        }

        var cueBody = Data()
        cueBody.appendLE(UInt32(all.count))
        for cue in all { cueBody.append(cue.rawRecord) }
        stripped.append(contentsOf: Array("cue ".utf8))
        stripped.appendLE(UInt32(cueBody.count))
        stripped.append(cueBody)

        var out = stripped
        let riffSize = UInt32(out.count - 8)
        out.replaceSubrange(4..<8, with: riffSize.leBytes)
        return out
    }
}

extension Data {
    func readLE<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type, at offset: Int) -> T {
        let start = startIndex + offset
        var value: T = 0
        for byte in self[start..<(start + MemoryLayout<T>.size)].reversed() {
            value = (value << 8) | T(byte)
        }
        return value
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        append(contentsOf: value.leBytes)
    }
}

extension FixedWidthInteger {
    var leBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
