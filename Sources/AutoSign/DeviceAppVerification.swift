import Foundation

enum DeviceAppVerification {
    struct Application: Decodable, Equatable, Sendable {
        let bundleIdentifier: String
        let url: URL
        let version: String?
        let bundleVersion: String?
    }
    private struct Applications: Decodable {
        struct Result: Decodable { let apps: [Application] }
        let result: Result
    }
    private struct Launch: Decodable {
        struct Result: Decodable {
            struct Process: Decodable { let processIdentifier: Int }
            let process: Process
        }
        let result: Result
    }
    private struct Processes: Decodable {
        struct Result: Decodable {
            struct Process: Decodable { let processIdentifier: Int }
            let runningProcesses: [Process]
        }
        let result: Result
    }
    private struct LockState: Decodable {
        struct Result: Decodable { let passcodeRequired: Bool }
        let result: Result
    }

    static func application(_ bundleID: String, on device: AppleDevice) async throws -> Application? {
        let data = try await command(["device", "info", "apps", "--device", device.udid, "--bundle-id", bundleID])
        return try JSONDecoder().decode(Applications.self, from: data).result.apps.first { $0.bundleIdentifier == bundleID }
    }

    @discardableResult
    static func verifyLaunch(_ bundleID: String, on device: AppleDevice, freshLaunch: Bool = false) async throws -> Int {
        guard try await isUnlocked(on: device) else {
            throw ProfileRefreshError.unavailable("手机已锁定，无法验证应用启动；请解锁设备后重新刷新。")
        }
        // Do not terminate a running Store or bring background renewals to the
        // foreground. A separate real-device test also verifies a fresh launch.
        let data = try await command(["device", "process", "launch", "--device", device.udid,
                                      "--no-activate"] + (freshLaunch ? ["--terminate-existing"] : []) + [bundleID], checkingSignature: true)
        let pid = try JSONDecoder().decode(Launch.self, from: data).result.process.processIdentifier
        try await Task.sleep(for: .seconds(2))
        let processes = try await command(["device", "info", "processes", "--device", device.udid])
        guard try JSONDecoder().decode(Processes.self, from: processes).result.runningProcesses.contains(where: {
            $0.processIdentifier == pid
        }) else {
            throw ProfileRefreshError.verification("应用启动后已退出，续签尚未通过启动验证，请解锁设备后检查应用。")
        }
        return pid
    }

    static func isUnlocked(on device: AppleDevice) async throws -> Bool {
        let lock = try await command(["device", "info", "lockState", "--device", device.udid])
        return try !JSONDecoder().decode(LockState.self, from: lock).result.passcodeRequired
    }

    static func isSignatureFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return ["invalid code signature", "signature is invalid", "valid provisioning profile",
                "untrusted developer", "0xe8008015", "0xe8008018", "0xe8008029"].contains { lower.contains($0) }
    }

    private static func command(_ arguments: [String], checkingSignature: Bool = false) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autosign-verify-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Task.checkCancellation()
        let result = try await ProcessRunner.run("/usr/bin/xcrun", ["devicectl"] + arguments
            + ["--timeout", "30", "--json-output", url.path, "--quiet"])
        try Task.checkCancellation()
        guard result.status == 0 else {
            if checkingSignature, isSignatureFailure(result.output) {
                throw ProfileRefreshError.incompatible("应用未通过设备签名检查：\(result.output)")
            }
            throw ProfileRefreshError.unavailable("设备验证失败（\(arguments.prefix(3).joined(separator: " "))），请保持设备解锁后重试：\(result.output)")
        }
        return try Data(contentsOf: url)
    }
}
