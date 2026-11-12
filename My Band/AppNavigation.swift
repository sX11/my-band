import Foundation
import Observation

// MARK: - AppNavigation
//
// Where a notification tap asks the UI to go. RootView turns to the Sleep & trends page, and
// TrendsView opens the night once a load begun after the tap finishes, then clears it.

@Observable
@MainActor
final class AppNavigation {

    static let shared = AppNavigation()

    /// The day a night ends on, at the start of that day.
    var openNight: Date?

    private init() {}
}
