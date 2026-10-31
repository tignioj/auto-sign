import AutoSignLocalization
import Foundation

enum DeviceService {
    static func connectedDevices(excluding removedUDIDs: Set<String> = DeviceRemovalStore.removedUDIDs()) async throws -> [AppleDevice] {
        let devices = try await listedDevices().filter { !removedUDIDs.contains($0.udid) }
        return await verifiedDevices(devices)
    }

    static func verifiedDevices(_ devices: [AppleDevice],
                                probe: @escaping @Sendable (AppleDevice) async -> AppleDevice? = {
                                    await probeConnection(to: $0)
                                }) async -> [AppleDevice] {
        // Both list and details may return stale CoreDevice state. Verify all
        // paired devices, including ones cached as connected, with a live RPC.
        return await withTaskGroup(of: AppleDevice.self, returning: [AppleDevice].self) { group in
            for device in devices {
                group.addTask {
                    guard device.isPaired else { return device }
                    if let verified = await probe(device), verified.udid == device.udid {
                        return verified
                    }
                    var offline = device
                    offline.isConnected = false
                    return offline
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
            ["devicectl", "list", "devices", "--timeout", "30", "--json-output", jsonURL.path, "--quiet"],
            context: L10n.tr("无法读取设备。请确认已安装 Xcode。")
        )
        return try parseDevices(from: Data(contentsOf: jsonURL))
    }

    static func probeConnection(to device: AppleDevice,
                                query: @Sendable ([String]) async throws -> Data = {
                                    try await deviceQuery($0)
                                }) async -> AppleDevice? {
        // Unlike details, lockState requires a response from the actual device.
        // It works while passcode-locked and neither unlocks nor launches apps.
        guard let liveData = try? await query([
            "device", "info", "lockState", "--device", device.udid, "--timeout", "30"
        ]), let live = try? JSONDecoder().decode(DeviceLockStateResponse.self, from: liveData),
              let details = try? await query([
                "device", "info", "details", "--device", device.udid, "--timeout", "30"
              ]), var verified = try? parseDeviceDetails(from: details),
              verified.udid == device.udid, verified.isPaired,
              live.result.deviceIdentifier == verified.id else { return nil }
        verified.isConnected = true
        return verified
    }

    private static func deviceQuery(_ arguments: [String]) async throws -> Data {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosign-device-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        _ = try await ProcessRunner.checked("/usr/bin/xcrun",
            ["devicectl"] + arguments + ["--json-output", jsonURL.path, "--quiet"],
            context: L10n.tr("无法读取设备。请确认已安装 Xcode。"))
        return try Data(contentsOf: jsonURL)
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
        // Xcode 27.2 moves device data into `properties`. Prefer those fields,
        // falling back individually while older Xcode versions remain supported.
        let hardware = item.properties?.hardware
        let legacyHardware = item.hardwareProperties
        let platform = hardware?.platform ?? legacyHardware?.platform
        let reality = hardware?.reality ?? legacyHardware?.reality
        guard platform == "iOS",
              let deviceType = hardware?.deviceType ?? legacyHardware?.deviceType,
              let type = DeviceKind(rawValue: deviceType),
              let identifier = item.identifier, !identifier.isEmpty,
              let udid = hardware?.udid ?? legacyHardware?.udid, !udid.isEmpty else { return nil }

        // Idle paired devices can lack `reality` until their tunnel is opened.
        // Physical UDIDs use these two formats; simulator UDIDs are UUIDs.
        guard reality == "physical" || (reality == nil && udid.range(
            of: "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$",
            options: .regularExpression
        ) != nil) else { return nil }

        let marketingName = hardware?.marketingName ?? legacyHardware?.marketingName
            ?? hardware?.productType ?? legacyHardware?.productType ?? type.rawValue
        let state = item.properties?.state
        let connection = item.properties?.connection
        let isConnected = (connection?.state ?? item.connectionProperties?.tunnelState) == "connected"
        return AppleDevice(
            id: identifier,
            udid: udid,
            name: state?.name ?? item.deviceProperties?.name ?? marketingName,
            marketingName: marketingName,
            kind: type,
            osVersion: item.properties?.software?.osVersionNumber?.stringValue
                ?? item.deviceProperties?.osVersionNumber ?? L10n.tr("未知版本"),
            isPaired: (connection?.pairingState ?? item.connectionProperties?.pairingState) == "paired"
                || isConnected,
            developerModeEnabled: state?.developerModeStatus?.isEnabled
                ?? (item.deviceProperties?.developerModeStatus == "enabled"),
            isConnected: isConnected
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
            context: L10n.tr("无法与设备配对。请保持设备解锁并通过 USB 连接，然后在设备上确认信任。")
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

private struct DeviceLockStateResponse: Decodable {
    let result: ResultBody
    struct ResultBody: Decodable {
        let deviceIdentifier: String
        let passcodeRequired: Bool
    }
}

private struct DeviceItem: Decodable {
    let identifier: String?
    let properties: Properties?
    let deviceProperties: DeviceProperties?
    let hardwareProperties: HardwareProperties?
    let connectionProperties: ConnectionProperties?

    struct Properties: Decodable {
        let hardware: HardwareProperties?
        let connection: ConnectionProperties?
        let state: StateProperties?
        let software: SoftwareProperties?
    }

    struct StateProperties: Decodable {
        let name: String?
        let developerModeStatus: DeveloperModeStatus?
    }

    struct SoftwareProperties: Decodable {
        let osVersionNumber: VersionNumber?

        struct VersionNumber: Decodable { let stringValue: String }
    }

    struct DeveloperModeStatus: Decodable {
        let isEnabled: Bool

        private enum CodingKeys: String, CodingKey { case enabled }

        init(from decoder: Decoder) throws {
            if let status = try? decoder.singleValueContainer().decode(String.self) {
                isEnabled = status == "enabled"
            } else {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled = try container.contains(.enabled) && !container.decodeNil(forKey: .enabled)
            }
        }
    }

    struct DeviceProperties: Decodable {
        let name: String?
        let osVersionNumber: String?
        let developerModeStatus: String?
    }

    struct HardwareProperties: Decodable {
        let deviceType: String?
        let marketingName: String?
        let platform: String?
        let productType: String?
        let reality: String?
        let udid: String?
    }

    struct ConnectionProperties: Decodable {
        let pairingState: String?
        let state: String?
        let tunnelState: String?
    }
}
