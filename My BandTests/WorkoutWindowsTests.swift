import Testing
import Foundation
@testable import My_Band

struct WorkoutWindowsTests {

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "WorkoutWindowsTests"))
        defaults.removePersistentDomain(forName: "WorkoutWindowsTests")
        return defaults
    }

    @Test func windowsFromAnEarlierSyncAreStillThere() throws {
        let defaults = try freshDefaults()
        let run = WorkoutWindows.Window(start: .now.addingTimeInterval(-7200), end: .now.addingTimeInterval(-3600))
        WorkoutWindows(defaults: defaults).record([run])
        WorkoutWindows(defaults: defaults).record([run])
        #expect(WorkoutWindows(defaults: defaults).all() == [run])
    }

    @Test func windowsOlderThanTheKeepPeriodAreDropped() throws {
        let defaults = try freshDefaults()
        let now = Date()
        let old = WorkoutWindows.Window(start: now.addingTimeInterval(-WorkoutWindows.keep - 7200),
                                        end: now.addingTimeInterval(-WorkoutWindows.keep - 3600))
        let recent = WorkoutWindows.Window(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        WorkoutWindows(defaults: defaults).record([old, recent], now: now)
        #expect(WorkoutWindows(defaults: defaults).all(now: now) == [recent])
    }
}
