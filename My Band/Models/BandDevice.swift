import Foundation
import SwiftData

@Model
final class BandDevice {

    var id: UUID
    var name: String
    /// CBPeripheral.identifier.uuidString — used to retrieve a known peripheral after app relaunch
    var peripheralIdentifier: String
    var addedDate: Date
    var lastSyncDate: Date?

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \SleepSession.device)
    var sleepSessions: [SleepSession] = []

    @Relationship(deleteRule: .cascade, inverse: \ActivityDay.device)
    var activityDays: [ActivityDay] = []

    // MARK: - Init

    init(name: String, peripheralIdentifier: String) {
        self.id = UUID()
        self.name = name
        self.peripheralIdentifier = peripheralIdentifier
        self.addedDate = Date()
    }
}
