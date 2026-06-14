import Foundation

// MARK: - SleepDetailsParser
//
// Parses the binary sleep file returned by Mi Band 10 (confirmed from GadgetBridge
// SleepDetailsParser.java and XiaomiActivityFileFetcher.java).
//
// File layout (received from activity characteristic 0053 after CRC-32 validation):
//
//   [0..6]   XiaomiActivityFileId (7 bytes)
//   [7]      padding (expect 0x00)
//   [8]      header bitmask (bit5=hasHR, bit4=hasSpO2, bit3=hasSnore[v3+])
//   [9]      isAwake (0=sleeping, 1=awake/not finished)
//   [10..13] bedTime (UInt32 LE, Unix seconds)
//   [14..17] wakeupTime (UInt32 LE, Unix seconds)
//   [18]     sleepQuality (if version >= 4)
//   ... optional HR/SpO2/snore sections (skipped here)
//
// After the header sections, stage packets appear interleaved, each preceded by:
//   MAGIC = 0xfffcfafb (UInt32 BE) → bytes [0xFF, 0xFC, 0xFA, 0xFB]
//
// Stage packet header (17 bytes total):
//   [0..3]   magic = 0xfffcfafb
//   [4]      headerLen (= 17)
//   [5..12]  ts (Int64, seconds)
//   [13]     parity
//   [14]     type
//   [15..16] dataLen (UInt16 BE: (byte15 << 8) | byte16)
//
// Known types:
//   0x10 (16) — Sleep summary:   total/deep/light/rem/wake durations (minutes, UInt16 BE)
//   0x11 (17) — Sleep stages:    array of UInt16 BE entries
//                                 bits[15:12] = stage, bits[11:0] = offset_minutes
//
// Stage codes (type 17):
//   0 → awake
//   1 → light sleep
//   2 → deep sleep
//   3 → REM sleep
//   4 → not sleeping

enum SleepDetailsParser {

    private static let stageMagic: [UInt8] = [0xFF, 0xFC, 0xFA, 0xFB]
    private static let headerLen = 17

    // MARK: - Public API

    /// Parses a complete, CRC-validated activity file into SleepSession objects.
    static func parse(_ data: Data) -> [SleepSession] {
        guard data.count >= 18 else { return [] }

        // Extract bedTime and wakeupTime from fixed header offsets
        let bedTime    = data.readUInt32LE(at: 10)
        let wakeupTime = data.readUInt32LE(at: 14)
        guard bedTime > 0, wakeupTime > bedTime else { return [] }

        let sessionStart = Date(timeIntervalSince1970: TimeInterval(bedTime))
        let sessionEnd   = Date(timeIntervalSince1970: TimeInterval(wakeupTime))

        // Scan for stage packets
        var stages: [SleepPhase] = []
        var summaryMinutes: (deep: Int, light: Int, rem: Int, wake: Int)?

        var i = 18  // start after fixed header (conservative; real start depends on header bitmask)
        while i <= data.count - headerLen {
            guard let magic = findMagic(in: data, from: i) else { break }
            i = magic

            let type    = data[i + 14]
            let dataLen = Int(data[i + 15]) << 8 | Int(data[i + 16])
            let dataStart = i + headerLen
            let dataEnd   = dataStart + dataLen
            guard dataEnd <= data.count else { i += headerLen; continue }

            let ts = data.readInt64BE(at: i + 5)  // seconds

            switch type {
            case 0x11:  // Sleep stages
                let stagePhases = parseSleepStages(
                    data.subdata(in: dataStart ..< dataEnd),
                    baseTimestamp: TimeInterval(ts)
                )
                stages.append(contentsOf: stagePhases)

            case 0x10:  // Sleep summary
                summaryMinutes = parseSleepSummary(data.subdata(in: dataStart ..< dataEnd))

            default:
                break
            }

            i = dataEnd
        }

        if !stages.isEmpty {
            return [SleepSession(startDate: sessionStart, endDate: sessionEnd,
                                 phases: stages, rawDataHash: hashOf(data))]
        }

        // Fallback: build from summary if no stage detail available
        if let summary = summaryMinutes {
            let phases = buildPhasesFromSummary(
                start:    sessionStart,
                deepMin:  summary.deep,
                lightMin: summary.light,
                remMin:   summary.rem,
                wakeMin:  summary.wake
            )
            if !phases.isEmpty {
                return [SleepSession(startDate: sessionStart, endDate: sessionEnd,
                                     phases: phases, rawDataHash: hashOf(data))]
            }
        }

        return []
    }

    // MARK: - Stage packet magic finder

    private static func findMagic(in data: Data, from start: Int) -> Int? {
        for i in start ... (data.count - stageMagic.count) {
            if data[i] == 0xFF && data[i+1] == 0xFC && data[i+2] == 0xFA && data[i+3] == 0xFB {
                return i
            }
        }
        return nil
    }

    // MARK: - Type 0x11: Sleep stages

    private static func parseSleepStages(_ data: Data, baseTimestamp: TimeInterval) -> [SleepPhase] {
        guard data.count >= 2 else { return [] }
        var phases: [SleepPhase] = []
        let count = data.count / 2

        for idx in 0 ..< count {
            let word      = data.readUInt16BE(at: idx * 2)
            let stageRaw  = UInt8(word >> 12)      // bits [15:12]
            let offsetMin = Int(word & 0x0FFF)     // bits [11:0]

            let stage: SleepPhaseType
            switch stageRaw {
            case 0: stage = .awake
            case 1: stage = .light
            case 2: stage = .deep
            case 3: stage = .rem
            default: continue   // 4=notSleep, others — skip
            }

            let phaseStart = Date(timeIntervalSince1970: baseTimestamp + TimeInterval(offsetMin * 60))
            // Duration = gap to next entry (or 1 minute stub for last)
            let nextOffsetMin: Int
            if idx + 1 < count {
                let nextWord = data.readUInt16BE(at: (idx + 1) * 2)
                nextOffsetMin = Int(nextWord & 0x0FFF)
            } else {
                nextOffsetMin = offsetMin + 1
            }
            let durationMin = max(1, nextOffsetMin - offsetMin)
            let phaseEnd = phaseStart.addingTimeInterval(TimeInterval(durationMin * 60))

            phases.append(SleepPhase(startDate: phaseStart, endDate: phaseEnd, type: stage))
        }
        return phases
    }

    // MARK: - Type 0x10: Sleep summary
    //
    // Data layout (UInt16 BE each unless noted):
    //   byte[0]:   (sleep_index << 4) | wake_count
    //   [1..2]:    sleep_duration (minutes)
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

    // MARK: - Fallback: build phases from summary (no detail stages)

    private static func buildPhasesFromSummary(
        start: Date,
        deepMin: Int, lightMin: Int, remMin: Int, wakeMin: Int
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

    // MARK: - Dedup hash

    private static func hashOf(_ data: Data) -> Int {
        data.prefix(64).reduce(into: 0) { $0 ^= Int($1) }
    }
}

// MARK: - Data reading helpers

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        return UInt32(self[offset])
             | (UInt32(self[offset + 1]) << 8)
             | (UInt32(self[offset + 2]) << 16)
             | (UInt32(self[offset + 3]) << 24)
    }

    func readInt64BE(at offset: Int) -> Int64 {
        guard offset + 7 < count else { return 0 }
        var result: Int64 = 0
        for i in 0 ..< 8 {
            result = (result << 8) | Int64(self[offset + i])
        }
        return result
    }
}
