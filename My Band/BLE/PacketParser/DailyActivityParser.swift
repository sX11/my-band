import Foundation

// MARK: - ActivityMinuteSample
//
// One minute of activity detail. Fields are nil when "not measured" for that minute.

struct ActivityMinuteSample {
    let date: Date
    var steps: Int? = nil
    var caloriesKcal: Int? = nil
    var distanceMeters: Double? = nil
    var heartRate: Int? = nil
    var spo2: Int? = nil
    var stress: Int? = nil
}

// MARK: - XiaomiBitGroupReader
//
// Port of GadgetBridge XiaomiComplexActivityParser. A nibble in the per-record header
// gates each "group": bit 0x8 = group present, bits 0x4/0x2/0x1 = sub-fields 0/1/2 valid.
// When present, the group consumes a fixed 8/16/32-bit value from the shared cursor.

final class XiaomiBitGroupReader {
    private let header: [UInt8]
    private let buf: LEReader
    private var currentGroup = -1
    private var currentGroupBits = 0
    private var currentVal = 0

    init(header: [UInt8], buf: LEReader) {
        self.header = header
        self.buf = buf
    }

    func reset() { currentGroup = -1; currentGroupBits = 0; currentVal = 0 }

    /// Advances to the next group of `nBits`. Returns whether the group exists.
    func nextGroup(_ nBits: Int) -> Bool {
        currentGroup += 1
        if currentGroup >= header.count * 2 {
            _ = consume(nBits)   // keep the buffer advancing to avoid an infinite loop
            return false
        }
        if (currentNibble & 8) == 0 { return false }
        currentGroupBits = nBits
        currentVal = consume(nBits)
        return (currentNibble & 8) != 0
    }

    private func consume(_ nBits: Int) -> Int {
        switch nBits {
        case 8:  return Int(buf.u8())
        case 16: return Int(buf.u16())
        case 32: return Int(buf.i32())
        default: return 0
        }
    }

    private var currentNibble: Int {
        let byte = currentGroup / 2
        guard byte < header.count else { return 0 }
        return currentGroup % 2 == 0 ? (Int(header[byte]) & 0xF0) >> 4 : Int(header[byte]) & 0x0F
    }

    func hasFirst() -> Bool  { isValid(0) }
    func hasSecond() -> Bool { isValid(1) }
    func hasThird() -> Bool  { isValid(2) }

    private func isValid(_ idx: Int) -> Bool { (currentNibble & (1 << (2 - idx))) != 0 }

    func get(_ idx: Int, _ nBits: Int) -> Int {
        let shift = currentGroupBits - idx - nBits
        guard shift >= 0 else { return 0 }
        return (currentVal & (((1 << nBits) - 1) << shift)) >> shift
    }
}

// MARK: - DailyDetailsParser
//
// Port of GadgetBridge DailyDetailsParser.java — per-minute steps/calories/distance/HR/SpO₂.
// NOTE: validate on hardware. In particular GadgetBridge treats the per-minute `steps`
// field as that minute's sample value; if real totals look off we revisit cumulative vs delta.

enum DailyDetailsParser {

    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> [ActivityMinuteSample] {
        let headerSize: Int
        switch meta.version {
        case 1, 2: headerSize = 4
        case 3:    headerSize = 5
        case 4:    headerSize = 6
        default:   return []
        }
        guard data.count > 4 else { return [] }

        // Discard trailing CRC-32, then skip fileId(7) + padding(1) + header(headerSize).
        let body = data.dropLast(4)
        let r = LEReader(Data(body))
        r.skip(7)
        guard r.u8() == 0 else { return [] }
        var header = [UInt8]()
        for _ in 0 ..< headerSize { header.append(r.u8()) }

        let parser = XiaomiBitGroupReader(header: header, buf: r)
        var samples: [ActivityMinuteSample] = []
        var minute = meta.timestamp
        let version = meta.version

        // Cap iterations defensively (one day = 1440 minutes).
        var guardCount = 0
        while r.remaining > 0 && guardCount < 2000 {
            guardCount += 1
            let startOffset = r.offset
            parser.reset()

            var steps: Int?
            var calories: Int?
            var distanceMeters: Double?
            var hr: Int?
            var spo2: Int?
            var stress: Int?
            var includeExtra = 0

            if parser.nextGroup(16) {
                if parser.hasSecond() { includeExtra = parser.get(1, 1) }
                if parser.hasThird()  { steps = parser.get(2, 14) }
            }
            if parser.nextGroup(8) {
                if parser.hasSecond() { calories = parser.get(2, 6) }
            }
            _ = parser.nextGroup(8)                       // unknown
            if parser.nextGroup(16) {
                if parser.hasFirst() { distanceMeters = Double(parser.get(0, 16)) }  // value is metres
            }
            if parser.nextGroup(8) {
                if parser.hasFirst() { hr = parser.get(0, 8) }
            }
            if parser.nextGroup(8) {
                if parser.hasFirst() { _ = parser.get(0, 8) } // energy — not mapped
            }
            _ = parser.nextGroup(16)                      // unknown
            if version >= 3 {
                if parser.nextGroup(8) {
                    if parser.hasFirst() { spo2 = parser.get(0, 8) }
                }
                if parser.nextGroup(8) {
                    if parser.hasFirst() {
                        let s = parser.get(0, 8)
                        if s != 255 { stress = s }
                    }
                }
            }
            if includeExtra == 1 { _ = r.u8() }
            if version >= 4 {
                _ = parser.nextGroup(16)                  // light
                _ = parser.nextGroup(16)                  // body momentum
            }

            samples.append(ActivityMinuteSample(
                date: minute, steps: zeroNil(steps), caloriesKcal: zeroNil(calories),
                distanceMeters: distanceMeters.map { $0 }, heartRate: zeroNil(hr),
                spo2: zeroNil(spo2), stress: stress
            ))

            minute = minute.addingTimeInterval(60)
            if r.offset == startOffset { break }          // no progress — stop
        }
        return samples
    }

    private static func zeroNil(_ v: Int?) -> Int? {
        guard let v, v > 0 else { return nil }
        return v
    }
}
