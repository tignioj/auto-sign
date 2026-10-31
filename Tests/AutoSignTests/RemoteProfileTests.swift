import Foundation
import Testing
@testable import AutoSign
@testable import AutoSignRemoteHelper

private func wireHex(_ text: String) -> Data {
    let compact = text.filter { !$0.isWhitespace }
    var bytes = Data(), index = compact.startIndex
    while index < compact.endIndex {
        let end = compact.index(index, offsetBy: 2)
        bytes.append(UInt8(compact[index..<end], radix: 16)!)
        index = end
    }
    return bytes
}

@Test func remoteXPCDecodesKnownWireValuesAndRejectsMalformedLengths() throws {
    // Captured protocol layout: dictionary count=1, Port=23 (uint64).
    let fixture = wireHex("00f00000 18000000 01000000 506f727400000000 00400000 1700000000000000")
    var reader = XPCWire.Reader(data: fixture)
    let dictionary = try #require(try reader.object() as? [String: Any])
    #expect((dictionary["Port"] as? NSNumber)?.intValue == 23)
    #expect(reader.offset == fixture.count)
    #expect(try XPCWire.encode("x") == wireHex("00900000 02000000 78000000"))
    for bad in [fixture.dropLast(), wireHex("00f00000 ffffffff 01000000"),
                wireHex("00f00000 04000000 ffffffff"), wireHex("00900000 02000000 ff000000")] {
        #expect(throws: RemoteFailure.self) { var input = XPCWire.Reader(data: Data(bad)); _ = try input.object() }
    }
}

@Test func remoteXPCRequiresValidWrapperAndPreservesHandshakeIdentity() throws {
    let id = UUID()
    let data = try XPCWire.message(["UUID": id, "Enabled": true, "Port": NSNumber(value: 123)], flags: 0x101, id: 1)
    let value = try #require(try XPCWire.decodeMessage(data))
    #expect((value["Enabled"] as? Bool) == true)
    #expect((value["Port"] as? NSNumber)?.intValue == 123)
    var bytes = id.uuid
    #expect(value["UUID"] as? Data == withUnsafeBytes(of: &bytes) { Data($0) })
    #expect(try XPCWire.decodeMessage(XPCWire.message(nil, flags: 0x201)) == nil)
    var wrongMagic = data; wrongMagic[0] = 0
    var wrongLength = data; wrongLength[8] = 0
    for bad in [wrongMagic, wrongLength, Data(data.dropLast()), data + Data([0])] {
        #expect(throws: RemoteFailure.self) { _ = try XPCWire.decodeMessage(bad) }
    }
}

@Test func remoteEndpointDiscoveryOnlyUsesRemotedAndTheExpectedIPv6Device() {
    let sample = """
    ,interface,state,
    remoted.366,,,
    tcp6 fd64::2.40000<->fd64::1.52982,utun14,Established,
    tcp6 fd64::2.40001<->fd65::1.52983,utun15,Established,
    tcp6 fd64::2.40002<->fd64::1.52984,utun14,CloseWait,
    tcp6 fd64::2.40003<->fd64::1.52982,utun14,Established,
    OtherApp.123,,,
    tcp6 fd64::2.40000<->fd64::1.9999,utun14,Established,
    remoted.fake,,,
    tcp6 fd64::2.40000<->fd64::1.9998,utun14,Established,
    """
    #expect(RemoteDeviceProfileService.parsePorts(sample, address: "fd64:0:0:0:0:0:0:1") == [52982])
    #expect(RemoteDeviceProfileService.parsePorts(sample, address: "fd66::1").isEmpty)
    #expect(RemoteDeviceProfileService.parsePorts(sample, address: "not-an-ip").isEmpty)
    let id = UUID()
    #expect(RemoteDeviceProfileService.parseHostID("Local device\n\tUUID: \(id.uuidString)\nRemote device\n\tUUID: \(UUID())") == id)
    #expect(RemoteDeviceProfileService.parseHostID("Remote device\n\tUUID: \(id)") == nil)
    #expect(RemoteDeviceProfileService.parseHostID("Local device\ninvalid\n\tUUID: \(id)") == nil)
}

@Test func remoteEndpointRejectsWrongUnpairedOfflineOrInvalidTunnelDetails() throws {
    func details(_ udid: String = "phone", paired: String = "paired", state: String = "connected", address: String = "fd64::1") -> Data {
        Data("""
        {"result":{"identifier":"core-id","deviceProperties":{"name":"Phone","developerModeStatus":"enabled"},"hardwareProperties":{"deviceType":"iPhone","platform":"iOS","reality":"physical","udid":"\(udid)"},"connectionProperties":{"pairingState":"\(paired)","tunnelState":"\(state)","tunnelIPAddress":"\(address)"}}}
        """.utf8)
    }
    #expect(try RemoteDeviceProfileService.tunnelAddress(from: details(), expectedUDID: "phone") == "fd64::1")
    for bad in [details("other"), details(paired: "unpaired"), details(paired: "unpaired", state: "disconnected"),
                details(state: "disconnected"), details(address: "localhost")] {
        #expect(throws: ProfileRefreshError.self) { _ = try RemoteDeviceProfileService.tunnelAddress(from: bad, expectedUDID: "phone") }
    }
}

@Test func pairedCachedTunnelSnapshotRecoversWithoutChangingTheTarget() async throws {
    let offline = Data(#"{"result":{"identifier":"core-id","deviceProperties":{"name":"iPad mini 7"},"hardwareProperties":{"deviceType":"iPad","platform":"iOS","udid":"00008130-0000000000000001"},"connectionProperties":{"pairingState":"paired","tunnelState":"unavailable"}}}"#.utf8)
    let connected = Data(#"{"result":{"identifier":"core-id","properties":{"hardware":{"deviceType":"iPad","platform":"iOS","reality":"physical","udid":"00008130-0000000000000001"},"state":{"name":"iPad mini 7","developerModeStatus":{"enabled":{"mode":1}}},"connection":{"pairingState":"paired","state":"connected","tunnelIPAddressString":"fd64::1"}}}}"#.utf8)
    var reads = 0
    var reconnects = 0
    let address = try await DeviceConnectionRetry.run(operation: {
        reads += 1
        return try RemoteDeviceProfileService.tunnelAddress(from: reads == 1 ? offline : connected,
            expectedUDID: "00008130-0000000000000001")
    }, beforeRetry: { reconnects += 1 })
    #expect(address == "fd64::1")
    #expect(reads == 2 && reconnects == 1)
}

@Test func transientTunnelRecoveryNeverRetriesIdentityPairingOrInvalidAddresses() async {
    let samples = [
        #"{"result":{"identifier":"core-id","deviceProperties":{"name":"Other"},"hardwareProperties":{"deviceType":"iPad","platform":"iOS","reality":"physical","udid":"other"},"connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"}}}"#,
        #"{"result":{"identifier":"core-id","deviceProperties":{"name":"Unpaired"},"hardwareProperties":{"deviceType":"iPad","platform":"iOS","reality":"physical","udid":"phone"},"connectionProperties":{"pairingState":"unpaired","tunnelState":"disconnected"}}}"#,
        #"{"result":{"identifier":"core-id","deviceProperties":{"name":"Invalid address","developerModeStatus":"enabled"},"hardwareProperties":{"deviceType":"iPad","platform":"iOS","reality":"physical","udid":"phone"},"connectionProperties":{"pairingState":"paired","tunnelState":"connected","tunnelIPAddress":"localhost"}}}"#
    ]
    for sample in samples {
        var reads = 0
        do {
            _ = try await DeviceConnectionRetry.run(operation: {
                reads += 1
                return try RemoteDeviceProfileService.tunnelAddress(from: Data(sample.utf8), expectedUDID: "phone")
            }, beforeRetry: { Issue.record("Must not retry an invalid identity, pairing, or address") })
            Issue.record("Expected invalid tunnel rejection")
        } catch { #expect(reads == 1) }
    }
}

@Test func strictProfileOnlyRefreshNeverCallsReplacement() async throws {
    for reason in [nil, "certificate changed"] as [String?] {
        for error in [ProfileRefreshError.unsupported("missing service"), .incompatible("changed profile")] {
            var replacement = false
            do {
                _ = try await AppRefreshService.perform(expiration: Date(), incompatibility: reason,
                    verification: .init(verifyLaunch: true), allowReinstall: false,
                    profileOnly: { throw error }, reinstall: { _ in replacement = true })
                Issue.record("Profile-only validation must stop on an incompatible transport")
            } catch { #expect(!replacement) }
        }
    }
}

@Test func profileOnlyPolicyPersistsForOnlyTheSelectedDevice() throws {
    let name = "AutoSignTests.ProfileOnly.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    #expect(!ProfileRefreshPolicy.profileOnly(on: "phone", preferences: preferences))
    ProfileRefreshPolicy.setProfileOnly(true, on: "phone", preferences: preferences)
    let reopened = try #require(UserDefaults(suiteName: name))
    #expect(ProfileRefreshPolicy.profileOnly(on: "phone", preferences: reopened))
    #expect(!ProfileRefreshPolicy.profileOnly(on: "tablet", preferences: reopened))
    ProfileRefreshPolicy.setProfileOnly(false, on: "phone", preferences: reopened)
    #expect(!ProfileRefreshPolicy.profileOnly(on: "phone", preferences: preferences))
}
