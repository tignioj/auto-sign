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

@Test func verifiesCachedConnectedDevicesAndKeepsFailedProbesOffline() async throws {
    let cached = try #require(DeviceService.parseDevices(from: discoveryList([discoveryDevice()])).first)
    var idle = cached
    idle.isConnected = false
    let result = await DeviceService.verifiedDevices([cached, idle]) { _ in nil }
    #expect(result.count == 2)
    #expect(result.allSatisfy { !$0.isConnected })
    #expect(result.allSatisfy { !$0.isReadyForInstallation })
}

@Test func verifiedDiscoveryNeverReplacesTheTargetWithAnotherDevice() async throws {
    let device = try #require(DeviceService.parseDevices(from: discoveryList([discoveryDevice()])).first)
    let other = try #require(DeviceService.parseDevices(from: discoveryList([discoveryDevice(index: 1)])).first)
    let result = await DeviceService.verifiedDevices([device]) { _ in other }
    #expect(result.first?.udid == device.udid)
    #expect(result.first?.isConnected == false)
}

@Test(arguments: [true, false])
func liveResponseProvesReachabilityDespiteCachedDisconnectedDetails(locked: Bool) async throws {
    let item = discoveryDevice()
    let device = try #require(DeviceService.parseDevices(from: discoveryList([item])).first)
    var cached = item
    var properties = try #require(cached["properties"] as? [String: Any])
    properties["connection"] = ["pairingState": "paired", "state": "disconnected"]
    cached["properties"] = properties
    let replies = ProbeReplies(live: try JSONSerialization.data(withJSONObject: ["result": [
        "deviceIdentifier": device.id, "passcodeRequired": locked
    ]]), details: try JSONSerialization.data(withJSONObject: ["result": cached]))
    let result = await DeviceService.probeConnection(to: device, query: { try await replies.query($0) })
    let verified = try #require(result)
    #expect(verified.udid == device.udid && verified.isReadyForInstallation)
    let calls = await replies.arguments
    #expect(calls.map { $0[2] } == ["lockState", "details"])
    #expect(calls.allSatisfy { $0.contains(device.udid) && !$0.contains(device.id) })
}

@Test func failedLiveProbeNeverAcceptsCachedConnectionState() async throws {
    let item = discoveryDevice()
    let device = try #require(DeviceService.parseDevices(from: discoveryList([item])).first)
    let replies = ProbeReplies(live: Data(#"{"info":{"outcome":"failed"},"result":{}}"#.utf8),
                               details: try JSONSerialization.data(withJSONObject: ["result": item]))
    let result = await DeviceService.probeConnection(to: device, query: { try await replies.query($0) })
    #expect(result == nil)
    #expect(await replies.arguments.count == 1)
}

@Test func liveProbeRejectsAReplyFromAnotherCoreDevice() async throws {
    let item = discoveryDevice()
    let device = try #require(DeviceService.parseDevices(from: discoveryList([item])).first)
    let replies = ProbeReplies(live: Data(#"{"result":{"deviceIdentifier":"another-device","passcodeRequired":true}}"#.utf8),
                               details: try JSONSerialization.data(withJSONObject: ["result": item]))
    #expect(await DeviceService.probeConnection(to: device, query: { try await replies.query($0) }) == nil)
}

private actor ProbeReplies {
    let live: Data
    let details: Data
    var arguments: [[String]] = []
    init(live: Data, details: Data) { self.live = live; self.details = details }
    func query(_ arguments: [String]) -> Data {
        self.arguments.append(arguments)
        return arguments[2] == "lockState" ? live : details
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
