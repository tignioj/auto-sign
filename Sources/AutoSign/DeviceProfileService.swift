import AutoSignLocalization
import Foundation

enum ProfileRefreshError: LocalizedError, Sendable {
    case unsupported(String)
    case incompatible(String)
    case unavailable(String)
    case deviceNotFound(String)
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message), .incompatible(let message), .unavailable(let message),
             .deviceNotFound(let message), .verification(let message): message
        }
    }
}

enum DeviceProfileService {
    struct Response: Decodable {
        let kind: String
        var message: String?
        var detail: String?
        var status: Int?
        var profiles: [Data]?
        var transport: String?
    }

    static func installedProfiles(on device: AppleDevice,
                                  statusChanged: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> [Data] {
        let response = try await run(["list", device.udid], on: device, statusChanged: statusChanged)
        guard let profiles = response.profiles else {
            throw ProfileRefreshError.verification(L10n.tr("设备没有返回描述文件列表，无法确认续签结果。"))
        }
        return profiles
    }

    static func install(_ url: URL, on device: AppleDevice,
                        statusChanged: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws {
        _ = try await run(["install", device.udid, url.path], on: device, statusChanged: statusChanged)
    }

    static func verify(_ url: URL, on device: AppleDevice,
                       statusChanged: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws {
        let expected = try Data(contentsOf: url)
        let installed = try await installedProfiles(on: device, statusChanged: statusChanged)
        // Exact CMS bytes establish that the device holds the same Apple-signed
        // UUID, issue date, certificates and expiry that we validated locally.
        guard installed.contains(expected) else {
            throw ProfileRefreshError.incompatible(L10n.tr("设备未保存新的描述文件，改用完整安装更新签名。"))
        }
    }

    static func decodeResponse(_ result: CommandResult) throws -> Response {
        // MobileDevice can emit diagnostics before our helper's single JSON line.
        guard let line = result.output.split(separator: "\n").last,
              let response = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)) else {
            throw ProfileRefreshError.unavailable(L10n.tr("设备描述文件组件未正常完成（\(result.status)）：\(result.output.prefix(500))"))
        }
        guard result.status == 0, response.kind == "success" else {
            // Also suppress the misleading success detail from older helpers.
            let detail = response.status == 0 || response.detail == "kAMDSuccess" ? nil : response.detail
            let message = [response.message.map { L10n.helperMessage($0) }, detail]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            switch response.kind {
            case "deviceNotFound": throw ProfileRefreshError.deviceNotFound(message)
            case "unsupported": throw ProfileRefreshError.unsupported(message)
            case "rejected": throw ProfileRefreshError.incompatible(message)
            case "invalid": throw ProfileRefreshError.verification(message)
            default: throw ProfileRefreshError.unavailable(message)
            }
        }
        return response
    }

    private static func run(_ arguments: [String], on device: AppleDevice,
                            statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws -> Response {
        try Task.checkCancellation()
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AutoSignDeviceHelper")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/AutoSignDeviceHelper")
        guard let executable = [sibling, development].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw ProfileRefreshError.unsupported(L10n.tr("缺少描述文件更新组件，使用完整签名安装。请重新构建完整 AutoSign.app。"))
        }
        return try await withTransportRecovery(legacy: {
            try await withConnectionRetry(operation: {
                let result = try await ProcessRunner.run(executable.path, arguments)
                try Task.checkCancellation()
                return try decodeResponse(result)
            }, beforeRetry: {
                await statusChanged(L10n.tr("描述文件连接暂时中断，正在重新连接设备…"))
                try await DeviceConnectionRetry.reconnect(to: device)
            })
        }, remote: {
            await statusChanged(L10n.tr("正在通过 CoreDevice 重新连接描述文件服务…"))
            return try await RemoteDeviceProfileService.run(arguments, on: device)
        }, missingDevice: { message in
            try await missingDeviceError(message, on: device)
        })
    }

    static func withTransportRecovery<T>(legacy: () async throws -> T, remote: () async throws -> T,
                                         missingDevice: (String) async throws -> ProfileRefreshError) async throws -> T {
        do { return try await legacy() }
        catch ProfileRefreshError.deviceNotFound(let message) {
            try Task.checkCancellation()
            do { return try await remote() }
            catch ProfileRefreshError.deviceNotFound { throw try await missingDevice(message) }
        } catch ProfileRefreshError.unavailable(let message) where DeviceConnectionRetry.isTransient(message) {
            try Task.checkCancellation()
            // A discovered Wi-Fi device can have a stale legacy Mux endpoint.
            // Use the independently verified CoreDevice channel before giving up.
            do { return try await remote() }
            catch ProfileRefreshError.deviceNotFound(let remoteMessage) {
                // A transient connection error must never become a capability
                // failure that permits replacing the installed application.
                throw ProfileRefreshError.unavailable("\(message)\n\(remoteMessage)")
            }
        }
    }

    static func missingDeviceError(_ message: String, on device: AppleDevice,
                                   probe: (AppleDevice) async -> AppleDevice? = { await DeviceService.probeConnection(to: $0) },
                                   isUnlocked: (AppleDevice) async throws -> Bool = { try await DeviceAppVerification.isUnlocked(on: $0) }) async throws -> ProfileRefreshError {
        try Task.checkCancellation()
        let reachable = await probe(device)
        try Task.checkCancellation()
        guard let reachable, reachable.udid == device.udid, reachable.isReadyForInstallation else {
            return .unavailable(message)
        }
        guard try await isUnlocked(reachable) else {
            return .unavailable(L10n.tr("手机已锁定，无法确认描述文件连接是否可用，请解锁后重试。"))
        }
        try Task.checkCancellation()
        // CoreDevice can reach devices whose legacy MobileDevice transport is
        // unavailable. Only a fresh successful probe allows installation fallback.
        return .unsupported(L10n.tr("设备可通过 Xcode 连接，但当前连接不支持单独更新描述文件，改用完整签名安装"))
    }

    static func withConnectionRetry<T>(operation: () async throws -> T,
                                      beforeRetry: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) async throws -> T {
        try await DeviceConnectionRetry.run(operation: operation, beforeRetry: beforeRetry)
    }
}
