import Foundation
import Testing
@testable import AutoSign

@Test func parsesXcode27PropertiesForUpdatedDevices() throws {
    let models: [(String, String, DeviceKind)] = [
        ("iPadmini7", "iPad16,1", .iPad),
        ("iPhone18pm", "iPhone19,7", .iPhone),
        ("iPadpro11M5", "iPad17,1", .iPad),
        ("iPadpro13M5", "iPad17,3", .iPad)
    ]
    let items = models.enumerated().map { index, model in
        discoveryDevice(name: model.0, productType: model.1, kind: model.2, index: index)
    }
    let devices = try DeviceService.parseDevices(from: discoveryList(items))
    #expect(devices.count == 4)
    for (name, productType, kind) in models {
        let device = try #require(devices.first { $0.name == name })
        #expect(device.kind == kind)
        #expect(device.marketingName == productType)
        #expect(device.osVersion == "27.2")
        #expect(device.isReadyForInstallation)
    }
}

@Test(arguments: ["iPad16,1", "iPhone19,7", "iPad17,1", "iPad17,3"])
func discoversIdlePhysicalDevicesWithoutReality(productType: String) throws {
    // This is the sparse legacy snapshot Xcode 27.2 returns before opening a
    // paired device's on-demand tunnel. It must reach the active probe.
    let item: [String: Any] = [
        "identifier": "idle-device",
        "deviceProperties": ["name": productType, "osVersionNumber": "27.2"],
        "hardwareProperties": [
            "deviceType": productType.hasPrefix("iPad") ? "iPad" : "iPhone",
            "platform": "iOS", "productType": productType,
            "udid": "00008142-0000000000000001"
        ],
        "connectionProperties": ["pairingState": "paired", "tunnelState": "disconnected"]
    ]
    let device = try #require(DeviceService.parseDevices(from: discoveryList([item])).first)
    #expect(device.isPaired)
    #expect(!device.isConnected)
    #expect(!device.isReadyForInstallation)
}

@Test func discoversIdleDeviceInNewSchemaAndParsesActiveDetails() throws {
    var item = discoveryDevice()
    var properties = try #require(item["properties"] as? [String: Any])
    var hardware = try #require(properties["hardware"] as? [String: Any])
    hardware.removeValue(forKey: "reality")
    properties["hardware"] = hardware
    properties["connection"] = ["pairingState": "paired", "state": "disconnected"]
    properties["state"] = ["name": "idle iPad"]
    item["properties"] = properties
    let idle = try #require(DeviceService.parseDevices(from: discoveryList([item])).first)
    #expect(idle.isPaired && !idle.isConnected && !idle.developerModeEnabled)

    let data = try JSONSerialization.data(withJSONObject: ["result": discoveryDevice()])
    let active = try #require(try DeviceService.parseDeviceDetails(from: data))
    #expect(active.udid == idle.udid)
    #expect(active.isReadyForInstallation)
}

@Test func newPropertiesOverrideDeprecatedFieldsAndFallbackIndividually() throws {
    var item = discoveryDevice()
    item["hardwareProperties"] = ["marketingName": "iPad Pro 11-inch (M5)"]
    item["deviceProperties"] = ["name": "old name", "osVersionNumber": "26.5", "developerModeStatus": "enabled"]
    item["connectionProperties"] = ["pairingState": "paired", "tunnelState": "connected"]
    var properties = try #require(item["properties"] as? [String: Any])
    properties["state"] = ["name": "current name", "developerModeStatus": ["disabled": [:]]]
    properties["connection"] = ["pairingState": "unpaired", "state": "disconnected"]
    item["properties"] = properties
    let device = try #require(DeviceService.parseDevices(from: discoveryList([item])).first)
    #expect(device.name == "current name")
    #expect(device.marketingName == "iPad Pro 11-inch (M5)")
    #expect(device.osVersion == "27.2")
    #expect(!device.isPaired && !device.isConnected && !device.developerModeEnabled)
}

@Test func incompleteAndSimulatorEntriesDoNotHidePhysicalDevices() throws {
    var simulator = discoveryDevice()
    var properties = try #require(simulator["properties"] as? [String: Any])
    var hardware = try #require(properties["hardware"] as? [String: Any])
    hardware["reality"] = "simulated"
    properties["hardware"] = hardware
    simulator["properties"] = properties

    var simulatorWithoutReality = simulator
    hardware.removeValue(forKey: "reality")
    hardware["udid"] = "E86C2E12-8A81-4680-AF0C-08A41DB0D586"
    properties["hardware"] = hardware
    simulatorWithoutReality["properties"] = properties

    let devices = try DeviceService.parseDevices(from: discoveryList([
        ["identifier": "incomplete", "properties": ["hardware": [:]]],
        ["identifier": "null-legacy", "hardwareProperties": NSNull()],
        [:], simulator, simulatorWithoutReality, discoveryDevice()
    ]))
    #expect(devices.count == 1)
    #expect(devices.first?.isReadyForInstallation == true)
}

@Test func recognizesLegacyPhysicalUDIDWithoutReality() throws {
    let json = #"{"result":{"devices":[{"identifier":"legacy","deviceProperties":{"name":"iPhone"},"hardwareProperties":{"deviceType":"iPhone","platform":"iOS","udid":"0123456789abcdef0123456789abcdef01234567"},"connectionProperties":{"pairingState":"paired"}}]}}"#
    let devices = try DeviceService.parseDevices(from: Data(json.utf8))
    #expect(devices.count == 1)
    #expect(devices.first?.isConnected == false)
}

@Test func integrationDiscoversDevicesWhenConfigured() async throws {
    guard let expected = ProcessInfo.processInfo.environment["AUTOSIGN_DISCOVERY_EXPECTED_UDIDS"] else { return }
    let devices = try await DeviceService.connectedDevices(excluding: [])
    for udid in expected.split(separator: ",").map(String.init) {
        let device = try #require(devices.first { $0.udid == udid })
        print("Device discovery: \(device.name), \(device.osVersion), connected=\(device.isConnected), developerMode=\(device.developerModeEnabled)")
        #expect(device.isReadyForInstallation)
    }
}

private func discoveryList(_ devices: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["info": ["jsonVersion": 5], "result": ["devices": devices]])
}

private func discoveryDevice(name: String = "iPad", productType: String = "iPad17,1",
                             kind: DeviceKind = .iPad, index: Int = 0) -> [String: Any] {
    [
        "identifier": "core-device-\(index)",
        "properties": [
            "hardware": [
                "deviceType": kind.rawValue, "platform": "iOS", "reality": "physical",
                "productType": productType, "udid": String(format: "00008142-%016d", index)
            ],
            "state": ["name": name, "developerModeStatus": ["enabled": ["mode": 1]]],
            "software": ["osVersionNumber": ["stringValue": "27.2", "components": [27, 2, 0, 0, 0]]],
            "connection": ["pairingState": "paired", "state": "connected", "transportType": "localNetwork"]
        ]
    ]
}
