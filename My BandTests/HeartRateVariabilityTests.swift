import Testing
import Foundation
import HealthKit
@testable import My_Band

// Pinned by the real v5 night in SleepFixtures.swift: 27 type-1 blocks of beat-to-beat intervals.
@MainActor
struct HeartRateVariabilityTests {

    private func realNight(awakeFlag: UInt8? = nil) -> ParsedSleep {
        var data = Fixtures.bytes(Fixtures.sleepDetailsV5ThreeRevisions)
        let fileIdAndPadding = 8, v5HeaderBitmask = 2
        if let awakeFlag { data[data.startIndex + fileIdAndPadding + v5HeaderBitmask] = awakeFlag }
        guard let meta = XiaomiActivityFileMeta(Data(data.prefix(7))) else {
            Issue.record("fixture id doesn't decode")
            return ParsedSleep()
        }
        return SleepDetailsParser.parse(data, meta: meta)
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// Minutes of steady 1000 ms beats; `wobble` alternates ±wobble ms so SDNN is non-zero.
    private func block(start: Date, minutes: Int, wobble: Int = 40) -> BeatWindow {
        BeatWindow(start: start, intervalsMs: (0 ..< minutes * 60).map { 1000 + ($0 % 2 == 0 ? wobble : -wobble) })
    }

    // MARK: - Parsing type-1 packets

    @Test func realNightCarriesTwentySevenTenMinuteBlocks() {
        let parsed = realNight()
        let blocks = parsed.beatWindows
        #expect(blocks.count == 27)
        #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(blocks.first?.start == Date(timeIntervalSince1970: 1_790_829_958.797))
        if let session = parsed.sessions.first {
            #expect(blocks.allSatisfy { (session.startDate ... session.endDate).contains($0.start) })
        } else {
            Issue.record("no session")
        }
        #expect(blocks.allSatisfy { (590_000 ... 601_000).contains($0.intervalsMs.reduce(0, +)) })
        #expect(blocks.reduce(0) { $0 + $1.intervalsMs.count } == 19_699)
    }

    @Test func realNightIntervalsComeInFortyMillisecondSteps() {
        let intervals = realNight().beatWindows.flatMap(\.intervalsMs)
        #expect(!intervals.isEmpty)
        #expect(intervals.allSatisfy { $0 % 40 == 0 })
    }

    /// The beats a block implies agree with the band's own HR section over the same span; the one
    /// that doesn't has missed beats (and a zero interval) the artifact filter rejects.
    @Test func realNightBeatsAgreeWithTheHeaderHeartRate() {
        let parsed = realNight()
        let agreeing = parsed.beatWindows.filter { block in
            let totalMs = block.intervalsMs.reduce(0, +)
            let end = block.start.addingTimeInterval(TimeInterval(totalMs) / 1000)
            let header = parsed.heartRates.filter { $0.date >= block.start && $0.date < end }.map(\.bpm)
            guard !header.isEmpty, totalMs > 0 else { return false }
            let implied = 60_000 * Double(block.intervalsMs.count) / Double(totalMs)
            let banded = Double(header.reduce(0, +)) / Double(header.count)
            return abs(implied - banded) <= 2
        }
        #expect(parsed.beatWindows.count == 27)
        #expect(agreeing.count == 26)
    }

    // MARK: - One value per block

    @Test func realNightYieldsOneSDNNValuePerBlockNotPerMinute() throws {
        let blocks = realNight(awakeFlag: 1).beatWindows
        let cleanMinutes = blocks.flatMap(HeartRateVariability.minuteSDNN)
        let samples = HealthKitManager.hrvSamples(blocks)
        #expect(cleanMinutes.count == 264)
        #expect(samples.count == 27)
        let ms = samples.map { $0.quantity.doubleValue(for: .secondUnit(with: .milli)) }.sorted()
        try #require(!ms.isEmpty)
        #expect(abs(ms[ms.count / 2] - 21.16) < 0.01)
        #expect(samples.allSatisfy { $0.endDate.timeIntervalSince($0.startDate) == 60 })
        for (sample, block) in zip(samples.sorted { $0.startDate < $1.startDate }, blocks) {
            #expect(sample.startDate >= block.start)
            #expect(sample.endDate <= block.start.addingTimeInterval(TimeInterval(block.intervalsMs.reduce(0, +)) / 1000 + 60))
        }
    }

    @Test func blockValueComesFromItsCleanestMinute() {
        var window = block(start: t0, minutes: 3)
        let fiveArtifactsInMinuteZero = [10, 20, 30, 40, 50]
        for i in fiveArtifactsInMinuteZero { window.intervalsMs[i] = 1600 }
        let minutes = HeartRateVariability.minuteSDNN(window)
        #expect(minutes.count == 3)
        #expect(minutes[0].acceptedShare < 1)
        let value = HeartRateVariability.blockSDNN(window)
        #expect(value?.minute.start == t0.addingTimeInterval(60))
        #expect(value?.blockStart == t0)
    }

    @Test func blockWithoutACleanMinuteHasNoValue() {
        let noisy = BeatWindow(start: t0, intervalsMs: (0 ..< 120).map { $0 % 2 == 0 ? 400 : 1500 })
        #expect(HeartRateVariability.blockSDNN(noisy) == nil)
        #expect(HealthKitManager.hrvSamples([noisy]).isEmpty)
    }

    // MARK: - Which blocks a file gives

    private func writable(_ parsed: ParsedSleep) -> [BeatWindow] {
        BandSyncer.writableBeats(parsed, inRange: parsed.inRange(HealthKitManager.validDateRange()).sessions)
    }

    @Test func aClosedNightGivesEveryBlock() {
        #expect(writable(realNight(awakeFlag: 1)).count == 27)
    }

    @Test func anOpenNightGivesEveryBlockButTheStillGrowingLast() {
        let open = realNight()
        #expect(open.awakeFlag == 0)
        #expect(writable(open) == Array(open.beatWindows.dropLast()))
        #expect(writable(open).count == 26)
    }

    @Test func aReportWithoutAwakeFlagGivesNoBlocks() {
        var unknown = realNight(awakeFlag: 1)
        unknown.awakeFlag = nil
        #expect(!unknown.beatWindows.isEmpty)
        #expect(writable(unknown).isEmpty)
    }

    @Test func aSettledOpenNightGivesItsLastBlockToo() {
        let open = realNight()
        let sessions = open.inRange(HealthKitManager.validDateRange()).sessions
        #expect(BandSyncer.writableBeats(open, inRange: sessions, settled: true) == open.beatWindows)
    }

    @Test func blocksOutsideTheNightAreNotSleep() {
        let night = SleepSession(startDate: t0, endDate: t0.addingTimeInterval(3600), phases: [])
        let beforeBed = block(start: t0.addingTimeInterval(-1800), minutes: 10)
        let acrossBedtime = block(start: t0.addingTimeInterval(-300), minutes: 10)
        let asleep = block(start: t0.addingTimeInterval(1200), minutes: 10)
        let afterWaking = block(start: t0.addingTimeInterval(7200), minutes: 10)
        var parsed = ParsedSleep()
        parsed.awakeFlag = 1
        parsed.beatWindows = [beforeBed, acrossBedtime, asleep, afterWaking]
        #expect(BandSyncer.writableBeats(parsed, inRange: [night]) == [acrossBedtime, asleep])
    }

    @Test func aFileWithoutASessionGivesNoBlocks() {
        let closed = realNight(awakeFlag: 1)
        #expect(!closed.beatWindows.isEmpty)
        #expect(BandSyncer.writableBeats(closed, inRange: []).isEmpty)
    }

    // MARK: - Reports of one night

    @Test func furthestReportWinsARepeatedBlockWhateverTheOrder() {
        let all = realNight(awakeFlag: 1).beatWindows
        let earlierCutReadDifferently = all.prefix(10).map { BeatWindow(start: $0.start, intervalsMs: $0.intervalsMs.map { $0 + 40 }) }
        let bed = Date(timeIntervalSince1970: 1_790_827_200)
        let merged = HeartRateVariability.nightBlocks([
            (reach: bed.addingTimeInterval(8 * 3600), windows: all),
            (reach: bed.addingTimeInterval(3 * 3600), windows: earlierCutReadDifferently),
        ])
        #expect(merged == all)
        #expect(HealthKitManager.hrvSamples(merged).count == 27)
    }

    @Test func blocksOnlyInAnEarlierReportAreKept() {
        let a = block(start: t0, minutes: 2), b = block(start: t0.addingTimeInterval(605), minutes: 2)
        let merged = HeartRateVariability.nightBlocks([(reach: t0.addingTimeInterval(9000), windows: [b]),
                                                      (reach: t0.addingTimeInterval(1000), windows: [a])])
        #expect(merged.map(\.start) == [a.start, b.start])
    }

    // MARK: - Quantization

    @Test func blockSDNNRemovesTheFortyMillisecondStepVariance() throws {
        let value = try #require(HeartRateVariability.blockSDNN(block(start: t0, minutes: 1, wobble: 40)))
        #expect(abs(value.minute.sdnnMs - (40.0 * 40 - 40 * 40 / 6).squareRoot()) < 0.5)
    }

    @Test func spreadBelowTheStepNoiseCorrectsToZero() throws {
        let value = try #require(HeartRateVariability.blockSDNN(block(start: t0, minutes: 1, wobble: 5)))
        #expect(value.minute.sdnnMs == 0)
    }

    // MARK: - Night spans

    @Test func blocksHoursApartAreClearedAsSeparateNights() {
        let a = block(start: t0, minutes: 10)
        let b = block(start: t0.addingTimeInterval(1800), minutes: 10)
        let nextNight = block(start: t0.addingTimeInterval(20 * 3600), minutes: 10)
        let spans = HeartRateVariability.nightSpans([nextNight, b, a])
        #expect(spans == [t0 ... t0.addingTimeInterval(1800 + 600),
                          nextNight.start ... nextNight.start.addingTimeInterval(600)])
    }

    @Test func aNightSpanStopsAtItsLastBeatShortOfTheNextBlocksValue() throws {
        let a = block(start: t0, minutes: 10)
        let b = block(start: a.end.addingTimeInterval(0.5), minutes: 10)
        let span = try #require(HeartRateVariability.nightSpans([a]).first)
        #expect(span == a.start ... a.end)
        let own = try #require(HealthKitManager.hrvSamples([a]).first)
        #expect(own.startDate < span.upperBound && own.endDate > span.lowerBound)
        let next = try #require(HealthKitManager.hrvSamples([b]).first)
        #expect(next.startDate > span.upperBound)
    }

    // MARK: - Stored nights

    private var now: Date { t0.addingTimeInterval(20 * 3600) }

    private func report(from start: TimeInterval, to end: TimeInterval, flag: Int?, fetchedAgo: TimeInterval?,
                        hash: Int) -> SleepSession {
        let s = SleepSession(startDate: t0.addingTimeInterval(start), endDate: t0.addingTimeInterval(end),
                             phases: [], rawDataHash: hash)
        s.awakeFlag = flag
        s.fetchedAt = fetchedAgo.map { now.addingTimeInterval(-$0) }
        return s
    }

    private func selected(_ nights: [[SleepSession]], full: Bool = false, retry: [ClosedRange<Date>] = [],
                          settledDone: Set<Int> = []) -> [BandSyncer.StoredHRVNight] {
        BandSyncer.storedHRVNights(nights, full: full, retry: retry, settledDone: settledDone, now: now)
    }

    @Test func anOpenNightSettlesOnlyLongAfterItsLastReport() {
        let settled = report(from: 0, to: 8 * 3600, flag: 0, fetchedAgo: 4 * 3600, hash: 1)
        let recent = report(from: 0, to: 8 * 3600, flag: 0, fetchedAgo: 3600, hash: 2)
        let closed = report(from: 0, to: 8 * 3600, flag: 1, fetchedAgo: 4 * 3600, hash: 3)
        let picked = selected([[settled]])
        #expect(picked.count == 1 && picked.first?.settled == true)
        #expect(selected([[recent]]).isEmpty)
        #expect(selected([[closed]]).isEmpty)
    }

    @Test func aLaterReportKeepsTheNightOpen() {
        let earlier = report(from: 0, to: 4 * 3600, flag: 0, fetchedAgo: 10 * 3600, hash: 1)
        let latest = report(from: 0, to: 8 * 3600, flag: 0, fetchedAgo: 1800, hash: 2)
        #expect(selected([[earlier, latest]]).isEmpty)
    }

    @Test func aSettledNightIsWrittenOnce() {
        let settled = report(from: 0, to: 8 * 3600, flag: 0, fetchedAgo: 4 * 3600, hash: 1)
        #expect(selected([[settled]], settledDone: [1]).isEmpty)
        #expect(selected([[settled]], full: true, settledDone: [1]).first?.settled == true)
    }

    @Test func onlyQueuedNightsAreRetried() {
        let first = report(from: -86_400, to: -86_400 + 8 * 3600, flag: 1, fetchedAgo: 30 * 3600, hash: 1)
        let second = report(from: 0, to: 8 * 3600, flag: 1, fetchedAgo: 12 * 3600, hash: 2)
        let failedSpan = t0.addingTimeInterval(3600) ... t0.addingTimeInterval(2 * 3600)
        #expect(selected([[first], [second]]).isEmpty)
        #expect(selected([[first], [second]], retry: [failedSpan]).map(\.reports) == [[second]])
        #expect(selected([[first], [second]], full: true).count == 2)
    }

    @Test func retryQueueKeepsEachFailedNightOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "HeartRateVariabilityTests.retry"))
        defer { defaults.removePersistentDomain(forName: "HeartRateVariabilityTests.retry") }
        let night = t0 ... t0.addingTimeInterval(8 * 3600)
        BandSyncer.queueHRVRetry([night], defaults)
        BandSyncer.queueHRVRetry([t0.addingTimeInterval(3600) ... t0.addingTimeInterval(7200)], defaults)
        #expect(BandSyncer.hrvRetrySpans(defaults) == [night])
        BandSyncer.setHRVRetrySpans([], defaults)
        #expect(BandSyncer.hrvRetrySpans(defaults).isEmpty)
    }

    @Test func aFileKeptOnTwoRecordsIsParsedAndWrittenOnce() {
        let raw = Data(Fixtures.bytes(Fixtures.sleepDetailsV5ThreeRevisions))
        let a = report(from: 0, to: 8 * 3600, flag: 1, fetchedAgo: 0, hash: 7)
        let b = report(from: 0, to: 8 * 3600, flag: 1, fetchedAgo: 0, hash: 7)
        let collision = report(from: 0, to: 8 * 3600, flag: 1, fetchedAgo: 0, hash: 7)
        a.rawData = raw
        b.rawData = raw
        collision.rawData = raw.dropLast()
        let stored = BandSyncer.parseStoredFiles([a, b, collision])
        #expect(stored.parsed.count == 3)
        #expect(stored.firstHolders == [ObjectIdentifier(a), ObjectIdentifier(collision)])
    }

    // MARK: - Health samples

    @Test func loggedMedianIsTheWrittenSamplesMedian() {
        let replaced = block(start: t0, minutes: 1, wobble: 60)
        let kept = block(start: t0, minutes: 1, wobble: 20)
        let corrupt = block(start: Date(timeIntervalSince1970: 1_500_000_000), minutes: 1, wobble: 100)
        let (samples, median) = HealthKitManager.hrvToWrite([replaced, kept, corrupt])
        #expect(samples.count == 1)
        let written = (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: .secondUnit(with: .milli))
        #expect(median != nil && median == written)
        #expect((median ?? .infinity) < 20)
    }

    @Test func syncIdentifierFollowsTheBlockNotTheChosenMinute() {
        let first = block(start: t0, minutes: 3)
        var rescored = first
        for i in [10, 20, 30, 40, 50] { rescored.intervalsMs[i] = 1600 }
        let a = HealthKitManager.hrvSamples([first]), b = HealthKitManager.hrvSamples([rescored])
        #expect(a.first?.startDate != b.first?.startDate)
        let ids = (a + b).map { $0.metadata?[HKMetadataKeySyncIdentifier] as? String }
        #expect(ids == ["mb-hrv-1790000000", "mb-hrv-1790000000"])
        #expect((a + b).allSatisfy { $0.metadata?[HKMetadataKeySyncVersion] as? Int == HealthKitManager.hrvAlgorithmVersion })
    }

    @Test func samplesAreCreditedToTheBand() {
        let sample = HealthKitManager.hrvSamples([block(start: t0, minutes: 1)]).first
        #expect(sample?.device?.name == "Xiaomi Smart Band 10")
        #expect(sample?.device?.manufacturer == "Xiaomi")
        #expect(sample?.quantityType == HKQuantityType(.heartRateVariabilitySDNN))
    }
}
