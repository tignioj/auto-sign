import Foundation
import Testing
@testable import AutoSign

@Test func launchVerificationPreferenceDefaultsOffAndPersists() throws {
    let suite = "AutoSignTests.RefreshVerification.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    #expect(!RefreshVerificationOptions.load(from: preferences).verifyLaunch)

    preferences.set(true, forKey: RefreshVerificationOptions.launchPreferenceKey)
    let reloaded = try #require(UserDefaults(suiteName: suite))
    #expect(RefreshVerificationOptions.load(from: reloaded).verifyLaunch)
    preferences.set(false, forKey: RefreshVerificationOptions.launchPreferenceKey)
    #expect(!RefreshVerificationOptions.load(from: reloaded).verifyLaunch)
}

@Test(arguments: [false, true], [false, true])
func renewalVerificationRespectsLaunchOption(verifyLaunch: Bool, reinstall: Bool) async throws {
    let verification = RefreshVerificationOptions(verifyLaunch: verifyLaunch)
    var events: [String] = []
    let verify = {
        try await verification.verify(profile: { events.append("profile-verified") },
                                      launch: { events.append("launch") })
    }
    let result = try await AppRefreshService.perform(expiration: Date(),
        incompatibility: reinstall ? "certificate changed" : nil, verification: verification, profileOnly: {
            events.append("profile-installed")
            try await verify()
        }, reinstall: { _ in
            events.append("reinstalled")
            try await verify()
        })
    #expect(result.method == (reinstall ? .reinstalled : .profileOnly))
    #expect(events == [reinstall ? "reinstalled" : "profile-installed", "profile-verified"] + (verifyLaunch ? ["launch"] : []))
    #expect(result.message.contains(verifyLaunch ? "启动验证通过" : "已跳过启动验证"))
    #expect(result.message.contains("启动验证通过") == verifyLaunch)
}

@Test(arguments: [false, true])
func skippingLaunchStillRejectsUnverifiedProfiles(verifyLaunch: Bool) async {
    var launched = false
    await #expect(throws: ProfileRefreshError.self) {
        try await RefreshVerificationOptions(verifyLaunch: verifyLaunch).verify(profile: {
            throw ProfileRefreshError.verification("profile mismatch")
        }, launch: { launched = true })
    }
    #expect(!launched)
}

@Test func enabledLaunchVerificationStillRejectsLaunchFailure() async {
    var profileVerified = false
    await #expect(throws: ProfileRefreshError.self) {
        try await RefreshVerificationOptions(verifyLaunch: true).verify(profile: {
            profileVerified = true
        }, launch: { throw ProfileRefreshError.verification("app exited") })
    }
    #expect(profileVerified)
}

private func refreshProfile(uuid: String, expiry: Date, certificate: String = "CERT",
                            entitlements: [String: AnySendable] = ["application-identifier": AnySendable(value: "TEAM.app.test")]) -> ProvisioningProfile {
    ProvisioningProfile(name: "Test", uuid: uuid, expirationDate: expiry, applicationIdentifier: "TEAM.app.test",
        teamIdentifier: "TEAM", provisionedDevices: ["phone"], provisionsAllDevices: false,
        entitlements: entitlements, signingCertificateHashes: [certificate])
}

private func refreshRecord(expiry: Date, extensions: [String] = [], entitlements: [String: Any] = ["application-identifier": "TEAM.app.test"]) throws -> StoreRecord {
    StoreRecord(app: StoreApp(id: "test", deviceUDID: "phone", name: "Test", bundleIdentifier: "app.test", version: "1",
        expiration: expiry, refreshedAt: Date(), isStore: false), ipaPath: "/unused.ipa", profilePath: "/unused.mobileprovision",
        identityID: "CERT", teamIdentifier: "TEAM",
        signedEntitlements: try PropertyListSerialization.data(fromPropertyList: entitlements, format: .binary, options: 0),
        extensionBundleIdentifiers: extensions)
}

@Test func renewalRejectsSameOrEarlierExpiryEvenWithNewUUID() throws {
    let now = Date()
    let record = try refreshRecord(expiry: now.addingTimeInterval(86_400))
    let old = refreshProfile(uuid: "old", expiry: record.app.expiration)
    for expiry in [record.app.expiration, now.addingTimeInterval(600)] {
        let new = refreshProfile(uuid: "new", expiry: expiry)
        #expect(throws: ProfileRefreshError.self) {
            try AppRefreshService.validate(record: record, original: old, renewed: new, deviceUDID: "phone")
        }
    }
    let new = refreshProfile(uuid: "new", expiry: now.addingTimeInterval(7 * 86_400))
    try AppRefreshService.validate(record: record, original: old, renewed: new, deviceUDID: "phone")
    #expect(throws: ProfileRefreshError.self) {
        try AppRefreshService.validate(record: record, original: old, renewed: new, deviceUDID: "other-phone")
    }
}

@Test func xcodeRenewalMustExtendExpiryForExistingApp() throws {
    let now = Date()
    let original = ProvisioningProfile(name: "old", uuid: "old", expirationDate: now.addingTimeInterval(8 * 86_400),
        applicationIdentifier: "TEAM.app.test", teamIdentifier: "TEAM", provisionedDevices: ["phone"],
        provisionsAllDevices: false, entitlements: [:], creationDate: now.addingTimeInterval(-3600))
    let new = ProvisioningProfile(name: "new", uuid: "new", expirationDate: now.addingTimeInterval(7 * 86_400),
        applicationIdentifier: "TEAM.app.test", teamIdentifier: "TEAM", provisionedDevices: ["phone"],
        provisionsAllDevices: false, entitlements: [:], creationDate: now)
    #expect(throws: AutoSignError.self) {
        try ProfileRenewalPolicy.validate(original: original, renewed: new, bundleID: "app.test", deviceUDID: "phone", requestedAt: now, now: now,
            requireExtendedExpiry: true)
    }
    // Installing/upgrading a version must not inherit the refresh-only constraint.
    try ProfileRenewalPolicy.validate(original: original, renewed: new, bundleID: "app.test", deviceUDID: "phone", requestedAt: now, now: now)
}

@Test func profileOnlyRequiresOriginalCertificatePermissionsAndNoUnmanagedExtensions() throws {
    let expiry = Date().addingTimeInterval(86_400)
    let record = try refreshRecord(expiry: expiry)
    let old = refreshProfile(uuid: "old", expiry: expiry)
    let fresh = refreshProfile(uuid: "fresh", expiry: expiry.addingTimeInterval(86_400))
    #expect(ProfileRefreshCompatibility.reason(record: record, original: old, renewed: fresh) == nil)
    let changed = refreshProfile(uuid: "changed", expiry: fresh.expirationDate, certificate: "OTHER")
    #expect(ProfileRefreshCompatibility.reason(record: record, original: old, renewed: changed) != nil)
    let extensionRecord = try refreshRecord(expiry: expiry, extensions: ["app.test.widget"])
    #expect(ProfileRefreshCompatibility.reason(record: extensionRecord, original: old, renewed: fresh) != nil)
    let restricted = try refreshRecord(expiry: expiry, entitlements: ["application-identifier": "TEAM.app.test", "get-task-allow": true])
    #expect(ProfileRefreshCompatibility.reason(record: restricted, original: old, renewed: fresh) != nil)
    #expect(ProfileRefreshCompatibility.permits(["TEAM.*"], ["TEAM.app.test"]))
    #expect(!ProfileRefreshCompatibility.permits(["OTHER.*"], ["TEAM.app.test"]))
    #expect(!ProfileRefreshCompatibility.permits(false, true))
}

@Test func successfulProfileUpdateNeverReinstalls() async throws {
    var events: [String] = []
    let result = try await AppRefreshService.perform(expiration: Date(), incompatibility: nil,
        verification: .init(verifyLaunch: true), profileOnly: {
        events.append("profile-and-verify")
    }, reinstall: { _ in events.append("reinstall") })
    #expect(result.method == .profileOnly)
    #expect(events == ["profile-and-verify"])
    #expect(result.fallbackReason == nil)
}

@Test func explicitCapabilityFailureFallsBackOnceButOfflineAndVerificationFailuresDoNot() async throws {
    var attempts = 0
    var replacements = 0
    let result = try await AppRefreshService.perform(expiration: Date(), incompatibility: nil,
        verification: .init(verifyLaunch: true), profileOnly: {
        attempts += 1
        throw ProfileRefreshError.unsupported("unsupported service")
    }, reinstall: { _ in replacements += 1 })
    #expect(result.method == .reinstalled)
    #expect(attempts == 1 && replacements == 1)
    for error in [ProfileRefreshError.unavailable("locked"), .verification("could not verify launch")] {
        var fallback = false
        do {
            _ = try await AppRefreshService.perform(expiration: Date(), incompatibility: nil,
                verification: .init(verifyLaunch: true),
                profileOnly: { throw error }, reinstall: { _ in fallback = true })
            Issue.record("Unverified refresh must fail")
        } catch { #expect(!fallback) }
    }
}

@Test func changedCertificateSkipsProfileInstallAndFailedReplacementNeverReportsSuccess() async throws {
    var fastPath = false
    var replacements = 0
    do {
        _ = try await AppRefreshService.perform(expiration: Date(), incompatibility: "certificate changed",
            verification: .init(verifyLaunch: true), profileOnly: {
            fastPath = true
        }, reinstall: { _ in replacements += 1; throw ProfileRefreshError.verification("app cannot start") })
        Issue.record("A failed replacement must not return success")
    } catch {
        #expect(!fastPath)
        #expect(replacements == 1)
    }
}

@Test func helperErrorsDistinguishUnavailableRejectedAndInvalidProfiles() {
    for (kind, expected) in [("unavailable", "unavailable"), ("unsupported", "unsupported"),
                             ("rejected", "incompatible"), ("invalid", "verification")] {
        let result = CommandResult(status: 11, data: Data("{\"kind\":\"\(kind)\",\"message\":\"test\"}".utf8))
        do {
            _ = try DeviceProfileService.decodeResponse(result)
            Issue.record("Expected helper failure")
        } catch {
            switch (error, expected) {
            case (ProfileRefreshError.unavailable, "unavailable"), (ProfileRefreshError.unsupported, "unsupported"),
                 (ProfileRefreshError.incompatible, "incompatible"), (ProfileRefreshError.verification, "verification"): break
            default: Issue.record("Wrong error classification: \(error)")
            }
        }
    }
    #expect(!DeviceAppVerification.isSignatureFailure("Device is locked"))
    #expect(DeviceAppVerification.isSignatureFailure("The application has an invalid code signature"))
}

@Test func legacyStoreRecordsStillDecodeWithoutSignatureMetadata() throws {
    let record = try refreshRecord(expiry: Date())
    var object = try #require(JSONSerialization.jsonObject(with: StoreJSON.encoder().encode(record)) as? [String: Any])
    object.removeValue(forKey: "signedEntitlements")
    object.removeValue(forKey: "extensionBundleIdentifiers")
    let legacy = try StoreJSON.decoder().decode(StoreRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.signedEntitlements == nil)
    #expect(legacy.extensionBundleIdentifiers == nil)
    #expect(legacy.app.id == record.app.id)
}

@Test func temporaryWiFiSessionErrorsReconnectAtMostTwice() async throws {
    var attempts = 0
    var waits = 0
    let value = try await DeviceProfileService.withConnectionRetry(operation: {
        attempts += 1
        if attempts < 3 { throw ProfileRefreshError.unavailable("kAMDMuxConnectError") }
        return "connected"
    }, beforeRetry: { waits += 1 })
    #expect(value == "connected" && attempts == 3 && waits == 2)
    attempts = 0
    do {
        _ = try await DeviceProfileService.withConnectionRetry(operation: {
            attempts += 1
            throw ProfileRefreshError.unavailable("kAMDMuxConnectError")
        }, beforeRetry: {})
        Issue.record("Persistent transport failure must fail")
    } catch { #expect(attempts == 3) }
}

@Test func reconnectionNeverRetriesLockErrorsAndHonorsCancellation() async {
    for error in [ProfileRefreshError.unavailable("Device is locked"), .verification("invalid profile")] {
        var attempts = 0
        do {
            _ = try await DeviceProfileService.withConnectionRetry(operation: { attempts += 1; throw error }, beforeRetry: {})
            Issue.record("Expected failure")
        } catch { #expect(attempts == 1) }
    }
    var attempts = 0
    do {
        _ = try await DeviceProfileService.withConnectionRetry(operation: {
            attempts += 1
            throw ProfileRefreshError.unavailable("kAMDMuxConnectError")
        }, beforeRetry: { throw CancellationError() })
        Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError && attempts == 1) }
}

@Test func integrationProfileOnlyRefreshWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let deviceUDID = environment["AUTOSIGN_INTEGRATION_REFRESH_DEVICE"] else { return }
    let device = try #require(try await DeviceService.connectedDevices().first { $0.udid == deviceUDID && $0.isReadyForInstallation })
    let ids = environment["AUTOSIGN_INTEGRATION_REFRESH_APPS"]?.split(separator: ",").map(String.init) ?? []
    let records = try StoreLibrary.records().filter { $0.app.deviceUDID == deviceUDID && (ids.isEmpty || ids.contains($0.app.id)) }
    #expect(!records.isEmpty)
    var checks: [[String: Any]] = []
    for record in records.sorted(by: { !$0.app.isStore && $1.app.isStore }) {
        let original = try await SigningService.readProfile(at: URL(fileURLWithPath: record.profilePath))
        let before = try #require(try await DeviceAppVerification.application(record.app.bundleIdentifier, on: device))
        let result = try await AppRefreshService.refresh(record, on: device,
            verification: .init(verifyLaunch: true)) { message in print(message) }
        #expect(result.method == .profileOnly)
        #expect(result.expiration > record.app.expiration)
        let after = try #require(try await DeviceAppVerification.application(record.app.bundleIdentifier, on: device))
        #expect(before == after)
        let updated = try #require(try StoreLibrary.records().first { $0.app.id == record.app.id })
        #expect(updated.app.expiration == result.expiration)
        try await DeviceProfileService.verify(URL(fileURLWithPath: updated.profilePath), on: device)
        let profile = try await SigningService.readProfile(at: URL(fileURLWithPath: updated.profilePath))
        let pid = try await DeviceAppVerification.verifyLaunch(record.app.bundleIdentifier, on: device, freshLaunch: true)
        checks.append(["app": record.app.name, "bundleIdentifier": record.app.bundleIdentifier,
            "method": result.method.rawValue, "oldUUID": original.uuid, "newUUID": profile.uuid,
            "previousExpiration": ISO8601DateFormatter().string(from: original.expirationDate),
            "expiration": ISO8601DateFormatter().string(from: profile.expirationDate),
            "creationDate": profile.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "expirationExtended": result.expiration > record.app.expiration,
            "installationUnchanged": before == after, "installationURL": after.url.absoluteString,
            "profileReadBackVerified": true, "freshLaunchProcessID": pid])
    }
    if let path = environment["AUTOSIGN_INTEGRATION_REFRESH_REPORT"] {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report: [String: Any] = ["verifiedAt": ISO8601DateFormatter().string(from: Date()),
            "device": device.name, "deviceUDID": device.udid, "iOSVersion": device.osVersion, "checks": checks]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
