import Foundation

// MARK: - XiaomiActivityFileMeta
//
// The 7-byte activity file id that prefixes every activity file (and is used to
// request it). Confirmed from GadgetBridge XiaomiActivityFileId.java:
//
//   [0..3] timestamp (UInt32 LE, unix seconds)
//   [4]    timezone  (Int8, 15-minute blocks)
//   [5]    version   (UInt8)
//   [6]    flags: bit7 = type (0=ACTIVITY, 1=SPORTS)
//                 bits6..2 = subtype  ((flags & 127) >> 2)
//                 bits1..0 = detailType (flags & 3: 0=DETAILS, 1=SUMMARY, 2=GPS)

struct XiaomiActivityFileMeta {

    enum Kind { case activity, sports, unknown }
    enum Detail: Int { case details = 0, summary = 1, gps = 2, unknown = -1 }

    // Activity subtypes
    static let subtypeDaily: Int       = 0x00
    static let subtypeSleepStages: Int = 0x03
    static let subtypeManual: Int      = 0x06
    static let subtypeSleep: Int       = 0x08

    let timestamp: Date
    let timezone: Int
    let version: Int
    let type: Kind
    let subtype: Int
    let detail: Detail

    init?(_ id: Data) {
        guard id.count >= 7 else { return nil }
        let base = id.startIndex
        let ts = UInt32(id[base]) | (UInt32(id[base + 1]) << 8)
               | (UInt32(id[base + 2]) << 16) | (UInt32(id[base + 3]) << 24)
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
        self.timezone  = Int(Int8(bitPattern: id[base + 4]))
        self.version   = Int(id[base + 5])
        let flags = id[base + 6]
        self.type    = ((flags >> 7) & 1) == 0 ? .activity : .sports
        self.subtype = Int((flags & 127) >> 2)
        self.detail  = Detail(rawValue: Int(flags & 3)) ?? .unknown
    }

    var isSleep: Bool {
        type == .activity && (subtype == Self.subtypeSleepStages || subtype == Self.subtypeSleep)
    }
    var isDailySummary: Bool {
        type == .activity && subtype == Self.subtypeDaily && detail == .summary
    }
    var isDailyDetails: Bool {
        type == .activity && subtype == Self.subtypeDaily && detail == .details
    }
    /// On-demand single measurements (HR/SpO₂/stress/temperature) taken from the band's apps.
    var isManualSamples: Bool {
        type == .activity && subtype == Self.subtypeManual
    }
    /// A workout/sport session. `detail` distinguishes the summary record from its GPS track.
    var isWorkoutSummary: Bool { type == .sports && detail == .summary }
    var isWorkoutGps: Bool     { type == .sports && detail == .gps }
    /// The per-second sensor series recorded during a workout (e.g. subtype 8 = heart rate).
    var isWorkoutDetails: Bool { type == .sports && detail == .details }
}
