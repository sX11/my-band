import Foundation

// MARK: - SleepPacketParser
//
// Parses the binary sleep payload returned by Mi Band 10 via the XiaomiSppPacketV2 protocol.
//
// Format confirmed from GadgetBridge XiaomiSleepService.java:
//
//   Sleep stage entries (2 bytes each, big-endian UInt16):
//     bits 15–12 (top nibble): sleep stage
//       0 = awake
//       1 = light (core)
//       2 = deep
//       3 = REM
//     bits 11–0: offset in minutes from the session base timestamp
//
//   The payload may include a details header (Type 16) at a known byte offset:
//     bytes 18–19: total duration (UInt16, minutes)
//     bytes 20–23: bedtime (UInt32 BE, Unix seconds)
//     bytes 24–27: waketime (UInt32 BE, Unix seconds)
//     bytes 31–32: deep duration (UInt16, minutes)
//     bytes 33–34: light duration (UInt16, minutes)
//     bytes 35–36: REM duration (UInt16, minutes)
//     bytes 37–38: awake duration (UInt16, minutes)
//
// ⚠️ Byte layout and stage codes must be verified against a real Mi Band 10 capture.
//    Use a BLE sniffer or raw-logging mode to obtain a fixture.
//    Update kStageMap and header offsets below if needed.

enum SleepPacketParser {

    // MARK: - Calibration constants

    private static let kEntrySize = 2   // 2 bytes per stage entry (UInt16 BE)
    private static let kSessionGapThreshold: Double = 30   // minutes

    private static let kStageMap: [UInt8: SleepPhaseType] = [
        0: .awake,
        1: .light,
        2: .deep,
        3: .rem,
    ]

    // MARK: - Public API

    /// Parses a raw payload into SleepSession objects.
    /// Returns an empty array if the payload is malformed or unrecognized — never throws.
    static func parse(_ data: Data) -> [SleepSession] {
        // Try the details-header format first (has bedtime/waketime embedded)
        if let sessions = parseDetailsFormat(data), !sessions.isEmpty { return sessions }
        // Fallback: raw entry-only format
        return parseRawEntries(data)
    }

    // MARK: - Details header format (Type 16)

    private static func parseDetailsFormat(_ data: Data) -> [SleepSession]? {
        guard data.count >= 38 else { return nil }

        let bedtime  = data.readUInt32BE(at: 20)
        let waketime = data.readUInt32BE(at: 24)
        guard bedtime > 0, waketime > bedtime else { return nil }

        let base = Date(timeIntervalSince1970: TimeInterval(bedtime))
        let end  = Date(timeIntervalSince1970: TimeInterval(waketime))

        // Entries start after the 38-byte header
        let entriesStart = 38
        guard data.count > entriesStart else {
            // No entries — construct a single session from header data only
            let totalMinutes = Int(data.readUInt16BE(at: 18))
            let deepMin  = Int(data.readUInt16BE(at: 31))
            let lightMin = Int(data.readUInt16BE(at: 33))
            let remMin   = Int(data.readUInt16BE(at: 35))
            let awakeMin = Int(data.readUInt16BE(at: 37))
            let phases = buildPhasesFromSummary(
                base: base, totalMinutes: totalMinutes,
                deepMin: deepMin, lightMin: lightMin, remMin: remMin, awakeMin: awakeMin
            )
            return [makeSession(phases: phases, start: base, end: end)]
        }

        let entryData = data.subdata(in: entriesStart..<data.count)
        let phases = decodeEntries(entryData, base: base)
        guard !phases.isEmpty else { return nil }
        return [makeSession(phases: phases, start: base, end: end)]
    }

    // MARK: - Raw entries format

    private static func parseRawEntries(_ data: Data) -> [SleepSession] {
        guard data.count >= kEntrySize else { return [] }
        guard data.count % kEntrySize == 0 else { return [] }

        // First entry's offset anchors the base timestamp.
        // Without an absolute timestamp we use a relative epoch and note the limitation.
        // ⚠️ When real capture is available, determine the actual base timestamp source.
        let base = Date()   // placeholder — replace with actual session timestamp from sync command response

        let phases = decodeEntries(data, base: base)
        return assembleSessions(from: phases)
    }

    // MARK: - Entry decoder

    private static func decodeEntries(_ data: Data, base: Date) -> [SleepPhase] {
        var phases: [SleepPhase] = []
        let count = data.count / kEntrySize

        for i in 0..<count {
            let word = data.readUInt16BE(at: i * kEntrySize)
            let stageRaw   = UInt8(word >> 12)          // bits 15–12
            let offsetMin  = Int(word & 0x0FFF)         // bits 11–0
            let stage = kStageMap[stageRaw] ?? .awake

            let start = base.addingTimeInterval(TimeInterval(offsetMin * 60))
            // Duration: inferred as gap to next entry (or a default for the last entry)
            let nextOffset: Int
            if i + 1 < count {
                let nextWord = data.readUInt16BE(at: (i + 1) * kEntrySize)
                nextOffset = Int(nextWord & 0x0FFF)
            } else {
                nextOffset = offsetMin + 1  // 1-minute stub for last entry
            }
            let durationMin = max(1, nextOffset - offsetMin)
            let end = start.addingTimeInterval(TimeInterval(durationMin * 60))

            phases.append(SleepPhase(startDate: start, endDate: end, type: stage))
        }
        return phases
    }

    // MARK: - Session assembly

    private static func assembleSessions(from phases: [SleepPhase]) -> [SleepSession] {
        guard !phases.isEmpty else { return [] }
        var sessions: [SleepSession] = []
        var current: [SleepPhase] = []

        for phase in phases {
            if !current.isEmpty, phase.type == .awake {
                let gap = phase.startDate.timeIntervalSince(current.last!.endDate) / 60
                if gap >= kSessionGapThreshold {
                    sessions.append(makeSession(phases: current, start: current.first!.startDate, end: current.last!.endDate))
                    current = []
                }
            }
            current.append(phase)
        }
        if !current.isEmpty {
            sessions.append(makeSession(phases: current, start: current.first!.startDate, end: current.last!.endDate))
        }
        return sessions
    }

    private static func makeSession(phases: [SleepPhase], start: Date, end: Date) -> SleepSession {
        let hash = phases.reduce(into: 0) { $0 ^= $1.startDate.hashValue ^ $1.type.hashValue }
        return SleepSession(startDate: start, endDate: end, phases: phases, rawDataHash: hash)
    }

    // MARK: - Phase builder from summary (no individual entries)

    private static func buildPhasesFromSummary(
        base: Date, totalMinutes: Int,
        deepMin: Int, lightMin: Int, remMin: Int, awakeMin: Int
    ) -> [SleepPhase] {
        var phases: [SleepPhase] = []
        var cursor = base

        func addPhase(_ type: SleepPhaseType, minutes: Int) {
            guard minutes > 0 else { return }
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            phases.append(SleepPhase(startDate: cursor, endDate: end, type: type))
            cursor = end
        }

        addPhase(.light, minutes: lightMin)
        addPhase(.deep,  minutes: deepMin)
        addPhase(.rem,   minutes: remMin)
        addPhase(.awake, minutes: awakeMin)
        return phases
    }
}

// MARK: - Data reading helpers

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        return (UInt32(self[offset])     << 24)
             | (UInt32(self[offset + 1]) << 16)
             | (UInt32(self[offset + 2]) <<  8)
             |  UInt32(self[offset + 3])
    }
}
