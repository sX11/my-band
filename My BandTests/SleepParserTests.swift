import Testing
import Foundation
@testable import My_Band

// Sleep files built to the documented layouts, plus one real capture (SleepFixtures.swift). They
// pin the byte offsets both parsers depend on, and which parser each file id routes to:
// subtype 0x03 used to go through SleepDetailsParser, whose offsets don't fit its layout at all.
@MainActor
struct SleepParserTests {

    // MARK: - Byte builders

    private func le16(_ v: Int) -> [UInt8] { (0 ..< 2).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func le32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func le64(_ v: Int) -> [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }

    /// [ts u32 LE][tz][version][flags = subtype<<2 | detail] — activity type (bit 7 clear).
    private func fileId(version: Int, subtype: Int, detail: Int) -> [UInt8] {
        le32(bed) + [0, UInt8(version), UInt8((subtype << 2) | detail)]
    }

    private func meta(_ bytes: [UInt8]) -> XiaomiActivityFileMeta {
        guard let m = XiaomiActivityFileMeta(Data(bytes.prefix(7))) else { fatalError("bad file id") }
        return m
    }

    /// Parsers strip the trailing CRC-32 (BandSyncer validated it on reassembly).
    private let crc: [UInt8] = [0, 0, 0, 0]
    private let bed = 1_780_000_000
    private func at(_ offset: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(bed + offset)) }

    // MARK: - 0x08 · SleepDetailsParser

    /// Version 2, header bit 3 set (HR section present), one type-17 stage packet.
    private func detailsFile(version: Int = 2) -> [UInt8] {
        var b = fileId(version: version, subtype: 0x08, detail: 0)
        b += [0]                                    // padding
        b += [0x10]                                 // header: bit 3 (HR) only
        b += [1]                                    // isAwake
        b += le32(bed) + le32(bed + 3 * 3600)       // bedTime, wakeupTime
        b += le16(60) + le16(2) + le32(bed) + [58, 54]   // HR: unit 60 s, 2 samples
        let words = [(1, 60), (2, 30), (3, 20)].flatMap { be16(($0.0 << 12) | $0.1) }
        b += [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(bed) + [0, 17] + be16(words.count) + words
        return b + crc
    }

    @Test func detailsParserReadsHeartRateAndDurationEncodedStages() {
        let bytes = detailsFile()
        let parsed = SleepDetailsParser.parse(Data(bytes), meta: meta(bytes))

        #expect(parsed.heartRates.map(\.bpm) == [58, 54])
        #expect(parsed.heartRates.map(\.date) == [at(0), at(60)])
        #expect(parsed.sessions.count == 1)
        let session = parsed.sessions[0]
        #expect(session.startDate == at(0))
        #expect(session.endDate == at(3 * 3600))
        #expect(session.phases == [
            SleepPhase(startDate: at(0), endDate: at(3600), type: .light),
            SleepPhase(startDate: at(3600), endDate: at(5400), type: .deep),
            SleepPhase(startDate: at(5400), endDate: at(6600), type: .rem),
        ])
    }

    private func stagePacket(ts: Int, type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(ts) + [0, type] + be16(payload.count) + payload
    }

    private func stages(ts: Int, _ entries: [(code: Int, minutes: Int)]) -> [UInt8] {
        stagePacket(ts: ts, type: 17, entries.flatMap { be16(($0.code << 12) | $0.minutes) })
    }

    /// Version 2, empty header, three hours in bed, followed by `packets`.
    private func detailsFile(packets: [UInt8]) -> [UInt8] {
        var b = fileId(version: 2, subtype: 0x08, detail: 0)
        b += [0, 0x00, 1] + le32(bed) + le32(bed + 3 * 3600)
        return b + packets + crc
    }

    private func phases(_ bytes: [UInt8]) -> [SleepPhase] {
        SleepDetailsParser.parse(Data(bytes), meta: meta(bytes)).sessions.first?.phases ?? []
    }

    @Test func detailsParserKeepsOnlyTheLastRescoringOfTheNight() {
        let bytes = detailsFile(packets: stages(ts: bed, [(1, 60), (2, 30)])
                                       + stages(ts: bed, [(3, 30), (1, 60), (0, 10)]))
        #expect(phases(bytes) == [
            SleepPhase(startDate: at(0), endDate: at(1800), type: .rem),
            SleepPhase(startDate: at(1800), endDate: at(5400), type: .light),
            SleepPhase(startDate: at(5400), endDate: at(6000), type: .awake),
        ])
    }

    @Test func aLaterRescoringWithAnotherStartWinsWhereTheyOverlap() {
        let bytes = detailsFile(packets: stages(ts: bed, [(1, 60), (2, 60)])
                                       + stages(ts: bed + 1800, [(3, 60)]))
        #expect(phases(bytes) == [
            SleepPhase(startDate: at(0), endDate: at(1800), type: .light),
            SleepPhase(startDate: at(1800), endDate: at(5400), type: .rem),
            SleepPhase(startDate: at(5400), endDate: at(7200), type: .deep),
        ])
    }

    @Test func flagOnlyType18DoesNotSwallowTheNextPacket() {
        // The length field carries flags, so nothing follows it; reading it as a length would eat the next magic.
        let flagOnly: [UInt8] = [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(bed) + [0, 0x12] + be16(2)
        let bytes = detailsFile(packets: flagOnly + stages(ts: bed, [(2, 30)]))
        #expect(phases(bytes) == [SleepPhase(startDate: at(0), endDate: at(1800), type: .deep)])
    }

    @Test func stagesStampedFarOutsideTheNightAreDropped() {
        let bytes = detailsFile(packets: stages(ts: bed - 3 * 86400, [(1, 30)])
                                       + stages(ts: bed, [(2, 30)]))
        let session = SleepDetailsParser.parse(Data(bytes), meta: meta(bytes)).sessions.first
        #expect(session?.phases == [SleepPhase(startDate: at(0), endDate: at(1800), type: .deep)])
        #expect(session?.startDate == at(0))
    }

    @Test func aRescoringClaimsTheStretchItMarksNotSleeping() {
        let bytes = detailsFile(packets: stages(ts: bed, [(1, 90)])
                                       + stages(ts: bed + 600, [(2, 30), (4, 50)]))
        #expect(phases(bytes) == [
            SleepPhase(startDate: at(0), endDate: at(600), type: .light),
            SleepPhase(startDate: at(600), endDate: at(2400), type: .deep),
        ])
    }

    @Test func anImplausibleLaterRevisionDoesNotSplitTheNight() {
        let bytes = detailsFile(packets: stages(ts: bed, [(1, 60)])
                                       + stages(ts: bed - 3 * 86400, [(2, 4095), (2, 4095)]))
        #expect(phases(bytes) == [SleepPhase(startDate: at(0), endDate: at(3600), type: .light)])
    }

    @Test func aPhaseRunningPastTheWindowIsClippedNotDropped() {
        let bytes = detailsFile(packets: stages(ts: bed, [(1, 60), (2, 4000)]))
        #expect(phases(bytes) == [
            SleepPhase(startDate: at(0), endDate: at(3600), type: .light),
            SleepPhase(startDate: at(3600), endDate: at(9 * 3600), type: .deep),
        ])
    }

    @Test func sessionWidensToEncloseAPhasePastWakeup() {
        let bytes = detailsFile(packets: stages(ts: bed, [(1, 120), (0, 90)]))
        let session = SleepDetailsParser.parse(Data(bytes), meta: meta(bytes)).sessions.first
        #expect(session?.endDate == at(210 * 60))
    }

    /// Real v5 night with three re-scorings; the band's own totals for the last one are
    /// light 161, deep 125, REM 86, awake 22 minutes in 35 phases.
    @Test func detailsParserReadsARealNightAsTheBandScoredIt() {
        let data = Fixtures.bytes(Fixtures.sleepDetailsV5ThreeRevisions)
        guard let meta = XiaomiActivityFileMeta(Data(data.prefix(7))) else {
            Issue.record("fixture id doesn't decode")
            return
        }
        let parsed = SleepDetailsParser.parse(data, meta: meta)

        #expect(parsed.sessions.count == 1)
        let session = parsed.sessions.first
        #expect(session?.startDate == Date(timeIntervalSince1970: 1_790_827_200))
        #expect(session?.endDate == Date(timeIntervalSince1970: 1_790_850_840))
        let phases = session?.phases ?? []
        func minutes(_ type: SleepPhaseType) -> Int {
            Int(phases.filter { $0.type == type }.reduce(0) { $0 + $1.duration } / 60)
        }
        #expect(phases.count == 35)
        #expect(minutes(.light) == 161)
        #expect(minutes(.deep) == 125)
        #expect(minutes(.rem) == 86)
        #expect(minutes(.awake) == 22)
        #expect(parsed.spo2.count == 35)
        #expect(parsed.spo2.prefix(10).map(\.pct) == [97, 93, 93, 95, 94, 94, 95, 94, 97, 97])
        #expect(parsed.heartRates.count == 301)
    }

    @Test func detailsParserRejectsAnUnknownVersionInsteadOfGuessingOffsets() {
        let bytes = detailsFile(version: 6)
        let parsed = SleepDetailsParser.parse(Data(bytes), meta: meta(bytes))
        #expect(parsed.sessions.isEmpty)
        #expect(parsed.heartRates.isEmpty)
        #expect(parsed.spo2.isEmpty)
    }

    // MARK: - 0x03 · SleepStagesParser

    private func stagesFile(version: Int = 2, bedTime: Int? = nil,
                            events: [(offset: Int, code: UInt8)]) -> [UInt8] {
        let bedTime = bedTime ?? bed
        var b = fileId(version: version, subtype: 0x03, detail: 0)
        b += [0]                                    // padding
        b += [0xFF, 0xFF, 0, 0, 0, 0, 0]            // unknown (7)
        b += le16(180)                              // sleepDuration, minutes
        b += le32(bedTime) + le32(bed + 3 * 3600)   // bedTime, wakeupTime
        b += [0, 0, 0]                              // unknown (3)
        b += le16(30) + le16(120) + le16(20) + le16(10)  // deep, light, rem, wake
        b += [0]                                    // unknown
        for e in events { b += le32(bed + e.offset) + [e.code] }
        return b + crc
    }

    @Test func stagesParserTurnsTransitionsIntoPhases() {
        let bytes = stagesFile(events: [
            (-600, 5),   // awake, before the band's "real" sleep start
            (0, 3),      // light
            (3600, 2),   // deep
            (5400, 0),   // not sleeping — skipped
            (6000, 4),   // REM, runs to wakeupTime
        ])
        let parsed = SleepStagesParser.parse(Data(bytes), meta: meta(bytes))

        #expect(parsed.sessions.count == 1)
        let session = parsed.sessions[0]
        #expect(session.phases == [
            SleepPhase(startDate: at(-600), endDate: at(0), type: .awake),
            SleepPhase(startDate: at(0), endDate: at(3600), type: .light),
            SleepPhase(startDate: at(3600), endDate: at(5400), type: .deep),
            SleepPhase(startDate: at(6000), endDate: at(3 * 3600), type: .rem),
        ])
        // Widened to enclose the early awake phase.
        #expect(session.startDate == at(-600))
        #expect(session.endDate == at(3 * 3600))
    }

    @Test func stagesParserFallsBackToTheSummaryDurationsWithoutTransitions() {
        let bytes = stagesFile(events: [])
        let parsed = SleepStagesParser.parse(Data(bytes), meta: meta(bytes))
        let phases = parsed.sessions.first?.phases ?? []
        #expect(phases.map(\.type) == [.light, .deep, .rem, .awake])
        let expectedMinutes: [TimeInterval] = [120, 30, 20, 10]
        #expect(phases.map(\.duration) == expectedMinutes.map { $0 * 60 })
    }

    @Test func stagesParserIgnoresUnknownVersionsAndEmptyNights() {
        let wrongVersion = stagesFile(version: 3, events: [(0, 3)])
        #expect(SleepStagesParser.parse(Data(wrongVersion), meta: meta(wrongVersion)).sessions.isEmpty)

        let noBedTime = stagesFile(bedTime: 0, events: [(0, 3)])
        #expect(SleepStagesParser.parse(Data(noBedTime), meta: meta(noBedTime)).sessions.isEmpty)
    }

    // MARK: - Routing

    @Test func eachSleepSubtypeRoutesToItsOwnParser() {
        let details = meta(fileId(version: 5, subtype: 0x08, detail: 1))
        #expect(details.isSleep && details.isSleepDetails && !details.isSleepStages)

        let stages = meta(fileId(version: 2, subtype: 0x03, detail: 0))
        #expect(stages.isSleep && stages.isSleepStages && !stages.isSleepDetails)

        // GadgetBridge has no parser for a 0x03 that isn't DETAILS — it must fall to the ACK-only branch.
        let stagesSummary = meta(fileId(version: 2, subtype: 0x03, detail: 1))
        #expect(!stagesSummary.isSleep)
    }

    @Test func fileIdListingDropsPlaceholderIds() {
        let real = fileId(version: 2, subtype: 0x08, detail: 0)
        let placeholder = [UInt8](repeating: 0, count: 7)
        let ids = BandSyncer.splitFileIds(Data(real + placeholder))
        #expect(ids == [Data(real)])
    }
}
