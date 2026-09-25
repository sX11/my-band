import Testing
import Foundation
@testable import My_Band

// The app module defaults to MainActor isolation (SWIFT_DEFAULT_ACTOR_ISOLATION),
// so the parsers are MainActor-isolated; the suite runs on the main actor to call them.
@MainActor
struct DailySummaryParserTests {

    private func meta(_ data: Data) -> XiaomiActivityFileMeta {
        guard let m = XiaomiActivityFileMeta(data.prefix(7)) else {
            fatalError("fixture has no valid 7-byte file id")
        }
        return m
    }

    @Test func metaRoutesToDailySummary() {
        let data = Fixtures.bytes(Fixtures.dailySummaryV5)
        let m = meta(data)
        #expect(m.isDailySummary)
        #expect(m.version == 5)
        #expect(m.detail == .summary)
    }

    @Test func decodesStepsCaloriesAndSpO2() throws {
        let data = Fixtures.bytes(Fixtures.dailySummaryV5)
        let summary = try #require(DailySummaryParser.parse(data, meta: meta(data)))

        #expect(summary.steps == 1111)
        #expect(summary.caloriesKcal == 200)
        #expect(summary.spo2Avg == 98)
        #expect(summary.spo2Max?.pct == 98)
        #expect(summary.spo2Min?.pct == 98)
    }

    @Test func leavesUnmeasuredHeartRateFieldsNil() throws {
        // In this capture the HR fields are 0 (avg/max/resting) or have a 0 timestamp
        // (min=255 but ts=0), so none should surface.
        let data = Fixtures.bytes(Fixtures.dailySummaryV5)
        let summary = try #require(DailySummaryParser.parse(data, meta: meta(data)))

        #expect(summary.restingHR == nil)
        #expect(summary.avgHR == nil)
        #expect(summary.maxHR == nil)
        #expect(summary.minHR == nil)
        #expect(summary.avgStress == nil)
        #expect(summary.standingHours == nil)
    }

    @Test func rejectsUnsupportedVersion() {
        // Flip the version byte (index 5) to 4, which DailySummaryParser does not support;
        // it must return nil so the caller can fall back to the details parser.
        var data = Fixtures.bytes(Fixtures.dailySummaryV5)
        data[data.startIndex + 5] = 4
        #expect(DailySummaryParser.parse(data, meta: meta(data)) == nil)
    }

    @Test func rejectsFileTruncatedBeforeSpO2Fields() {
        let full = Fixtures.bytes(Fixtures.dailySummaryV5)
        let truncated = full.prefix(7 + 1 + 4 + 40)
        #expect(DailySummaryParser.parse(truncated, meta: meta(truncated)) == nil)
    }

    @Test func datedAtFileTimestamp() throws {
        let data = Fixtures.bytes(Fixtures.dailySummaryV5)
        let m = meta(data)
        let summary = try #require(DailySummaryParser.parse(data, meta: m))
        #expect(summary.date == m.timestamp)
    }
}
