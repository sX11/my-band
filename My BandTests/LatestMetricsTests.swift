import Testing
import Foundation
import SwiftData
@testable import My_Band

@MainActor
struct LatestMetricsTests {

    private let now = Date()

    private func summary(daysAgo: Int, resting: Int, mask: Int? = nil) -> DailySummary {
        var s = DailySummary(date: now.addingTimeInterval(-Double(daysAgo) * 86_400), steps: 0, caloriesKcal: 0)
        s.restingHR = resting
        s.standingHours = mask
        return s
    }

    @Test func olderSummaryDoesNotReplaceNewer() {
        var m = LatestMetrics()
        m.record(summary(daysAgo: 0, resting: 60))
        m.record(summary(daysAgo: 2, resting: 70))
        #expect(m.restingHR == 60)
    }

    @Test func futureSummaryIsIgnored() {
        var m = LatestMetrics()
        m.record(summary(daysAgo: 0, resting: 60))
        m.record(summary(daysAgo: -2, resting: 70))
        #expect(m.restingHR == 60)
    }

    @Test func standingHoursCountsMaskBits() {
        var m = LatestMetrics()
        m.record(summary(daysAgo: 0, resting: 60, mask: 0b1011_0000_0000))
        #expect(m.standingHours == 3)
    }

    @Test func newestSampleWinsAcrossSources() {
        var m = LatestMetrics()
        m.record([ActivityMinuteSample(date: now.addingTimeInterval(-600), heartRate: 70)])
        m.record([ManualSample(date: now.addingTimeInterval(-60), kind: .heartRate, value: 90)])
        m.record([ActivityMinuteSample(date: now.addingTimeInterval(-300), heartRate: 75)])
        #expect(m.heartRate?.value == 90)
    }

    @Test func futureSampleIsIgnored() {
        var m = LatestMetrics()
        m.record([ManualSample(date: now.addingTimeInterval(86_400), kind: .spo2, value: 97)])
        #expect(m.spo2 == nil)
    }

    @Test func storeSurvivesReloadAndReset() throws {
        let defaults = try #require(UserDefaults(suiteName: "LatestMetricsTests"))
        defaults.removePersistentDomain(forName: "LatestMetricsTests")
        let store = LatestMetricsStore(defaults: defaults)
        store.update { $0.record([ManualSample(date: now, kind: .stress, value: 30)]) }
        #expect(LatestMetricsStore(defaults: defaults).metrics.stress?.value == 30)
        store.reset()
        #expect(LatestMetricsStore(defaults: defaults).metrics.isEmpty)
    }

    @Test func lastNightMergesOverlappingSessionsWithoutDoubleCounting() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func phase(_ from: Int, _ to: Int, _ type: SleepPhaseType) -> SleepPhase {
            SleepPhase(startDate: t0.addingTimeInterval(Double(from) * 60), endDate: t0.addingTimeInterval(Double(to) * 60), type: type)
        }
        let early = SleepSession(startDate: t0, endDate: t0.addingTimeInterval(180 * 60),
                                 phases: [phase(0, 120, .light), phase(120, 180, .deep)])
        let resync = SleepSession(startDate: t0, endDate: t0.addingTimeInterval(300 * 60),
                                  phases: [phase(0, 120, .light), phase(120, 180, .deep), phase(180, 300, .rem)])
        let night = try #require(LatestMetricsView.lastNight([resync, early]))
        #expect(night.asleep == 300 * 60)
        #expect(night.duration(.deep) == 60 * 60)
        #expect(night.end == t0.addingTimeInterval(300 * 60))
    }

    @Test func sleepFetchReturnsOnlyThePairedBandsSessions() throws {
        let container = try ModelContainer(for: BandDevice.self, SleepSession.self, ActivityDay.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let paired = BandDevice(name: "new", peripheralIdentifier: "a")
        let forgotten = BandDevice(name: "old", peripheralIdentifier: "b")
        context.insert(paired)
        context.insert(forgotten)
        let mine = SleepSession(startDate: .now.addingTimeInterval(-9 * 3600), endDate: .now.addingTimeInterval(-2 * 3600), phases: [])
        let theirs = SleepSession(startDate: .now.addingTimeInterval(-8 * 3600), endDate: .now.addingTimeInterval(-1 * 3600), phases: [])
        context.insert(mine)
        context.insert(theirs)
        mine.device = paired
        theirs.device = forgotten
        try context.save()
        let fetched = try context.fetch(LatestMetricsView.sleepDescriptor(deviceID: paired.id))
        #expect(fetched.map(\.id) == [mine.id])
        #expect(try context.fetch(LatestMetricsView.sleepDescriptor(deviceID: nil)).isEmpty)
    }

    @Test func standingDetailMergesRuns() {
        #expect(LatestMetricsView.standingDetail(0b0100_0111_0000_0000) == "8:00–11:00, 14:00–15:00")
        #expect(LatestMetricsView.standingDetail(0) == nil)
    }
}
