import Foundation
import OSLog

// MARK: - WatchfaceService
//
// Watch face management for the Mi Band 10 (GadgetBridge XiaomiWatchfaceService, type=4):
// list / set active / delete / install. Install announces the face (installStart), waits for the
// band's installStatus, then streams the bytes via DataUploadService (TYPE_WATCHFACE) and finally
// activates it.

@Observable
@MainActor
final class WatchfaceService {

    struct Face: Identifiable, Equatable {
        let id: String
        let name: String
        let active: Bool
        let canDelete: Bool
    }

    private(set) var faces: [Face] = []
    private(set) var installProgress: Double?     // nil when idle

    private weak var bandManager: BandManager?
    private let upload: DataUploadService
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Watchface")
    private var statusContinuation: CheckedContinuation<UInt32, Error>?

    init(upload: DataUploadService) { self.upload = upload }

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onWatchfaceCommand = { [weak self] cmd in
            Task { @MainActor in self?.handle(cmd) }
        }
    }

    // MARK: - Actions

    func requestList() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.watchfaceListCommand())
    }

    func setActive(_ id: String) {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.watchfaceSetCommand(id: id))
        requestList()
    }

    func delete(_ id: String) {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.watchfaceDeleteCommand(id: id))
        // The band re-sends the list on the delete ack (handled below).
    }

    func install(_ file: InstallableFile) async throws {
        guard file.kind == .watchface else { return }
        guard let manager = bandManager, manager.connectionState.isConnected else {
            throw DataUploadService.UploadError.notConnected
        }
        installProgress = 0
        defer { installProgress = nil }

        log.info("Installing watch face id=\(file.id) (\(file.bytes.count)B)")
        manager.sendEncryptedCommand(
            protoBytes: XiaomiProto.watchfaceInstallStartCommand(id: file.id, size: file.bytes.count)
        )
        let status = try await waitForStatus(timeout: .seconds(15))
        guard status == 0 else {
            log.error("Watch face install rejected (status=\(status))")
            throw DataUploadService.UploadError.rejected
        }

        try await upload.upload(type: XiaomiDataUploadCmd.typeWatchface, bytes: file.bytes) { [weak self] p in
            self?.installProgress = p
        }

        setActive(file.id)
        log.info("Watch face installed and activated")
    }

    // MARK: - Incoming

    private func handle(_ cmd: Xiaomi_Command) {
        switch cmd.subtype {
        case XiaomiWatchfaceCmd.list where cmd.hasWatchface:
            faces = cmd.watchface.watchfaceList.watchface.map {
                Face(id: $0.id, name: $0.name.isEmpty ? $0.id : $0.name,
                     active: $0.active, canDelete: $0.canDelete)
            }
            log.debug("Watch face list: \(self.faces.count) face(s)")
        case XiaomiWatchfaceCmd.install where cmd.hasWatchface:
            if let cont = statusContinuation {
                statusContinuation = nil
                cont.resume(returning: cmd.watchface.installStatus)
            }
        case XiaomiWatchfaceCmd.delete:
            requestList()
        default:
            break
        }
    }

    private func waitForStatus(timeout: Duration) async throws -> UInt32 {
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            if let cont = statusContinuation {
                statusContinuation = nil
                cont.resume(throwing: DataUploadService.UploadError.timeout)
            }
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            statusContinuation = cont
        }
    }
}
