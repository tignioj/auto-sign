import Foundation

enum DeviceService {
    static func connectedDevices() async throws -> [AppleDevice] {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosign-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        _ = try await ProcessRunner.checked(
            "/usr/bin/xcrun",
            ["devicectl", "list", "devices", "--json-output", jsonURL.path, "--quiet"],
            context: "无法读取设备。请确认已安装 Xcode。"
        )
        return try parseDevices(from: Data(contentsOf: jsonURL))
    }

    static func parseDevices(from data: Data) throws -> [AppleDevice] {
        let root = try JSONDecoder().decode(DeviceListResponse.self, from: data)
        return root.result.devices.compactMap { item in
            guard item.hardwareProperties.platform == "iOS",
                  item.hardwareProperties.reality == "physical",
                  let type = DeviceKind(rawValue: item.hardwareProperties.deviceType),
                  let udid = item.hardwareProperties.udid else { return nil }
            return AppleDevice(
                id: item.identifier,
                udid: udid,
                name: item.deviceProperties.name,
                marketingName: item.hardwareProperties.marketingName ?? item.hardwareProperties.productType ?? type.rawValue,
                kind: type,
                osVersion: item.deviceProperties.osVersionNumber ?? "未知版本",
                isPaired: item.connectionProperties.pairingState == "paired"
                    || item.connectionProperties.tunnelState == "connected",
                developerModeEnabled: item.deviceProperties.developerModeStatus == "enabled",
                isConnected: item.connectionProperties.tunnelState == "connected"
            )
        }
        .sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func pair(_ device: AppleDevice) async throws {
        _ = try await ProcessRunner.checked(
            "/usr/bin/xcrun",
            ["devicectl", "manage", "pair", "--device", device.id, "--timeout", "120"],
            context: "无法与设备配对。请保持设备解锁并通过 USB 连接，然后在设备上确认信任。"
        )
    }
}

private struct DeviceListResponse: Decodable {
    let result: ResultBody

    struct ResultBody: Decodable { let devices: [DeviceItem] }
}

private struct DeviceItem: Decodable {
    let identifier: String
    let deviceProperties: DeviceProperties
    let hardwareProperties: HardwareProperties
    let connectionProperties: ConnectionProperties

    struct DeviceProperties: Decodable {
        let name: String
        let osVersionNumber: String?
        let developerModeStatus: String?
    }

    struct HardwareProperties: Decodable {
        let deviceType: String
        let marketingName: String?
        let platform: String
        let productType: String?
        let reality: String?
        let udid: String?
    }

    struct ConnectionProperties: Decodable {
        let pairingState: String?
        let tunnelState: String?
    }
}
