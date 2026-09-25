import Foundation

// MARK: - DailySummary
//
// Daily aggregate metrics for one day. Ported from GadgetBridge DailySummaryParser.java
// (versions 3 and 5). Timestamps are unix seconds; a 0 timestamp / 0 value means "not
// measured" and is exposed as nil.

struct DailySummary {
    let date: Date
    var steps: Int
    var caloriesKcal: Int
    var restingHR: Int?
    var avgHR: Int?
    var maxHR: (bpm: Int, at: Date)?
    var minHR: (bpm: Int, at: Date)?
    var avgStress: Int?
    var spo2Max: (pct: Int, at: Date)?
    var spo2Min: (pct: Int, at: Date)?
    var spo2Avg: Int?
    /// 24-bit mask: bit `h` set ⇒ the user stood up during hour `h` (00:00–01:00 = bit 0).
    var standingHours: Int?
}

enum DailySummaryParser {

    /// Parses a CRC-validated daily-summary activity file (fileId stripped of trailing CRC by caller
    /// is NOT required — we skip the leading 7 id bytes + padding ourselves).
    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> DailySummary? {
        let headerSize: Int
        switch meta.version {
        case 3: headerSize = 3
        case 5: headerSize = 4
        default: return nil      // unknown layout — let the caller fall back to details
        }

        let r = LEReader(data)
        r.skip(7)                // fileId
        guard r.u8() == 0 else { return nil }  // padding must be 0
        r.skip(headerSize)       // header bitmask (unused here)

        // Every field below through spo2Avg (41 bytes) plus the file's trailing CRC-32, which the
        // assembled buffer keeps. LEReader yields 0 past the end, so a shorter file would otherwise
        // parse CRC bytes and made-up zeros into SpO₂ and get ACKed.
        guard r.remaining >= 41 + 4 else { return nil }

        let steps = Int(r.i32())
        r.skip(3)                            // unk1..3
        let hrResting = r.u8()
        let hrMax     = r.u8()
        let hrMaxTs   = r.u32()
        let hrMin     = r.u8()
        let hrMinTs   = r.u32()
        let hrAvg     = r.u8()
        let stressAvg = r.u8()
        _ = r.u8()                           // stressMax
        _ = r.u8()                           // stressMin
        // 24-bit standing-hours mask (1 bit per hour, LSB = 00:00–01:00).
        let standB0 = Int(r.u8()), standB1 = Int(r.u8()), standB2 = Int(r.u8())
        let standing = (standB0 | (standB1 << 8) | (standB2 << 16)) & 0x00FF_FFFF
        let calories  = Int(r.i16())
        r.skip(3)                            // unk7..9
        let spo2Max   = r.u8()
        let spo2MaxTs = r.u32()
        let spo2Min   = r.u8()
        let spo2MinTs = r.u32()
        let spo2Avg   = r.u8()

        var s = DailySummary(date: meta.timestamp, steps: max(0, steps),
                             caloriesKcal: max(0, calories))
        s.restingHR = (hrResting > 0 && hrResting < 220) ? Int(hrResting) : nil
        s.avgHR     = (hrAvg > 0 && hrAvg < 220) ? Int(hrAvg) : nil
        s.avgStress = stressAvg > 0 && stressAvg != 255 ? Int(stressAvg) : nil
        if hrMax > 0, hrMax < 250, hrMaxTs > 1_500_000_000 { s.maxHR = (Int(hrMax), Date(timeIntervalSince1970: TimeInterval(hrMaxTs))) }
        if hrMin > 0, hrMin < 250, hrMinTs > 1_500_000_000 { s.minHR = (Int(hrMin), Date(timeIntervalSince1970: TimeInterval(hrMinTs))) }
        if (50...100).contains(spo2Max), spo2MaxTs > 1_500_000_000 { s.spo2Max = (Int(spo2Max), Date(timeIntervalSince1970: TimeInterval(spo2MaxTs))) }
        if (50...100).contains(spo2Min), spo2MinTs > 1_500_000_000 { s.spo2Min = (Int(spo2Min), Date(timeIntervalSince1970: TimeInterval(spo2MinTs))) }
        s.spo2Avg = (50...100).contains(spo2Avg) ? Int(spo2Avg) : nil
        s.standingHours = standing > 0 ? standing : nil
        return s
    }
}

// MARK: - Little-endian byte cursor
//
// A class (reference semantics) so a single cursor can be shared between an outer
// loop and the bit-group parser in DailyDetailsParser.

final class LEReader {
    private let data: Data
    private var pos: Int
    init(_ data: Data) { self.data = data; self.pos = data.startIndex }

    var remaining: Int { data.endIndex - pos }
    var offset: Int { pos - data.startIndex }
    func skip(_ n: Int) { pos += n }

    func u8() -> UInt8 {
        guard pos < data.endIndex else { return 0 }
        defer { pos += 1 }
        return data[pos]
    }
    func u16() -> UInt16 {
        let lo = UInt16(u8()), hi = UInt16(u8())
        return lo | (hi << 8)
    }
    func i16() -> Int16 { Int16(bitPattern: u16()) }
    func u32() -> UInt32 {
        let b0 = UInt32(u8()), b1 = UInt32(u8()), b2 = UInt32(u8()), b3 = UInt32(u8())
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    func i32() -> Int32 { Int32(bitPattern: u32()) }
    func f32() -> Float { Float(bitPattern: u32()) }   // IEEE-754 little-endian
    func u64() -> UInt64 {
        let lo = UInt64(u32()), hi = UInt64(u32())
        return lo | (hi << 32)
    }
    func i64() -> Int64 { Int64(bitPattern: u64()) }

    /// Reads `n` bytes (clamped to what remains) and advances the cursor.
    func read(_ n: Int) -> Data {
        let start = pos
        let end = Swift.min(pos + Swift.max(0, n), data.endIndex)
        pos = end
        return data.subdata(in: start ..< end)
    }
}
