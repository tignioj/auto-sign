import Foundation

/// Recover known transport failures, never authentication or profile failures.
enum DeviceConnectionRetry {
    static func isTransient(_ message: String) -> Bool {
        let text = message.lowercased()
        guard !["device is locked", "device locked", "devicelocked", "passwordprotected", "passcode required",
                "pairing verification failed", "invalidhostid", "user denied pairing"]
            .contains(where: text.contains) else { return false }
        return ["kamdmuxconnecterror", "kamdnotconnectederror", "kamdconnectionfailederror",
                "failed to allocate rsd device", "device disconnected immediately after connecting",
                "connection reset by peer", "connection refused", "broken pipe",
                "coredevice 连接失败", "coredevice 连接中断或读取超时", "coredevice 连接中断或写入超时",
                "coredevice 发现连接被重置", "未找到此设备已配对的 coredevice 描述文件通道"]
            .contains(where: text.contains)
    }

    static func run<T>(operation: () async throws -> T,
                       beforeRetry: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            do { return try await operation() }
            catch {
                guard attempt < 3, case ProfileRefreshError.unavailable(let message) = error,
                      isTransient(message) else { throw error }
                try Task.checkCancellation()
                try await beforeRetry()
            }
        }
    }

    static func reconnect(to device: AppleDevice) async throws {
        try await Task.sleep(for: .seconds(2))
        try Task.checkCancellation()
        // Wake the on-demand tunnel. The next command still targets the original
        // UDID, even if the probe is temporarily unavailable.
        _ = await DeviceService.probeConnection(to: device)
        try Task.checkCancellation()
    }
}
