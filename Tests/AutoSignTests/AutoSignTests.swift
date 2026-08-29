import Foundation
import Testing
@testable import AutoSign

@Test func parsesDeviceList() throws {
    let json = #"{"result":{"devices":[{"identifier":"core-id","deviceProperties":{"name":"测试 iPad","osVersionNumber":"26.0","developerModeStatus":"enabled"},"hardwareProperties":{"deviceType":"iPad","marketingName":"iPad mini","platform":"iOS","productType":"iPad16,1","reality":"physical","udid":"device-udid"},"connectionProperties":{"tunnelState":"connected"}}]}}"#
    let devices = try DeviceService.parseDevices(from: Data(json.utf8))
    #expect(devices.count == 1)
    #expect(devices[0].kind == .iPad)
    #expect(devices[0].developerModeEnabled)
    #expect(devices[0].udid == "device-udid")
}

@Test func matchesProvisioningApplicationIdentifiers() {
    #expect(SigningService.profileSupports("TEAM123.*", bundleID: "com.example.app"))
    #expect(SigningService.profileSupports("TEAM123.com.example.*", bundleID: "com.example.app"))
    #expect(SigningService.profileSupports("TEAM123.com.example.app", bundleID: "com.example.app"))
    #expect(!SigningService.profileSupports("TEAM123.com.other.app", bundleID: "com.example.app"))
    #expect(SigningService.explicitBundleIdentifier(from: "TEAM123.example.autosign.demo") == "example.autosign.demo")
    #expect(SigningService.explicitBundleIdentifier(from: "TEAM123.*") == nil)
}

@Test func integrationSignAndInstallWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let ipaPath = environment["AUTOSIGN_INTEGRATION_IPA"],
          let profilePath = environment["AUTOSIGN_INTEGRATION_PROFILE"] else { return }
    let devices = try await DeviceService.connectedDevices()
    let identities = try await SigningService.identities()
    guard let device = devices.first(where: { $0.isConnected && $0.developerModeEnabled }),
          let identity = identities.first else {
        Issue.record("Integration signing requires one connected Developer Mode device and one signing identity")
        return
    }
    let sourceProfile = URL(fileURLWithPath: profilePath)
    let activeProfile: URL
    if environment["AUTOSIGN_INTEGRATION_RENEW"] == "1" {
        activeProfile = try await SigningService.ensureUsableProfile(
            at: sourceProfile, for: device, forceRefresh: true
        ) { _ in }
    } else {
        activeProfile = sourceProfile
    }
    let output = try await SigningService.signAndInstall(
        ipa: URL(fileURLWithPath: ipaPath),
        profileURL: activeProfile,
        identity: identity,
        device: device
    ) { _, _ in }
    #expect(FileManager.default.fileExists(atPath: output.path))
}
