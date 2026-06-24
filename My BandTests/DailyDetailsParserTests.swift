import Testing
import Foundation
@testable import My_Band

@MainActor
struct DailyDetailsParserTests {

    private func meta(_ data: Data) -> XiaomiActivityFileMeta {
        guard let m = XiaomiActivityFileMeta(data.prefix(7)) else {
            fatalError("fixture has no valid 7-byte file id")
        }
        return m
    }

    @Test func metaRoutesToDailyDetails() {
        let data = Fixtures.bytes(Fixtures.dailyDetailsV4Short)
        let m = meta(data)
        #expect(m.isDailyDetails)
        #expect(m.version == 4)
        #expect(m.detail == .details)
    }

    @Test func shortFileYieldsFiveMinutes() {
        // 98 bytes − 4 CRC − 7 fileId − 1 pad − 6 header = 80 payload bytes; each record
        // is 16 bytes here, so five one-minute samples.
        let data = Fixtures.bytes(Fixtures.dailyDetailsV4Short)
        let samples = DailyDetailsParser.parse(data, meta: meta(data))
        #expect(samples.count == 5)
    }

    @Test func samplesAreOneMinuteApartFromFileTimestamp() {
        let data = Fixtures.bytes(Fixtures.dailyDetailsV4Short)
        let m = meta(data)
        let samples = DailyDetailsParser.parse(data, meta: m)
        #expect(samples.first?.date == m.timestamp)
        for (i, s) in samples.enumerated() {
            #expect(s.date == m.timestamp.addingTimeInterval(TimeInterval(i * 60)))
        }
    }

    @Test func firstMinuteCarriesSpO2AndStress() throws {
        let data = Fixtures.bytes(Fixtures.dailyDetailsV4Short)
        let first = try #require(DailyDetailsParser.parse(data, meta: meta(data)).first)
        #expect(first.spo2 == 97)
        #expect(first.stress == 36)
        #expect(first.steps == nil)
        #expect(first.heartRate == nil)
    }

    @Test func longFileDecodesPlausiblePhysiology() {
        // Structural invariants that hold regardless of the per-minute bit layout:
        // every surfaced HR / SpO₂ value is in a physiological range and timestamps march.
        let data = Fixtures.bytes(Fixtures.dailyDetailsV4Long)
        let m = meta(data)
        let samples = DailyDetailsParser.parse(data, meta: m)

        #expect(!samples.isEmpty)
        for (i, s) in samples.enumerated() {
            #expect(s.date == m.timestamp.addingTimeInterval(TimeInterval(i * 60)))
            if let hr = s.heartRate { #expect(hr >= 1 && hr <= 255) }
            if let spo2 = s.spo2 { #expect(spo2 >= 1 && spo2 <= 100) }
            if let steps = s.steps { #expect(steps >= 1) }
        }
        // The capture contains real movement and HR, so at least one of each must appear.
        #expect(samples.contains { $0.steps != nil })
        #expect(samples.contains { $0.heartRate != nil })
    }

    @Test func degenerateFileDoesNotCrash() {
        // 18-byte file with no minute records — must return without crashing.
        let data = Fixtures.bytes(Fixtures.dailyDetailsV4Empty)
        let samples = DailyDetailsParser.parse(data, meta: meta(data))
        #expect(samples.count <= 1)
    }

    @Test func unsupportedVersionReturnsEmpty() {
        // Version 7 is outside the 1...4 the parser handles.
        var data = Fixtures.bytes(Fixtures.dailyDetailsV4Short)
        data[data.startIndex + 5] = 7
        #expect(DailyDetailsParser.parse(data, meta: meta(data)).isEmpty)
    }
}
