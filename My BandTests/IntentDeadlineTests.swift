import Testing
import Foundation
@testable import My_Band

@MainActor
struct IntentDeadlineTests {

    @Test func syncFinishingInTimeReturnsItsOutcome() async throws {
        var expected = BandSyncer.HealthSyncOutcome()
        expected.workouts = 2
        let sync = Task<BandSyncer.HealthSyncOutcome, Error> { expected }
        let outcome = try await BackgroundSyncManager.value(of: sync, within: .seconds(5))
        #expect(outcome.workouts == 2)
    }

    @Test func syncPastTheDeadlineThrowsStillSyncingAndKeepsRunning() async throws {
        let sync = Task<BandSyncer.HealthSyncOutcome, Error> {
            try await Task.sleep(for: .milliseconds(400))
            var o = BandSyncer.HealthSyncOutcome()
            o.sleepSessions = 1
            return o
        }
        await #expect(throws: BackgroundSyncManager.StillSyncing.self) {
            try await BackgroundSyncManager.value(of: sync, within: .milliseconds(50))
        }
        #expect(!sync.isCancelled)
        let finished = try await sync.value
        #expect(finished.sleepSessions == 1)
    }

    @Test func syncFailingBeforeTheDeadlineRethrowsItsError() async {
        let sync = Task<BandSyncer.HealthSyncOutcome, Error> { throw SyncError.notConnected }
        await #expect(throws: SyncError.self) {
            try await BackgroundSyncManager.value(of: sync, within: .seconds(5))
        }
    }
}
