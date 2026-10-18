import Foundation
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "WorkoutParser")

// MARK: - WorkoutKind
//
// The sport types Mi Band 10 records: one kind per HealthKit activity type, with every
// GadgetBridge workoutType code that has one folded onto it. HealthKit mapping lives in
// HealthKitManager.
// Raw values are stored in each workout's Health metadata: renaming a case orphans old workouts.

enum WorkoutKind: String {
    case running, walking, hiking, trekking, trailRun, treadmill
    case outdoorCycling, indoorCycling
    case freeTraining, hiit, yoga
    case strengthTraining                               // Strength training (workoutType 308, freestyle layout)
    case poolSwim, openWaterSwim
    case elliptical, rowing, rowingMachine, jumpRoping
    case triathlon, sailing, paddleSports, waterPolo, waterSports, diving, surfing, climbing,
         skating, stairClimbing, stairs, stepTraining, coreTraining, flexibility, pilates,
         gymnastics, crossTraining, mixedCardio, functionalStrength, dance, boxing, wrestling,
         martialArts, taiChi, kickboxing, fencing, soccer, basketball, volleyball, baseball,
         softball, americanFootball, hockey, tableTennis, badminton, tennis, cricket, handball,
         bowling, squash, golf, curling, snowSports, snowboarding, downhillSkiing, archery,
         equestrian, fishing, discSports
    case other

    /// Whether a phone GPS stream is useful for this sport. Indoor / stationary sports (strength,
    /// yoga, treadmill, pool, machines…) gain nothing from it — the app replies "GPS disabled" so
    /// the band starts them immediately instead of waiting for, and recording, a fix it won't use.
    var usesGps: Bool {
        switch self {
        case .running, .trailRun, .walking, .hiking, .trekking, .outdoorCycling, .openWaterSwim,
             .triathlon, .climbing, .hockey, .sailing, .paddleSports, .waterSports, .surfing,
             .skating, .soccer, .baseball, .softball, .americanFootball, .cricket, .golf, .snowSports, .snowboarding,
             .downhillSkiing, .equestrian, .fishing, .discSports:
            return true
        case .treadmill, .indoorCycling, .freeTraining, .hiit, .yoga, .strengthTraining, .poolSwim,
             .elliptical, .rowing, .rowingMachine, .jumpRoping, .waterPolo, .diving,
             .stairClimbing, .stairs, .stepTraining, .coreTraining, .flexibility, .pilates,
             .gymnastics, .crossTraining, .mixedCardio, .functionalStrength, .dance, .boxing,
             .wrestling, .martialArts, .taiChi, .kickboxing, .fencing, .basketball, .volleyball,
             .tableTennis, .badminton, .tennis, .handball, .bowling, .squash, .curling,
             .archery, .other:
            return false
        }
    }
}

// MARK: - WorkoutSummary
//
// A parsed workout. `fields` holds every decoded numeric field keyed by WorkoutKey; typed
// accessors expose the ones HealthKit consumes. Time/HR-zone fields stay in `fields` for
// future UI without bloating this struct.

struct WorkoutSummary {
    var kind: WorkoutKind
    var startDate: Date
    var endDate: Date
    var swimStyle: String?
    var fields: [String: Double] = [:]
    let rawDataHash: Int

    var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
    var activeSeconds: Double?  { fields[WorkoutKey.activeSeconds] }
    var caloriesKcal: Double?   { positive(WorkoutKey.calories) }
    var distanceMeters: Double? { positive(WorkoutKey.distance) }
    var steps: Double?          { positive(WorkoutKey.steps) }
    var strokes: Double?        { positive(WorkoutKey.strokes) }
    var vo2Max: Double?         { positive(WorkoutKey.vo2max) }
    var hrAvg: Double?          { positive(WorkoutKey.hrAvg) }
    var hrMax: Double?          { positive(WorkoutKey.hrMax) }
    var hrMin: Double?          { positive(WorkoutKey.hrMin) }

    private func positive(_ key: String) -> Double? {
        guard let v = fields[key], v > 0 else { return nil }
        return v
    }
}

enum WorkoutKey {
    static let timeStart     = "startTime"
    static let timeEnd       = "endTime"
    static let activeSeconds = "activeSeconds"
    static let calories      = "calories"
    static let caloriesTotal = "caloriesTotal"
    static let distance      = "distanceMeters"
    static let steps         = "steps"
    static let strokes       = "strokes"
    static let laps          = "laps"
    static let jumps         = "jumps"
    static let vo2max        = "vo2max"
    static let hrAvg         = "hrAvg"
    static let hrMax         = "hrMax"
    static let hrMin         = "hrMin"
    static let speedAvg      = "speedAvg"
    static let speedMax      = "speedMax"
    static let swimStyle     = "swimStyle"
    static let workoutType   = "xiaomiWorkoutType"
}

// MARK: - WorkoutSummaryParser
//
// Port of GadgetBridge WorkoutSummaryParser.java + XiaomiSimpleActivityParser.java. The
// summary file is a flat little-endian record whose field layout depends on (subtype,
// version). Each per-sport builder describes that layout; `addUnknown` skips padding.
//
// Note (matching GadgetBridge): the header's per-field validity bits are NOT used to gate
// reads — the unknown-field lengths aren't fully identified, so honouring the header would
// desync the cursor. We read every field positionally and let `fields` hold whatever decodes.

enum WorkoutSummaryParser {

    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> WorkoutSummary? {
        // Trailing CRC-32 is left in place — fields are read positionally and stop well before it.
        let r = LEReader(data)
        r.skip(7)                              // fileId
        guard r.u8() == 0 else { return nil }  // padding

        guard let blueprint = blueprint(subtype: meta.subtype, version: meta.version) else {
            log.warning("WorkoutSummaryParser: no blueprint for subtype=0x\(String(meta.subtype, radix: 16)) version=\(meta.version) — skipped")
            return nil
        }

        var kind = blueprint.defaultKind
        r.skip(blueprint.headerSize)

        var fields: [String: Double] = [:]
        var endEpoch: Double?
        var swimStyle: String?

        for field in blueprint.fields {
            guard let value = field.read(r) else { continue }   // unknown/skip field
            guard let key = field.key else { continue }
            switch key {
            case WorkoutKey.timeStart:
                break                                            // ignored — start comes from the file id
            case WorkoutKey.timeEnd:
                endEpoch = value
            case WorkoutKey.swimStyle:
                swimStyle = Self.swimStyleName(Int(value))
            case WorkoutKey.workoutType:
                let code = Int(value)
                log.debug("WorkoutSummaryParser: workoutType code=\(code) subtype=0x\(String(meta.subtype, radix: 16)) version=\(meta.version)")
                if let mapped = workoutKind(fromCode: code) { kind = mapped }
                fields[key] = value
            default:
                fields[key] = value
            }
        }

        let start = meta.timestamp
        let end = endEpoch.map { Date(timeIntervalSince1970: $0) } ?? start
        log.info("WorkoutSummaryParser: subtype=0x\(String(meta.subtype, radix: 16)) version=\(meta.version) → kind=\(String(describing: kind)) workoutTypeField=\(fields[WorkoutKey.workoutType].map { String(Int($0)) } ?? "absent")")
        return WorkoutSummary(kind: kind, startDate: start,
                              endDate: end > start ? end : start,
                              swimStyle: swimStyle, fields: fields,
                              rawDataHash: hashOf(data))
    }

    // MARK: - Builder

    private struct Field {
        let key: String?
        let read: (LEReader) -> Double?
    }

    private final class Blueprint {
        var headerSize = 0
        var defaultKind: WorkoutKind = .other
        var fields: [Field] = []

        @discardableResult func header(_ n: Int) -> Blueprint { headerSize = n; return self }
        @discardableResult func kind(_ k: WorkoutKind) -> Blueprint { defaultKind = k; return self }
        @discardableResult func byte(_ k: String) -> Blueprint { fields.append(Field(key: k) { Double($0.u8()) }); return self }
        @discardableResult func short(_ k: String, _ mult: Double = 1) -> Blueprint { fields.append(Field(key: k) { Double($0.i16()) * mult }); return self }
        @discardableResult func int(_ k: String) -> Blueprint { fields.append(Field(key: k) { Double($0.i32()) }); return self }
        @discardableResult func float(_ k: String) -> Blueprint { fields.append(Field(key: k) { Double($0.f32()) }); return self }
        @discardableResult func skip(_ n: Int) -> Blueprint { fields.append(Field(key: nil) { $0.skip(n); return nil }); return self }
    }

    // Shared tail: the five HR-zone durations every workout ends with.
    private static func hrZones(_ b: Blueprint) {
        b.int("hrZoneExtreme").int("hrZoneAnaerobic").int("hrZoneAerobic")
         .int("hrZoneFatBurn").int("hrZoneWarmUp")
    }

    private static func hrTriple(_ b: Blueprint) {
        b.byte(WorkoutKey.hrAvg).byte(WorkoutKey.hrMax).byte(WorkoutKey.hrMin)
    }

    // MARK: - Per-(subtype, version) blueprints

    private static func blueprint(subtype: Int, version: Int) -> Blueprint? {
        switch subtype {
        case 0x01: return outdoorWalkingV1(version, kind: .running)   // SPORTS_OUTDOOR_RUNNING
        case 0x02: return outdoorWalkingV1(version, kind: .walking)   // SPORTS_OUTDOOR_WALKING_V1
        case 0x03: return treadmill(version)
        case 0x06: return outdoorCyclingV2(version)
        case 0x07: return indoorCycling(version)
        case 0x08: return freestyle(version)
        case 0x09: return poolSwimming(version)
        case 0x10: return hiit(version)
        case 0x0B: return elliptical(version)
        case 0x0D: return rowing(version)
        case 0x0E: return jumpRoping(version)
        case 0x16: return outdoorWalkingV2(version)
        case 0x17: return outdoorCycling(version)
        default:   return nil
        }
    }

    private static func freestyle(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 5:           headerSize = 3
        case 7:           headerSize = 5
        case 8, 9, 10:    headerSize = 6
        default:          return nil
        }
        let b = Blueprint().header(headerSize).kind(.freeTraining)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        if version > 5 { b.skip(6) }
        b.float("trainingEffectAerobic")
        if version > 6 { b.skip(1) }
        b.skip(1).short("recoveryTime")
        hrZones(b)
        if version == 5 {
            b.skip(10).short(WorkoutKey.workoutType).skip(2).int("configuredTimeGoal").short("configuredCaloriesGoal")
        } else {
            b.skip(2).skip(4).float("trainingEffectAnaerobic").skip(1)
             .short(WorkoutKey.workoutType).skip(2).int("configuredTimeGoal").short("configuredCaloriesGoal")
             .short("workoutLoad").skip(1)
            if version > 7 { b.byte("vitalityGain") }
        }
        return b
    }

    private static func indoorCycling(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 8: headerSize = 7
        case 9: headerSize = 8
        default: return nil
        }
        let b = Blueprint().header(headerSize).kind(.indoorCycling)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .skip(4).short(WorkoutKey.calories).skip(4)
        hrTriple(b)
        b.float("trainingEffectAerobic").skip(1).skip(1).short("recoveryTime")
        hrZones(b)
        b.skip(2).skip(4).float("trainingEffectAnaerobic").skip(3)
         .int("configuredTimeGoal").short("configuredCaloriesGoal").short("maximumCaloriesGoal")
         .skip(28).short("workoutLoad").skip(24).byte("configuredSets").skip(13)
        return b
    }

    private static func outdoorWalkingV1(_ version: Int, kind: WorkoutKind) -> Blueprint? {
        guard version == 4 else { return nil }
        let b = Blueprint().header(4).kind(kind)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).int(WorkoutKey.calories)
         .int("paceMax").int("paceMin").skip(4).int(WorkoutKey.steps).skip(2)
        hrTriple(b)
        b.skip(20).float("recoveryValue").skip(9).byte("recoveryTime").skip(2)
        hrZones(b)
        b.int("configuredTimeGoal")
        return b
    }

    private static func outdoorWalkingV2(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 1:    headerSize = 5
        case 4:    headerSize = 7
        case 5, 6: headerSize = 9
        case 9:    headerSize = 13
        default:   return nil
        }
        let b = Blueprint().header(headerSize).kind(.walking)
        b.short(WorkoutKey.workoutType)
         .int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .skip(4).int(WorkoutKey.distance).short(WorkoutKey.caloriesTotal).short(WorkoutKey.calories)
        if version >= 5 { b.int("paceAvgSecKm") }
        b.int("paceMax").int("paceMin")
        if version >= 5 { b.float(WorkoutKey.speedAvg) }
        b.float(WorkoutKey.speedMax).int(WorkoutKey.steps)
        if version >= 5 { b.short("stepLengthAvg").short("stepRateAvg") }
        b.short("stepRateMax")
        hrTriple(b)
        if version == 1 {
            b.skip(33)
        } else {
            b.skip(20).float("trainingEffectAerobic").skip(1).float("trainingEffectAnaerobic")
            if version >= 9 { b.skip(6).byte(WorkoutKey.vo2max).skip(2) } else { b.skip(4) }
            b.short("recoveryTime").skip(1)
        }
        hrZones(b)
        if version >= 9 {
            b.skip(46).short("workoutLoad").skip(15).short("activeScore").skip(17)
             .short("avgGroundContactTime").short("minGroundContactTime").skip(6)
             .short("avgVerticalRatio", 0.1).short("minVerticalRatio", 0.1)
             .short("maxVerticalOscillation").short("avgVerticalOscillation").short("minVerticalOscillation")
        }
        return b
    }

    private static func outdoorCycling(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 4, 5: headerSize = 6
        case 6:    headerSize = 7
        default:   return nil
        }
        let b = Blueprint().header(headerSize).kind(.outdoorCycling)
        b.short(WorkoutKey.workoutType)
         .int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .skip(4).int(WorkoutKey.distance).skip(2).short(WorkoutKey.calories).skip(4).skip(4)
        if version >= 5 { b.float(WorkoutKey.speedAvg) }
        b.float(WorkoutKey.speedMax)
        hrTriple(b)
        b.float("elevationGain").float("elevationLoss").float("altitudeAvg").float("altitudeMax").float("altitudeMin")
         .float("trainingEffectAerobic").skip(1).float("trainingEffectAnaerobic").skip(1)
         .byte(WorkoutKey.vo2max).skip(1).skip(1).short("recoveryTime").skip(1)
        hrZones(b)
        return b
    }

    private static func outdoorCyclingV2(_ version: Int) -> Blueprint? {
        guard version == 4 else { return nil }
        let b = Blueprint().header(5).kind(.outdoorCycling)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).short(WorkoutKey.calories).skip(8).float(WorkoutKey.speedMax)
        hrTriple(b)
        b.skip(28)
        hrZones(b)
        b.skip(18).skip(2).skip(6)
        return b
    }

    private static func hiit(_ version: Int) -> Blueprint? {
        guard version == 5 else { return nil }
        let b = Blueprint().header(4).kind(.hiit)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        b.float("trainingEffectAerobic").skip(1).skip(1).short("recoveryTime")
        hrZones(b)
        return b
    }

    private static func poolSwimming(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 6: headerSize = 4
        case 7: headerSize = 5
        case 8: headerSize = 8
        default: return nil
        }
        let b = Blueprint().header(headerSize).kind(.poolSwim)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).short(WorkoutKey.calories)
        if version >= 7 { b.skip(4) }
        b.skip(11).short(WorkoutKey.strokes).byte(WorkoutKey.swimStyle)
        if version >= 7 { b.skip(1) }
        b.skip(1).short(WorkoutKey.laps).short("swolfAvg").short("minSwolf").byte("configuredLaneLength").skip(6)
         .int("configuredTimeGoal").short("configuredCaloriesGoal").skip(8).short("configuredLengthsGoal").skip(13)
         .byte("vitalityGain")
        return b
    }

    private static func elliptical(_ version: Int) -> Blueprint? {
        guard (3...6).contains(version) else { return nil }
        let b = Blueprint().header(4).kind(.elliptical)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories).int(WorkoutKey.steps)
        if version >= 6 { b.short("cadenceAvg") }
        b.short("cadenceMax")
        hrTriple(b)
        b.skip(7)
        if version >= 4 { b.skip(1) }
        hrZones(b)
        return b
    }

    private static func rowing(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 4:    headerSize = 4
        case 6, 7: headerSize = 5
        default:   return nil
        }
        let b = Blueprint().header(headerSize).kind(.rowingMachine)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        b.skip(7)
        if version > 4 { b.skip(1) }
        hrZones(b)
        b.skip(2).int(WorkoutKey.strokes).int("strokeRateAvg").skip(4)
        return b
    }

    private static func treadmill(_ version: Int) -> Blueprint? {
        let headerSize: Int
        switch version {
        case 5:  headerSize = 4
        case 10: headerSize = 8
        case 11: headerSize = 9
        default: return nil
        }
        let b = Blueprint().header(headerSize).kind(.treadmill)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .int(WorkoutKey.distance).short(WorkoutKey.calories)
        if version >= 10 { b.int("paceAvgSecKm") }
        b.int("paceMax").int("paceMin").int(WorkoutKey.steps)
        if version >= 10 { b.skip(2).short("cadenceAvg") }
        b.short("cadenceMax")
        hrTriple(b)
        b.float("trainingEffectAerobic")
        if version >= 10 { b.skip(1) }
        b.byte(WorkoutKey.vo2max)
        if version >= 10 { b.skip(1) }
        b.skip(1).short("recoveryTime")
        hrZones(b)
        return b
    }

    private static func jumpRoping(_ version: Int) -> Blueprint? {
        guard version == 3 || version == 5 else { return nil }
        let b = Blueprint().header(5).kind(.jumpRoping)
        b.int(WorkoutKey.timeStart).int(WorkoutKey.timeEnd).int(WorkoutKey.activeSeconds)
         .short(WorkoutKey.calories)
        hrTriple(b)
        b.float("trainingEffectAerobic")
        if version == 3 { b.skip(3) } else { b.skip(2).short("recoveryTime") }
        hrZones(b)
        b.skip(2).int(WorkoutKey.jumps).short("jumpRateAvg").skip(2).short("jumpRateMax")
        if version == 3 {
            b.skip(43).skip(2).skip(2)
        } else {
            b.skip(27).skip(4).float("trainingEffectAnaerobic").skip(3)
             .int("configuredTimeGoal").short("configuredCaloriesGoal").int("configuredJumpsGoal")
             .short("workoutLoad").skip(1).byte("vitalityGain")
        }
        return b
    }

    // MARK: - Helpers

    private static func swimStyleName(_ code: Int) -> String {
        switch code {
        case 0: "medley"
        case 1: "breaststroke"
        case 2: "freestyle"
        case 3: "backstroke"
        case 4: "butterfly"
        default: "unknown"
        }
    }

    /// XiaomiWorkoutType.fromCode (GadgetBridge), folded onto one kind per HealthKit activity type.
    /// Also decides the GPS reply at workout start, so an outdoor sport must not map to a kind
    /// whose `usesGps` is false.
    static func workoutKind(fromCode code: Int) -> WorkoutKind? {
        switch code {
        case 1:                          .running
        case 2, 15, 207, 333:            .walking
        case 3:                          .hiking
        case 4:                          .trekking
        case 5:                          .trailRun
        case 6, 206:                     .outdoorCycling
        case 7, 324:                     .indoorCycling
        case 8:                          .freeTraining
        case 16:                         .hiit
        case 12:                         .yoga
        // Confirmed from hardware log: subtype=0x8 version=10 workoutType code=308.
        case 308:                        .strengthTraining
        case 9:                          .poolSwim
        case 10:                         .openWaterSwim
        case 11:                         .elliptical
        case 107:                        .rowing
        case 13:                         .rowingMachine
        case 14:                         .jumpRoping
        case 17:                         .triathlon
        case 100:                        .sailing
        case 101, 105, 106, 115:         .paddleSports
        case 102:                        .waterPolo
        case 103, 104, 108, 112:         .waterSports
        case 110:                        .diving
        case 113, 114:                   .surfing
        case 200:                        .climbing
        case 201, 202, 700, 707:         .skating
        case 300:                        .stairClimbing
        case 301:                        .stairs
        case 302, 326:                   .stepTraining
        case 303, 322, 323:              .coreTraining
        case 304, 307:                   .flexibility
        case 305:                        .pilates
        case 306, 327...329:             .gymnastics
        case 309:                        .crossTraining
        case 310, 325, 332, 399:         .mixedCardio
        case 311...321, 331:             .functionalStrength
        case 400...412, 499:             .dance
        case 500:                        .boxing
        case 501:                        .wrestling
        case 502, 504...507, 509, 511:   .martialArts
        case 503:                        .taiChi
        case 330, 508:                   .kickboxing
        case 510:                        .fencing
        case 600, 616, 621:              .soccer
        case 601:                        .basketball
        case 602:                        .volleyball
        case 603:                        .baseball
        case 604:                        .softball
        case 605:                        .americanFootball
        case 606, 704:                   .hockey
        case 607:                        .tableTennis
        case 608:                        .badminton
        case 609:                        .tennis
        case 610:                        .cricket
        case 611:                        .handball
        case 612:                        .bowling
        case 613:                        .squash
        case 619:                        .golf
        case 701:                        .curling
        case 702, 703, 705, 706:         .snowSports
        case 708:                        .snowboarding
        case 709:                        .downhillSkiing
        case 800:                        .archery
        case 802, 10000:                 .equestrian
        case 806:                        .fishing
        case 807:                        .discSports
        default: nil
        }
    }

    private static func hashOf(_ data: Data) -> Int {
        data.prefix(64).reduce(into: 0) { $0 ^= Int($1) }
    }
}
