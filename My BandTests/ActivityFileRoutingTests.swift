import Testing
import Foundation
@testable import My_Band

// Routing-layer test for the intra-workout sensor-detail files (type=sports detail=details).
// These once fell through every BandSyncer branch — fetched but never ACKed, so the band
// re-offered them forever. They now route to `isWorkoutDetails` (parsed when version is known,
// otherwise still ACKed); any file matching no predicate at all is ACKed by the final `else`.
@MainActor
struct ActivityFileRoutingTests {

    private func meta(_ id: String) -> XiaomiActivityFileMeta {
        guard let m = XiaomiActivityFileMeta(Fixtures.bytes(id)) else {
            fatalError("fixture has no valid 7-byte file id: \(id)")
        }
        return m
    }

    @Test func sportsDetailFilesDecodeAsSportsDetails() {
        for id in Fixtures.sportsDetailIds {
            let m = meta(id)
            #expect(m.type == .sports)
            #expect(m.detail == .details)
        }
    }

    @Test func sportsDetailFilesRouteToWorkoutDetails() {
        // They match isWorkoutDetails (the new branch) and none of the other parser predicates.
        for id in Fixtures.sportsDetailIds {
            let m = meta(id)
            #expect(m.isWorkoutDetails)
            #expect(!m.isSleep)
            #expect(!m.isDailySummary)
            #expect(!m.isDailyDetails)
            #expect(!m.isManualSamples)
            #expect(!m.isWorkoutSummary)
            #expect(!m.isWorkoutGps)
        }
    }

    @Test func decodesExpectedSportsSubtypes() {
        let subtypes = Fixtures.sportsDetailIds.map { meta($0).subtype }
        #expect(subtypes == [8, 8, 8, 8, 22, 22])
    }
}
