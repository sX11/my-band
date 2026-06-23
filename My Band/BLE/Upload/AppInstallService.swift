import Foundation
import OSLog

// MARK: - AppInstallService
//
// Quick-app (RPK) management for the Mi Band 10 (GadgetBridge XiaomiRpkService, type=20):
// list / install / delete. Install announces the app (rpkInfo{id, versionCode, size}), waits for
// the band's status, streams the bytes via DataUploadService (TYPE_RPK), and the band reports
// completion with CMD_RPK_INSTALLED, on which we refresh the list.

@Observable
@MainActor
final class AppInstallService {

    struct App: Identifiable, Equatable {
        let id: String          // package name
        let name: String
        let sha: Data           // needed to delete it later
    }

    private(set) var apps: [App] = []
    private(set) var installProgress: Double?     // nil when idle

    private weak var bandManager: BandManager?
    private let upload: DataUploadService
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "AppInstall")
    private var statusContinuation: CheckedContinuation<UInt32, Error>?

    init(upload: DataUploadService) { self.upload = upload }

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onRpkCommand = { [weak self] cmd in
            Task { @MainActor in self?.handle(cmd) }
        }
    }

    // MARK: - Actions

    func requestList() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.rpkListCommand())
    }

    func delete(_ app: App) {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.rpkDeleteCommand(id: app.id, sha: app.sha))
        // The band re-sends the list on the delete ack (handled below).
    }

    func install(_ file: InstallableFile) async throws {
        guard file.kind == .app else { return }
        guard let manager = bandManager, manager.connectionState.isConnected else {
            throw DataUploadService.UploadError.notConnected
        }
        installProgress = 0
        defer { installProgress = nil }

        log.info("Installing app \(file.id) v\(file.versionCode) (\(file.bytes.count)B)")
        manager.sendEncryptedCommand(
            protoBytes: XiaomiProto.rpkInstallCommand(id: file.id, versionCode: file.versionCode, size: file.bytes.count)
        )
        let status = try await waitForStatus(timeout: .seconds(15))
        guard status == 0 else {
            log.error("App install rejected (status=\(status))")
            throw DataUploadService.UploadError.rejected
        }

        try await upload.upload(type: XiaomiDataUploadCmd.typeRpk, bytes: file.bytes) { [weak self] p in
            self?.installProgress = p
        }
        log.info("App bytes uploaded — awaiting band install confirmation")
        // The band finishes asynchronously and pushes CMD_RPK_INSTALLED → handle() refreshes the list.
    }

    // MARK: - Incoming

    private func handle(_ cmd: Xiaomi_Command) {
        switch cmd.subtype {
        case XiaomiRpkCmd.list where cmd.hasRpk:
            apps = cmd.rpk.rpkList.rpkInfo.map {
                App(id: $0.id, name: $0.name.isEmpty ? $0.id : $0.name, sha: $0.sha)
            }
            log.debug("App list: \(self.apps.count) app(s)")
        case XiaomiRpkCmd.install where cmd.hasRpk:
            if let cont = statusContinuation {
                statusContinuation = nil
                cont.resume(returning: cmd.rpk.rpkInstallStart.cmd)
            }
        case XiaomiRpkCmd.installed, XiaomiRpkCmd.delete:
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
