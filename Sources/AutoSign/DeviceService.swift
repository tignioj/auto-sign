import Foundation

enum DeviceService {
    static func connectedDevices() async throws -> [AppleDevice] {
        let devices = try await listedDevices()

        // `devicectl list devices` is a passive snapshot. A paired Wi-Fi device can be
        // reachable even while its on-demand developer tunnel is idle, in which case
        // the snapshot reports `tunnelState: disconnected`. Probe those devices so
        // "connected" means that CoreDevice could actually reach them during refresh.
        return await withTaskGroup(of: AppleDevice.self, returning: [AppleDevice].self) { group in
            for device in devices {
                group.addTask {
                    guard device.isPaired, !device.isConnected else { return device }
                    return await probeConnection(to: device) ?? device
                }
            }

            var probedDevices: [AppleDevice] = []
            for await device in group {
                probedDevices.append(device)
            }
            return sorted(probedDevices)
        }
    }

    private static func listedDevices() async throws -> [AppleDevice] {
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

    static func probeConnection(to device: AppleDevice) async -> AppleDevice? {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosign-device-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        guard let result = try? await ProcessRunner.run(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "info", "details",
                "--device", device.id,
                "--timeout", "15",
                "--json-output", jsonURL.path,
                "--quiet"
            ]
        ), result.status == 0,
              let data = try? Data(contentsOf: jsonURL),
              let probedDevice = try? parseDeviceDetails(from: data),
              probedDevice.udid == device.udid,
              probedDevice.isConnected else {
            return nil
        }
        return probedDevice
    }

    static func parseDevices(from data: Data) throws -> [AppleDevice] {
        let root = try JSONDecoder().decode(DeviceListResponse.self, from: data)
        return sorted(root.result.devices.compactMap(makeDevice(from:)))
    }

    static func parseDeviceDetails(from data: Data) throws -> AppleDevice? {
        let root = try JSONDecoder().decode(DeviceDetailsResponse.self, from: data)
        return makeDevice(from: root.result)
    }

    private static func makeDevice(from item: DeviceItem) -> AppleDevice? {
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

    private static func sorted(_ devices: [AppleDevice]) -> [AppleDevice] {
        devices.sorted { lhs, rhs in
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

private struct DeviceDetailsResponse: Decodable {
    let result: DeviceItem
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
