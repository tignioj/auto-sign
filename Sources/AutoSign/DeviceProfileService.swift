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
    }

    static func installedProfiles(on device: AppleDevice) async throws -> [Data] {
        let response = try await run(["list", device.udid], on: device)
        guard let profiles = response.profiles else {
            throw ProfileRefreshError.verification("设备没有返回描述文件列表，无法确认续签结果。")
        }
        return profiles
    }

    static func install(_ url: URL, on device: AppleDevice) async throws {
        _ = try await run(["install", device.udid, url.path], on: device)
    }

    static func verify(_ url: URL, on device: AppleDevice) async throws {
        let expected = try Data(contentsOf: url)
        let installed = try await installedProfiles(on: device)
        // Exact CMS bytes establish that the device holds the same Apple-signed
        // UUID, issue date, certificates and expiry that we validated locally.
        guard installed.contains(expected) else {
            throw ProfileRefreshError.incompatible("设备未保存新的描述文件，改用完整安装更新签名。")
        }
    }

    static func decodeResponse(_ result: CommandResult) throws -> Response {
        // MobileDevice can emit diagnostics before our helper's single JSON line.
        guard let line = result.output.split(separator: "\n").last,
              let response = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)) else {
            throw ProfileRefreshError.unavailable("设备描述文件组件未正常完成（\(result.status)）：\(result.output.prefix(500))")
        }
        guard result.status == 0, response.kind == "success" else {
            // Also suppress the misleading success detail from older helpers.
            let detail = response.status == 0 || response.detail == "kAMDSuccess" ? nil : response.detail
            let message = [response.message, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
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

    private static func run(_ arguments: [String], on device: AppleDevice) async throws -> Response {
        try Task.checkCancellation()
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AutoSignDeviceHelper")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/AutoSignDeviceHelper")
        guard let executable = [sibling, development].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw ProfileRefreshError.unsupported("缺少描述文件更新组件，使用完整签名安装。请重新构建完整 AutoSign.app。")
        }
        do {
            return try await withConnectionRetry {
                let result = try await ProcessRunner.run(executable.path, arguments)
                try Task.checkCancellation()
                return try decodeResponse(result)
            }
        } catch ProfileRefreshError.deviceNotFound(let message) {
            throw try await missingDeviceError(message, on: device)
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
            return .unavailable("手机已锁定，无法确认描述文件连接是否可用，请解锁后重试。")
        }
        try Task.checkCancellation()
        // CoreDevice can reach devices whose legacy MobileDevice transport is
        // unavailable. Only a fresh successful probe allows installation fallback.
        return .unsupported("设备可通过 Xcode 连接，但当前连接不支持单独更新描述文件，改用完整签名安装")
    }

    static func withConnectionRetry<T>(operation: () async throws -> T,
                                      beforeRetry: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) async throws -> T {
        var attempts = 0
        while true {
            try Task.checkCancellation()
            attempts += 1
            do { return try await operation() }
            catch {
                guard attempts < 3, case ProfileRefreshError.unavailable(let message) = error,
                      ["kAMDMuxConnectError", "kAMDNotConnectedError", "kAMDConnectionFailedError"]
                        .contains(where: message.contains) else { throw error }
                // Start a fresh helper/session after the on-demand Wi-Fi transport
                // has had a chance to become ready. Never retry lock/profile errors.
                try await beforeRetry()
            }
        }
    }
}
