import Foundation

// MARK: - ManualSample
//
// A single on-demand measurement the user triggered from the band (the HR / SpO₂ /
// stress / temperature apps). Distinct from the all-day series in DailyDetailsParser.

struct ManualSample {
    enum Kind {
        case heartRate     // bpm
        case spo2          // percent (0–100)
        case stress        // stress index (no Apple Health type)
        case temperature   // °C
    }
    let date: Date
    let kind: Kind
    let value: Double
}

// MARK: - ManualSamplesParser
//
// Port of GadgetBridge ManualSamplesParser.java (ACTIVITY_MANUAL_SAMPLES, version 2).
// There is no per-record header: after the 7-byte file id + 1 padding byte the file is a
// flat list of [timestamp: u32 LE][type: u8][value]. The value width depends on the type,
// so an unknown type forces us to abort (we can't know how many bytes to skip).
//
//   0x11 HR · 0x12 SpO₂ · 0x13 stress  → 1-byte value
//   0x44 temperature                    → 4-byte value, centi-°C (e.g. 3674 = 36.74 °C)
//
// A 0 value means "not measured" and is dropped, matching GadgetBridge.

enum ManualSamplesParser {

    private static let typeHR: UInt8          = 0x11
    private static let typeSpO2: UInt8        = 0x12
    private static let typeStress: UInt8      = 0x13
    private static let typeTemperature: UInt8 = 0x44

    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> [ManualSample] {
        guard meta.version == 2, data.count > 4 else { return [] }

        let r = LEReader(Data(data.dropLast(4)))   // strip trailing CRC-32
        r.skip(7)                                   // fileId
        guard r.u8() == 0 else { return [] }        // padding must be 0

        var samples: [ManualSample] = []
        while r.remaining >= 5 {
            let ts   = r.u32()
            let type = r.u8()

            let kind: ManualSample.Kind
            let value: Double
            switch type {
            case typeHR:          kind = .heartRate;   value = Double(r.u8())
            case typeSpO2:        kind = .spo2;        value = Double(r.u8())
            case typeStress:      kind = .stress;      value = Double(r.u8())
            case typeTemperature: kind = .temperature; value = Double(r.i32()) / 100.0
            default:
                return samples   // unknown type — value width unknown, stop parsing
            }

            guard value > 0 else { continue }
            samples.append(ManualSample(date: Date(timeIntervalSince1970: TimeInterval(ts)),
                                        kind: kind, value: value))
        }
        return samples
    }
}
