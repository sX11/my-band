import Testing
import Foundation
@testable import My_Band

// Validates the reverse-engineered workout per-second HR detail format (type=sports,
// detail=details, subtype 8, version 3) against a real Mi Band 10 capture.
@MainActor
struct WorkoutDetailsParserTests {

    private func meta(_ data: Data) -> XiaomiActivityFileMeta {
        guard let m = XiaomiActivityFileMeta(data.prefix(7)) else {
            fatalError("fixture has no valid 7-byte file id")
        }
        return m
    }

    @Test func metaRoutesToWorkoutDetails() {
        let m = meta(Fixtures.bytes(Fixtures.workoutHrDetailV3))
        #expect(m.isWorkoutDetails)
        #expect(m.type == .sports)
        #expect(m.detail == .details)
        #expect(m.subtype == 8)
        #expect(m.version == 3)
    }

    @Test func parsesValidHeartRateSeries() {
        let data = Fixtures.bytes(Fixtures.workoutHrDetailV3)
        let samples = WorkoutDetailsParser.parse(data, meta: meta(data))

        // 135 one-second slots, first 18 are 0 (sensor acquiring) and dropped → 117 valid readings.
        #expect(samples.count == 117)
        #expect(samples.allSatisfy { (74...87).contains($0.bpm) })
        #expect(samples.first?.bpm == 74)
        #expect(samples.last?.bpm == 80)
    }

    @Test func samplesAreOneSecondApartFromWorkoutStart() {
        let data = Fixtures.bytes(Fixtures.workoutHrDetailV3)
        let m = meta(data)
        let samples = WorkoutDetailsParser.parse(data, meta: m)

        // First valid reading is at second 18 (18 leading zero samples were dropped).
        #expect(samples.first?.date == m.timestamp.addingTimeInterval(18))
        // Strictly increasing, one second apart.
        for (prev, next) in zip(samples, samples.dropFirst()) {
            #expect(next.date.timeIntervalSince(prev.date) == 1)
        }
        // Whole series stays within the 135-second workout window.
        #expect(samples.last!.date <= m.timestamp.addingTimeInterval(135))
    }

    @Test func unsupportedVersionYieldsEmpty() {
        // Flip the version byte (index 5) to something unconfirmed; the parser must bail rather than
        // misread an unknown header. The caller still ACKs the file.
        var data = Fixtures.bytes(Fixtures.workoutHrDetailV3)
        data[data.startIndex + 5] = 9
        #expect(WorkoutDetailsParser.parse(data, meta: meta(data)).isEmpty)
    }
}
