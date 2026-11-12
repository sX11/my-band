import Testing
import Foundation
import SwiftData
@testable import My_Band

@MainActor
struct SleepDurabilityTests {

    // MARK: - Byte builders

    private func le32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func le64(_ v: Int) -> [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }

    private let bed = 1_780_000_000
    private func at(_ offset: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(bed + offset)) }

    /// Version 2, 0x08, empty header, one hour in bed and a single type-16 summary packet.
    private func napFile(awake: UInt8, sleep: Int, light: Int = 0, deep: Int = 0) -> [UInt8] {
        var b = le32(bed) + [0, 2, UInt8(0x08 << 2)]
        b += [0, 0x00, awake] + le32(bed) + le32(bed + 3600)
        let summary: [UInt8] = [0] + be16(sleep) + be16(0) + be16(light) + be16(0) + be16(deep)
        b += [0xFB, 0xFA, 0xFC, 0xFF, 17] + le64(bed) + [0, 16] + be16(summary.count) + summary
        return b + [0, 0, 0, 0]
    }

    private func parse(_ bytes: [UInt8]) -> ParsedSleep {
        guard let meta = XiaomiActivityFileMeta(Data(bytes.prefix(7))) else { fatalError("bad file id") }
        return SleepDetailsParser.parse(Data(bytes), meta: meta)
    }

    // MARK: - Short naps

    @Test func aClosedNapWithoutStagesBecomesOneUnspecifiedPhase() {
        let parsed = parse(napFile(awake: 1, sleep: 45))
        #expect(parsed.awakeFlag == 1)
        #expect(parsed.sessions.count == 1)
        #expect(parsed.sessions.first?.phases == [SleepPhase(startDate: at(0), endDate: at(45 * 60), type: .unspecified)])
        #expect(parsed.sessions.first?.startDate == at(0))
        #expect(parsed.sessions.first?.endDate == at(3600))
    }

    @Test func anOpenNightWithoutStagesHasNoSession() {
        let parsed = parse(napFile(awake: 0, sleep: 45))
        #expect(parsed.awakeFlag == 0)
        #expect(parsed.sessions.isEmpty)
    }

    @Test func aSummaryWithStageMinutesKeepsTheStagedPhases() {
        let phases = parse(napFile(awake: 1, sleep: 45, light: 30, deep: 15)).sessions.first?.phases ?? []
        #expect(phases == [
            SleepPhase(startDate: at(0), endDate: at(30 * 60), type: .light),
            SleepPhase(startDate: at(30 * 60), endDate: at(45 * 60), type: .deep),
        ])
    }

    @Test func anOpenNightWithNothingToWriteIsHeldUnacknowledged() {
        let open = parse(napFile(awake: 0, sleep: 45))
        #expect(BandSyncer.shouldHoldOpenSleepFile(open, inRange: open.sessions))
        let closed = parse(napFile(awake: 1, sleep: 45))
        #expect(!BandSyncer.shouldHoldOpenSleepFile(closed, inRange: closed.sessions))
        let staged = parse(napFile(awake: 0, sleep: 45, light: 45))
        #expect(!BandSyncer.shouldHoldOpenSleepFile(staged, inRange: staged.sessions))
        #expect(BandSyncer.shouldHoldOpenSleepFile(staged, inRange: []))
    }

    @Test func inRangeDropsSessionsAndVitalsOutsideTheRange() {
        var parsed = ParsedSleep()
        parsed.sessions = [session(start: 0, end: 3600, hash: 1), session(start: -7200, end: 3600, hash: 2),
                           session(start: 0, end: 200_000, hash: 3)]
        parsed.heartRates = [(at(60), 55), (at(-60), 56)]
        parsed.spo2 = [(at(120), 97), (at(100_000), 90)]
        let kept = parsed.inRange(at(0) ... at(86_400))
        #expect(kept.sessions.map(\.rawDataHash) == [1])
        #expect(kept.vitals.map(\.date) == [at(60), at(120)])
        #expect(kept.vitals.map(\.heartRate) == [55, nil])
        #expect(kept.vitals.map(\.spo2) == [nil, 97])
    }

    @Test func theRealOpenNightReportsAwakeFlagZero() {
        let data = Fixtures.bytes(Fixtures.sleepDetailsV5ThreeRevisions)
        guard let meta = XiaomiActivityFileMeta(Data(data.prefix(7))) else {
            Issue.record("fixture id doesn't decode")
            return
        }
        #expect(SleepDetailsParser.parse(data, meta: meta).awakeFlag == 0)
    }

    // MARK: - Sleep state rule

    private let now = Date(timeIntervalSince1970: 1_790_850_900)

    private func report(endAgo: TimeInterval, fetchedAgo: TimeInterval?, flag: Int?,
                        last: SleepPhaseType = .light) -> SleepSession {
        let end = now.addingTimeInterval(-endAgo)
        let s = SleepSession(startDate: end.addingTimeInterval(-6 * 3600), endDate: end,
                             phases: [SleepPhase(startDate: end.addingTimeInterval(-3600), endDate: end, type: last)])
        s.awakeFlag = flag
        s.fetchedAt = fetchedAgo.map { now.addingTimeInterval(-$0) }
        return s
    }

    @Test func anOpenNightStillGrowingAtARecentFetchIsAsleep() {
        #expect(SleepStateRule.evaluate(report(endAgo: 120, fetchedAgo: 60, flag: 0), now: now).asleep)
    }

    @Test func aNightTheBandClosedIsAwake() {
        #expect(!SleepStateRule.evaluate(report(endAgo: 120, fetchedAgo: 60, flag: 1), now: now).asleep)
    }

    @Test func anOpenNightThatStoppedGrowingBeforeTheFetchIsAwake() {
        #expect(!SleepStateRule.evaluate(report(endAgo: 40 * 60, fetchedAgo: 60, flag: 0), now: now).asleep)
    }

    @Test func anOpenNightFetchedOverAnHourAgoIsAwake() {
        #expect(!SleepStateRule.evaluate(report(endAgo: 61 * 60, fetchedAgo: 61 * 60, flag: 0), now: now).asleep)
    }

    @Test func anAwakeLastPhaseIsAwake() {
        #expect(!SleepStateRule.evaluate(report(endAgo: 60, fetchedAgo: 60, flag: 0, last: .awake), now: now).asleep)
    }

    @Test func anEndAheadOfTheClockIsUntrusted() {
        let verdict = SleepStateRule.evaluate(report(endAgo: -30 * 60, fetchedAgo: 60, flag: 0), now: now)
        #expect(!verdict.asleep)
        #expect(verdict.reason.contains("untrusted"))
    }

    @Test func anEndAheadOfTheFetchIsUntrusted() {
        let verdict = SleepStateRule.evaluate(report(endAgo: 60, fetchedAgo: 20 * 60, flag: 0), now: now)
        #expect(!verdict.asleep)
        #expect(verdict.reason.contains("untrusted"))
    }

    @Test func aReportWithoutTheFlagEndingAfterNowIsNotAsleep() {
        #expect(!SleepStateRule.evaluate(report(endAgo: -3 * 60, fetchedAgo: nil, flag: nil), now: now).asleep)
    }

    @Test func aReportWithoutTheFlagFallsBackToItsAge() {
        #expect(SleepStateRule.evaluate(report(endAgo: 30 * 60, fetchedAgo: nil, flag: nil), now: now).asleep)
        #expect(!SleepStateRule.evaluate(report(endAgo: 90 * 60, fetchedAgo: nil, flag: nil), now: now).asleep)
    }

    // MARK: - Stored reports

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: BandDevice.self, SleepSession.self, ActivityDay.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A file id of the given subtype followed by `size` filler bytes.
    private func raw(subtype: Int = 0x08, _ tag: UInt8, size: Int = 1) -> Data {
        Data(le32(bed) + [0, 2, UInt8(subtype << 2)] + Array(repeating: tag, count: size))
    }

    private func session(start: Int, end: Int, hash: Int) -> SleepSession {
        SleepSession(startDate: at(start), endDate: at(end),
                     phases: [SleepPhase(startDate: at(start), endDate: at(end), type: .light)], rawDataHash: hash)
    }

    @Test func theLatestSessionIsTheOneEndingLast() throws {
        let context = try makeContext()
        context.insert(session(start: 0, end: 7 * 3600, hash: 1))
        context.insert(session(start: 600, end: 4 * 3600, hash: 2))
        try context.save()
        #expect(BandSyncer.mostRecentSleepSession(in: context)?.rawDataHash == 1)
    }

    @Test func aSessionEndingAfterNowIsIgnored() throws {
        let context = try makeContext()
        context.insert(session(start: 0, end: 7 * 3600, hash: 1))
        context.insert(session(start: 0, end: 30 * 3600, hash: 2))
        try context.save()
        #expect(BandSyncer.mostRecentSleepSession(in: context, now: at(8 * 3600))?.rawDataHash == 1)
    }

    @Test func anEndTieGoesToTheLatestFetch() throws {
        let context = try makeContext()
        let older = session(start: 0, end: 7 * 3600, hash: 1)
        let newer = session(start: 0, end: 7 * 3600, hash: 2)
        older.fetchedAt = at(7 * 3600)
        newer.fetchedAt = at(9 * 3600)
        context.insert(newer)
        context.insert(older)
        try context.save()
        #expect(BandSyncer.mostRecentSleepSession(in: context)?.rawDataHash == 2)
    }

    @Test func onlyTheReportReachingFurthestKeepsItsRawFile() throws {
        let context = try makeContext()
        let syncer = BandSyncer()
        syncer.storeReport(session(start: 0, end: 3 * 3600, hash: 1), raw: raw(1), awakeFlag: 0, fetchedAt: at(3 * 3600), context)
        syncer.storeReport(session(start: 0, end: 6 * 3600, hash: 2), raw: raw(2), awakeFlag: 0, fetchedAt: at(6 * 3600), context)
        // The band re-offering the earlier cut must not take the bytes back.
        syncer.storeReport(session(start: 0, end: 3 * 3600, hash: 1), raw: raw(1), awakeFlag: 0, fetchedAt: at(7 * 3600), context)
        syncer.storeReport(session(start: 86_400, end: 86_400 + 3600, hash: 3), raw: raw(3), awakeFlag: 1, fetchedAt: at(90_000), context)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.rawDataHash)]))
        #expect(stored.map(\.rawDataHash) == [1, 2, 3])
        #expect(stored.map(\.rawData) == [nil, raw(2), raw(3)])
        #expect(stored.first?.fetchedAt == at(7 * 3600))
    }

    @Test func anOverlappingReportOfAnotherFileKeepsItsRawFile() throws {
        let context = try makeContext()
        let syncer = BandSyncer()
        syncer.storeReport(session(start: 0, end: 3 * 3600, hash: 1), raw: raw(subtype: 0x03, 1), awakeFlag: nil, fetchedAt: at(3 * 3600), context)
        syncer.storeReport(session(start: 600, end: 4 * 3600, hash: 2), raw: raw(2), awakeFlag: 1, fetchedAt: at(4 * 3600), context)
        syncer.storeReport(session(start: 0, end: 6 * 3600, hash: 3), raw: raw(3), awakeFlag: 0, fetchedAt: at(6 * 3600), context)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.rawDataHash)]))
        #expect(stored.map(\.rawData) == [raw(subtype: 0x03, 1), raw(2), raw(3)])
    }

    @Test func aSameHashFileOfAnotherLengthIsAnotherReport() throws {
        let context = try makeContext()
        let syncer = BandSyncer()
        syncer.storeReport(session(start: 0, end: 3 * 3600, hash: 7), raw: raw(1, size: 4), awakeFlag: 0, fetchedAt: at(3 * 3600), context)
        syncer.storeReport(session(start: 0, end: 6 * 3600, hash: 7), raw: raw(2, size: 9), awakeFlag: 0, fetchedAt: at(6 * 3600), context)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<SleepSession>(sortBy: [SortDescriptor(\.endDate)]))
        #expect(stored.map(\.endDate) == [at(3 * 3600), at(6 * 3600)])
    }

    @Test func earlierCutsFollowTheirReparsedNightToItsNewStart() {
        let holder = session(start: -3600, end: 6 * 3600, hash: 1)
        holder.rawData = raw(1)
        let cut = SleepSession(startDate: at(-3600), endDate: at(3 * 3600), phases: [
            SleepPhase(startDate: at(-3600), endDate: at(-1800), type: .light),
            SleepPhase(startDate: at(-1800), endDate: at(600), type: .awake),
            SleepPhase(startDate: at(600), endDate: at(3 * 3600), type: .deep),
        ], rawDataHash: 2)
        let otherNight = session(start: 86_400 - 3600, end: 86_400 + 3600, hash: 3)
        let otherFile = session(start: -3600, end: 2 * 3600, hash: 4)
        otherFile.rawData = raw(subtype: 0x03, 4)

        BandSyncer.moveCuts(from: at(-3600), to: at(0), among: [holder, cut, otherNight, otherFile])

        #expect(cut.startDate == at(0))
        #expect(cut.endDate == at(3 * 3600))
        #expect(cut.phases == [
            SleepPhase(startDate: at(0), endDate: at(600), type: .awake),
            SleepPhase(startDate: at(600), endDate: at(3 * 3600), type: .deep),
        ])
        #expect(holder.startDate == at(-3600))
        #expect(otherNight.startDate == at(86_400 - 3600))
        #expect(otherFile.startDate == at(-3600))
    }

    @Test func aCutLyingWhollyBeforeTheNewStartKeepsASaneWindow() {
        let cut = SleepSession(startDate: at(-3600), endDate: at(-1800),
                               phases: [SleepPhase(startDate: at(-3600), endDate: at(-1800), type: .light)],
                               rawDataHash: 2)
        BandSyncer.moveCuts(from: at(-3600), to: at(0), among: [cut])
        #expect(cut.startDate == at(0))
        #expect(cut.endDate == at(0))
        #expect(cut.phases.isEmpty)
    }

    @Test func rawFilesOlderThanTheRetentionAreDropped() throws {
        let context = try makeContext()
        let old = session(start: 0, end: 3600, hash: 1)
        let recent = session(start: 100 * 86_400, end: 100 * 86_400 + 3600, hash: 2)
        old.rawData = Data([1])
        recent.rawData = Data([2])
        context.insert(old)
        context.insert(recent)
        BandSyncer.dropExpiredRawData(in: context, now: at(100 * 86_400 + 7200))
        #expect(old.rawData == nil)
        #expect(recent.rawData == Data([2]))
    }
}
