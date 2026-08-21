import Foundation

// MARK: - SleepDetailsParser
//
// Parses the binary sleep file returned by Mi Band 10. Faithful port of GadgetBridge
// SleepDetailsParser.java (XiaomiActivityFileFetcher → SleepDetailsParser).
//
// File layout (received from activity characteristic after CRC-32 validation):
//
//   [0..6]   XiaomiActivityFileId (7 bytes)
//   [7]      padding (expect 0x00)
//   [...]    header bitmask: 1 byte (versions 1–4) or 2 bytes (version 5).
//            validData(header, i) gates whether optional field `i` is present.
//   then, in order (each gated/sized by version + header bits):
//     isAwake (u8), bedTime (u32 LE), wakeupTime (u32 LE),
//     sleepQuality (v≥4), bedTime2/wakeupTime2 block (v≥5),
//     Heart-rate section, SpO₂ section, snore section (v≥3),
//     then interleaved stage packets.
//
// Each section: [unit: u16 LE][count: u16 LE]([firstRecordTime: u32 LE] if v≥2)[samples].
//   HR/SpO₂ samples are one u8 each; sample i timestamp = firstRecordTime + unit·i (seconds).
//   Snore samples are 4 bytes each (skipped).
//
// Stage packet header (17 bytes):
//   [0..3]   magic = 0xFFFCFAFB read **little-endian** → on-wire bytes FB FA FC FF
//   [4]      headerLen (= 17)
//   [5..12]  ts (Int64 LE, seconds for types 16/17)
//   [13]     parity
//   [14]     type
//   [15..16] dataLen (UInt16 **big-endian**)
//   [17..]   payload (dataLen bytes, big-endian fields)
//
// Stage packet types: 16 = summary, 17 = stages. Types 2/3/9/12/13/14/15 are flag-only
// (no payload). Type 1 (RR intervals) is ignored — HR comes from the header HR section.
//
// Type 17 entries are UInt16 BE: bits[15:12] = stage, bits[11:0] = duration_minutes of
// that stage. The stage starts at the running cursor; the cursor advances by the duration.
// Stage codes: 0 awake · 1 light · 2 deep · 3 rem · 4 not-sleeping (skipped).

struct ParsedSleep {
    var sessions: [SleepSession] = []
    var heartRates: [(date: Date, bpm: Int)] = []
    var spo2: [(date: Date, pct: Int)] = []
}

enum SleepDetailsParser {

    private static let stagePacketLen = 17

    // MARK: - Public API

    /// Parses a complete, CRC-validated sleep file. `meta.version` selects the header layout.
    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> ParsedSleep {
        var result = ParsedSleep()
        guard data.count > 4 else { return result }

        let version = meta.version
        let headerSize = version == 5 ? 2 : 1

        // Strip trailing CRC-32 before parsing fixed-length sections.
        let r = LEReader(Data(data.dropLast(4)))
        r.skip(7)                              // fileId
        _ = r.u8()                             // padding (expected 0)

        var header = [UInt8]()
        for _ in 0 ..< headerSize { header.append(r.u8()) }

        var headerIdx = 0
        _ = r.u8(); headerIdx += 1             // isAwake
        let bedTime = Int(r.i32()); headerIdx += 1
        let wakeupTime = Int(r.i32()); headerIdx += 1

        if version >= 4 {
            if validData(header, headerIdx) { _ = r.u8() }   // sleepQuality
            headerIdx += 1
        }
        if version >= 5 {
            r.skip(9)
            _ = r.i32()                        // bedTime2
            _ = r.i32()                        // wakeupTime2
            headerIdx += 5
        }

        // Heart-rate samples recorded during sleep — the data Apple Health's sleep
        // "Comparisons" tab correlates against the sleep window.
        if validData(header, headerIdx) {
            result.heartRates = readSamples(r, version: version, bedTime: bedTime, range: 30...250)
                .map { (date: $0.0, bpm: $0.1) }
        }
        headerIdx += 1

        // SpO₂ samples during sleep.
        if validData(header, headerIdx) {
            result.spo2 = readSamples(r, version: version, bedTime: bedTime, range: 50...100)
                .map { (date: $0.0, pct: $0.1) }
        }
        headerIdx += 1

        // Snore section (v≥3) — 4 bytes/sample, skipped.
        if version >= 3 {
            if validData(header, headerIdx) {
                _ = r.u16()                    // unit
                let count = Int(r.u16())
                if count > 0 {
                    if version >= 2 { _ = r.i32() }
                    r.skip(count * 4)
                }
            }
            headerIdx += 1
        }

        // Stage packets.
        guard bedTime > 0, wakeupTime > bedTime else { return result }
        let sessionStart = Date(timeIntervalSince1970: TimeInterval(bedTime))
        let sessionEnd   = Date(timeIntervalSince1970: TimeInterval(wakeupTime))

        var stages: [SleepPhase] = []
        var summaryMinutes: (deep: Int, light: Int, rem: Int, wake: Int)?

        while r.remaining >= stagePacketLen {
            guard scanForStageMagic(r) else { break }   // leaves cursor after the 4 magic bytes
            guard r.remaining >= 13 else { break }

            _ = r.u8()                          // headerLen (== 17)
            let ts = r.i64()                    // seconds (LE)
            _ = r.u8()                          // parity
            let type = Int(r.u8())
            let dataLen = (Int(r.u8()) << 8) | Int(r.u8())   // big-endian

            // Flag-only packets: the dataLen bytes are flags, no payload follows.
            if [0x2, 0x3, 0x9, 0xC, 0xD, 0xE, 0xF].contains(type) { continue }
            guard dataLen >= 0, r.remaining >= dataLen else { break }
            let payload = r.read(dataLen)

            switch type {
            case 16: summaryMinutes = parseSleepSummary(payload)
            case 17: stages.append(contentsOf: parseSleepStages(payload, base: TimeInterval(ts)))
            default: break                      // type 1 (RR intervals) etc. — ignored
            }
        }

        if !stages.isEmpty {
            let sanitized = sanitizeStages(stages)
            result.sessions = [SleepSession(startDate: sessionStart, endDate: sessionEnd,
                                            phases: sanitized, rawDataHash: hashOf(data))]
        } else if let s = summaryMinutes {
            let phases = buildPhasesFromSummary(start: sessionStart,
                                                deepMin: s.deep, lightMin: s.light,
                                                remMin: s.rem, wakeMin: s.wake)
            if !phases.isEmpty {
                result.sessions = [SleepSession(startDate: sessionStart, endDate: sessionEnd,
                                                phases: phases, rawDataHash: hashOf(data))]
            }
        }
        return result
    }

    // MARK: - HR / SpO₂ section

    private static func readSamples(_ r: LEReader, version: Int, bedTime: Int,
                                    range: ClosedRange<Int>) -> [(Date, Int)] {
        let unit = Int(r.u16())
        let count = Int(r.u16())
        guard count > 0 else { return [] }
        let rawFirst = version >= 2 ? Int(r.u32()) : bedTime
        let first: Int
        if rawFirst > 1_500_000_000 {
            first = rawFirst
        } else if bedTime > 1_500_000_000 && rawFirst > 0 && rawFirst < 86400 {
            let bedDate = Date(timeIntervalSince1970: TimeInterval(bedTime))
            let dayStart = Calendar.current.startOfDay(for: bedDate).timeIntervalSince1970
            first = Int(dayStart) + rawFirst
        } else {
            first = bedTime
        }
        var out: [(Date, Int)] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let v = Int(r.u8())
            guard range.contains(v) else { continue }
            let sampleTime = TimeInterval(first + unit * i)
            guard sampleTime > 1_500_000_000 else { continue }
            out.append((Date(timeIntervalSince1970: sampleTime), v))
        }
        return out
    }

    // MARK: - Stage packet magic finder
    //
    // Sliding 4-byte search for FB FA FC FF (0xFFFCFAFB little-endian), matching
    // GadgetBridge readStagePacketHeader. Leaves the cursor just past the magic.

    private static func scanForStageMagic(_ r: LEReader) -> Bool {
        var b0: UInt8 = 0, b1: UInt8 = 0, b2: UInt8 = 0, b3: UInt8 = 0
        var filled = 0
        while r.remaining > 0 {
            b0 = b1; b1 = b2; b2 = b3; b3 = r.u8()
            filled += 1
            if filled >= 4 && b0 == 0xFB && b1 == 0xFA && b2 == 0xFC && b3 == 0xFF { return true }
        }
        return false
    }

    // MARK: - Type 0x11 (17): Sleep stages

    private static func parseSleepStages(_ data: Data, base: TimeInterval) -> [SleepPhase] {
        guard data.count >= 2 else { return [] }
        var phases: [SleepPhase] = []
        var cursor = base
        let count = data.count / 2

        for idx in 0 ..< count {
            let word        = data.readUInt16BE(at: idx * 2)
            let stageRaw    = UInt8(word >> 12)        // bits [15:12]
            let durationMin = Int(word & 0x0FFF)       // bits [11:0]

            let start = Date(timeIntervalSince1970: cursor)
            cursor += TimeInterval(durationMin * 60)
            let end = Date(timeIntervalSince1970: cursor)

            guard end > start else { continue }        // zero-length marker

            let stage: SleepPhaseType
            switch stageRaw {
            case 0: stage = .awake
            case 1: stage = .light
            case 2: stage = .deep
            case 3: stage = .rem
            default: continue                           // 4 = not sleeping, others
            }
            phases.append(SleepPhase(startDate: start, endDate: end, type: stage))
        }
        return phases
    }

    // MARK: - Type 0x10 (16): Sleep summary
    //
    //   byte[0]:   (sleep_index << 4) | wake_count
    //   [1..2]:    sleep_duration (minutes, UInt16 BE)
    //   [3..4]:    wake_duration
    //   [5..6]:    light_duration
    //   [7..8]:    rem_duration
    //   [9..10]:   deep_duration

    private static func parseSleepSummary(_ data: Data) -> (deep: Int, light: Int, rem: Int, wake: Int)? {
        guard data.count >= 11 else { return nil }
        return (
            deep:  Int(data.readUInt16BE(at: 9)),
            light: Int(data.readUInt16BE(at: 5)),
            rem:   Int(data.readUInt16BE(at: 7)),
            wake:  Int(data.readUInt16BE(at: 3))
        )
    }

    // MARK: - Fallback: synthesise phases from the summary durations

    private static func buildPhasesFromSummary(
        start: Date, deepMin: Int, lightMin: Int, remMin: Int, wakeMin: Int
    ) -> [SleepPhase] {
        var phases: [SleepPhase] = []
        var cursor = start

        func add(_ type: SleepPhaseType, minutes: Int) {
            guard minutes > 0 else { return }
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            phases.append(SleepPhase(startDate: cursor, endDate: end, type: type))
            cursor = end
        }

        add(.light, minutes: lightMin)
        add(.deep,  minutes: deepMin)
        add(.rem,   minutes: remMin)
        add(.awake, minutes: wakeMin)
        return phases
    }

    // MARK: - Helpers

    /// Eliminates overlapping phases caused by cumulative Xiaomi stage packets.
    private static func sanitizeStages(_ stages: [SleepPhase]) -> [SleepPhase] {
        let sorted = stages.sorted { $0.startDate < $1.startDate }
        var merged: [SleepPhase] = []
        for s in sorted {
            guard s.endDate > s.startDate else { continue }
            if let last = merged.last, s.startDate < last.endDate {
                if s.endDate <= last.endDate { continue }
                merged.append(SleepPhase(startDate: last.endDate, endDate: s.endDate, type: s.type))
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// header bit `i`: byte `i/8`, MSB-first within the byte.
    private static func validData(_ header: [UInt8], _ i: Int) -> Bool {
        let byteIdx = i / 8
        guard byteIdx < header.count else { return false }
        return (header[byteIdx] & (1 << (7 - (i % 8)))) != 0
    }

    /// FNV-1a 64-bit over the whole file. The previous XOR-fold collapsed to a single byte
    /// (0–255), so distinct nights collided and `persistIfNew` silently dropped legitimate new
    /// sessions from SwiftData (Apple Health was unaffected — it always rewrites).
    private static func hashOf(_ data: Data) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}

// MARK: - Data reading helpers

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        let base = startIndex + offset
        return (UInt16(self[base]) << 8) | UInt16(self[base + 1])
    }
}
