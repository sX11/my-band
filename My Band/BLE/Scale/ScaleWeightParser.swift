import Foundation

// MARK: - ScaleReading

struct ScaleReading {
    let weightKg: Double
    /// The scale sets this once the weight has settled; non-final frames stream while you step on.
    let isFinal: Bool
}

// MARK: - ScaleWeightParser
//
// Decodes the weight an OKOK/Chipsea BLE scale publishes in its advertisement manufacturer data.
// Port of the weight paths in homeassistant-okokscale (Apache-2.0). Validated on hardware (2026-06-23)
// against a "Yoda1" scale, which is broadcast-only (no GATT) and uses the VC0 variant: the company-id
// low byte is 0xC0 and the 13-byte payload carries only weight — impedance/body composition are NOT
// available to the phone, so only weight is decoded.
//
// `data` is the full BLE manufacturer data: [companyId: UInt16 LE][payload…].

enum ScaleWeightParser {

    static func parse(_ data: Data) -> ScaleReading? {
        guard data.count >= 2 else { return nil }
        let base = data.startIndex
        let companyId = UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
        let payload = data.subdata(in: (base + 2) ..< data.endIndex)

        // VC0: matched by the low byte being 0xC0 (mirrors the integration's `key & 0xFF == 0xC0`).
        if (companyId & 0xFF) == 0xC0 { return parseVC0(payload) }
        return nil
    }

    // VC0: 13-byte payload. weight = bytes[0..1] BE, scaled by the unit in byte[6]; byte[6] bit0 = final.
    private static func parseVC0(_ d: Data) -> ScaleReading? {
        guard d.count == 13 else { return nil }
        let b = d.startIndex
        let msb = UInt16(d[b + 0])
        let lsb = UInt16(d[b + 1])
        let raw = (msb << 8) | lsb
        let props = d[b + 6]
        let isFinal = (props & 1) == 1

        let weightKg: Double
        switch (props >> 3) & 0x3 {
        case 0:                                                  // kg
            weightKg = Double(raw) / 100.0
        case 2:                                                  // lb
            weightKg = Double(raw) / 10.0 * Self.lbToKg
        case 3:                                                  // st:lb
            weightKg = (Double(d[b + 0]) * 14 + Double(d[b + 1]) / 10.0) * Self.lbToKg
        default:
            return nil
        }
        return ScaleReading(weightKg: weightKg, isFinal: isFinal)
    }

    private static let lbToKg = 0.45359237
}
