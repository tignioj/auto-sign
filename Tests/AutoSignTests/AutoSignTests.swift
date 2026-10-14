import Foundation
import Testing
@testable import AutoSign

@Test func parsesDeviceList() throws {
    let json = #"{"result":{"devices":[{"identifier":"core-id","deviceProperties":{"name":"测试 iPad","osVersionNumber":"26.0","developerModeStatus":"enabled"},"hardwareProperties":{"deviceType":"iPad","marketingName":"iPad mini","platform":"iOS","productType":"iPad16,1","reality":"physical","udid":"device-udid"},"connectionProperties":{"pairingState":"paired","tunnelState":"connected"}}]}}"#
    let devices = try DeviceService.parseDevices(from: Data(json.utf8))
    #expect(devices.count == 1)
    #expect(devices[0].kind == .iPad)
    #expect(devices[0].isPaired)
    #expect(devices[0].developerModeEnabled)
    #expect(devices[0].isReadyForInstallation)
    #expect(devices[0].udid == "device-udid")
}

@Test func parsesUnpairedDevice() throws {
    let json = #"{"result":{"devices":[{"identifier":"core-id","deviceProperties":{"name":"测试 iPhone","osVersionNumber":"26.6"},"hardwareProperties":{"deviceType":"iPhone","platform":"iOS","reality":"physical","udid":"device-udid"},"connectionProperties":{"pairingState":"unpaired","transportType":"wired","tunnelState":"disconnected"}}]}}"#
    let device = try #require(DeviceService.parseDevices(from: Data(json.utf8)).first)
    #expect(!device.isPaired)
    #expect(!device.isConnected)
    #expect(device.statusText == "需与这台 Mac 配对")
}

@Test func activeProbeRecognizesReachableWiFiDevice() throws {
    let passiveList = #"{"result":{"devices":[{"identifier":"core-id","deviceProperties":{"name":"Wi-Fi iPhone","osVersionNumber":"26.6","developerModeStatus":"enabled"},"hardwareProperties":{"deviceType":"iPhone","marketingName":"iPhone","platform":"iOS","reality":"physical","udid":"device-udid"},"connectionProperties":{"pairingState":"paired","transportType":"localNetwork","tunnelState":"disconnected"}}]}}"#
    let listedDevice = try #require(DeviceService.parseDevices(from: Data(passiveList.utf8)).first)
    #expect(listedDevice.isPaired)
    #expect(!listedDevice.isConnected)

    let activeDetails = #"{"result":{"identifier":"core-id","deviceProperties":{"name":"Wi-Fi iPhone","osVersionNumber":"26.6","developerModeStatus":"enabled"},"hardwareProperties":{"deviceType":"iPhone","marketingName":"iPhone","platform":"iOS","reality":"physical","udid":"device-udid"},"connectionProperties":{"pairingState":"paired","transportType":"localNetwork","tunnelState":"connected"}}}"#
    let probedDevice = try #require(try DeviceService.parseDeviceDetails(from: Data(activeDetails.utf8)))
    #expect(probedDevice.isConnected)
    #expect(probedDevice.isReadyForInstallation)
}

@Test func matchesProvisioningApplicationIdentifiers() {
    #expect(SigningService.profileSupports("TEAM123.*", bundleID: "com.example.app"))
    #expect(SigningService.profileSupports("TEAM123.com.example.*", bundleID: "com.example.app"))
    #expect(SigningService.profileSupports("TEAM123.com.example.app", bundleID: "com.example.app"))
    #expect(!SigningService.profileSupports("TEAM123.com.other.app", bundleID: "com.example.app"))
    #expect(SigningService.explicitBundleIdentifier(from: "TEAM123.example.autosign.demo") == "example.autosign.demo")
    #expect(SigningService.explicitBundleIdentifier(from: "TEAM123.*") == nil)
}

@Test func refreshesProfileWhenTargetDeviceIsMissing() {
    let validProfile = ProvisioningProfile(
        name: "Test Profile",
        uuid: "profile-uuid",
        expirationDate: Date().addingTimeInterval(3_600),
        applicationIdentifier: "TEAM123.com.example.app",
        teamIdentifier: "TEAM123",
        provisionedDevices: ["old-device"],
        provisionsAllDevices: false,
        entitlements: [:]
    )

    #expect(SigningService.profileNeedsRefresh(validProfile, for: "new-device", forceRefresh: false))
    #expect(!SigningService.profileNeedsRefresh(validProfile, for: "old-device", forceRefresh: false))

    let allDevicesProfile = ProvisioningProfile(
        name: "Enterprise Profile",
        uuid: "enterprise-profile-uuid",
        expirationDate: Date().addingTimeInterval(3_600),
        applicationIdentifier: "TEAM123.com.example.app",
        teamIdentifier: "TEAM123",
        provisionedDevices: [],
        provisionsAllDevices: true,
        entitlements: [:]
    )
    #expect(!SigningService.profileNeedsRefresh(allDevicesProfile, for: "new-device", forceRefresh: false))
}

@Test func migratesLegacyDeviceSelectionAndTracksNewPendingDevices() throws {
    let suiteName = "AutoSignTests.DeviceSelection.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }

    preferences.set("iphone-udid", forKey: DeviceSelectionStore.legacyDeviceUDIDKey)
    #expect(DeviceSelectionStore.load(from: preferences) == ["iphone-udid"])

    DeviceSelectionStore.save(["iphone-udid", "ipad-udid", "ipad-udid"], to: preferences)
    #expect(DeviceSelectionStore.load(from: preferences) == ["iphone-udid", "ipad-udid"])
    #expect(DeviceSelectionStore.loadPending(from: preferences) == ["ipad-udid"])
    #expect(preferences.string(forKey: DeviceSelectionStore.legacyDeviceUDIDKey) == "iphone-udid")
}

@Test func removingDeviceSelectionAlsoRemovesItsPendingRetry() throws {
    let suiteName = "AutoSignTests.PendingSelection.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }

    DeviceSelectionStore.save(["iphone-udid", "ipad-udid"], to: preferences)
    #expect(Set(DeviceSelectionStore.loadPending(from: preferences)) == ["iphone-udid", "ipad-udid"])

    DeviceSelectionStore.savePending(["ipad-udid"], to: preferences)
    DeviceSelectionStore.save(["iphone-udid"], to: preferences)
    #expect(DeviceSelectionStore.load(from: preferences) == ["iphone-udid"])
    #expect(DeviceSelectionStore.loadPending(from: preferences).isEmpty)
}

@Test func integrationSignAndInstallWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let ipaPath = environment["AUTOSIGN_INTEGRATION_IPA"],
          let profilePath = environment["AUTOSIGN_INTEGRATION_PROFILE"] else { return }
    let devices = try await DeviceService.connectedDevices()
    let identities = try await SigningService.identities()
    let requestedUDID = environment["AUTOSIGN_INTEGRATION_DEVICE"]
    guard let device = devices.first(where: { $0.isConnected && $0.developerModeEnabled && (requestedUDID == nil || $0.udid == requestedUDID) }),
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

@Test func deviceFailurePreservesInstalledExpiryAndSuccessClearsFailure() throws {
    let suite = "AutoSignTests.Status.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let expiry = Date().addingTimeInterval(100_000)
    RefreshStatusStore.record("one", name: "iPhone", state: "成功", expiration: expiry, success: true, preferences: preferences)
    RefreshStatusStore.record("two", name: "iPad", state: "等待连接", failure: "离线", preferences: preferences)
    RefreshStatusStore.record("one", state: "失败", failure: "No Accounts", preferences: preferences)
    let failed = try #require(RefreshStatusStore.load("one", preferences: preferences))
    #expect(failed.expiration == expiry)
    #expect(failed.lastSuccess != nil)
    #expect(failed.failure == "No Accounts")
    #expect(RefreshStatusStore.load("two", preferences: preferences)?.failure == "离线")
    RefreshStatusStore.record("one", state: "成功", expiration: expiry, success: true, preferences: preferences)
    #expect(RefreshStatusStore.load("one", preferences: preferences)?.failure == nil)
}

@Test func scheduleDistinguishesDisabledOverdueAndRenewalWindow() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let check = now.addingTimeInterval(1_800)
    let status = RefreshStatus(id: "one", name: "iPhone", expiration: now.addingTimeInterval(7 * 86_400))
    #expect(status.nextAttempt(check: check, enabled: false, now: now) == "自动续签已关闭")
    #expect(status.nextAttempt(check: nil, enabled: true, now: now) == "等待首次后台检查")
    #expect(status.nextAttempt(check: now.addingTimeInterval(-1), enabled: true, now: now).contains("检查时间已到"))
    #expect(status.nextAttempt(check: check, enabled: true, now: now).contains(now.addingTimeInterval(6 * 86_400).formatted(date: .abbreviated, time: .shortened)))
    #expect(RefreshStatusStore.failureSummary("error: No Accounts: Add a new account").contains("Xcode 未读取到可用账号"))
}

@Test func devicePreparationRetriesOnceAndCanRecover() async throws {
    var attempts = 0
    var waits = 0
    try await DevicePreparationRetry.run {
        attempts += 1
        if attempts == 1 {
            throw AutoSignError.command("The developer disk image could not be mounted on this device.")
        }
    } beforeRetry: { waits += 1 }
    #expect(attempts == 2)
    #expect(waits == 1)
}

@Test func devicePreparationStopsAfterSecondFailureAndKeepsDetails() async {
    var attempts = 0
    do {
        try await DevicePreparationRetry.run {
            attempts += 1
            throw AutoSignError.command("Timed out waiting for all destinations matching the provided destination specifier to become available")
        } beforeRetry: {}
        Issue.record("Expected retry failure")
    } catch {
        #expect(error.localizedDescription.contains("已自动重试 1 次"))
        #expect(error.localizedDescription.contains("Timed out waiting"))
    }
    #expect(attempts == 2)
}

@Test func devicePreparationDoesNotRetryAccountOrSigningErrors() async {
    for message in ["No Accounts", "No signing certificate found", "Provisioning profile is invalid"] {
        var attempts = 0
        var waits = 0
        do {
            try await DevicePreparationRetry.run {
                attempts += 1
                throw AutoSignError.command(message)
            } beforeRetry: { waits += 1 }
            Issue.record("Expected original failure")
        } catch {
            #expect(error.localizedDescription == message)
        }
        #expect(attempts == 1)
        #expect(waits == 0)
    }
}

@Test func devicePreparationCancellationDuringWaitPreventsRetry() async {
    var attempts = 0
    do {
        try await DevicePreparationRetry.run {
            attempts += 1
            throw AutoSignError.command("The developer disk image could not be mounted")
        } beforeRetry: { throw CancellationError() }
        Issue.record("Expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(attempts == 1)
}
