import Foundation
import Testing
@testable import AutoSign

@MainActor private final class BackgroundHarness {
    let suite = "AutoSignTests.Background.\(UUID().uuidString)"
    let preferences: UserDefaults
    let now = Date()
    var records: [StoreRecord] = []
    var devices: [AppleDevice] = []
    var calls: [StoreRecord] = []
    var options: [Bool] = []
    var failedIDs: Set<String> = []
    var returnedExpiry: Date?
    var recordReads = 0
    var deviceReads = 0
    var onRead: ((Int) throws -> Void)?
    var deviceError: Error?
    var cancelledID: String?
    var logs: [String] = []
    var notifications: [String] = []

    init() throws {
        preferences = try #require(UserDefaults(suiteName: suite))
        DeviceSelectionStore.save(["phone"], to: preferences)
        devices = [device("phone")]
    }

    func cleanUp() { preferences.removePersistentDomain(forName: suite) }

    func device(_ udid: String, connected: Bool = true, paired: Bool = true, developerMode: Bool = true) -> AppleDevice {
        AppleDevice(id: udid, udid: udid, name: udid, marketingName: "iPhone", kind: .iPhone, osVersion: "17.0",
                    isPaired: paired, developerModeEnabled: developerMode, isConnected: connected)
    }

    func record(_ id: String, device: String = "phone", remaining: TimeInterval = 3_600,
                bundle: String? = nil, isStore: Bool = false, team: String = "TEAM") -> StoreRecord {
        StoreRecord(app: StoreApp(id: id, deviceUDID: device, name: id, bundleIdentifier: bundle ?? "com.test.\(id)",
            version: "1", expiration: now.addingTimeInterval(remaining), refreshedAt: now.addingTimeInterval(-86_400),
            isStore: isStore), ipaPath: "/saved/\(id)/original.ipa", profilePath: "/saved/\(id)/profile.mobileprovision",
            identityID: "CERT-\(team)", teamIdentifier: team)
    }

    func setExpiry(_ id: String, _ expiration: Date) {
        guard let index = records.firstIndex(where: { $0.app.id == id }) else { return }
        let app = records[index].app
        records[index].app = StoreApp(id: app.id, deviceUDID: app.deviceUDID, name: app.name,
            bundleIdentifier: app.bundleIdentifier, version: app.version, expiration: expiration,
            refreshedAt: Date(), isStore: app.isStore, buildVersion: app.buildVersion)
    }

    func status(_ id: String) throws -> RefreshStatus {
        let app = try #require(records.first { $0.app.id == id }?.app)
        return RefreshStatusStore.loadApp(app, preferences: preferences)
    }

    func run() async {
        await BackgroundRefreshCoordinator.run(preferences: preferences, now: now, dependencies: .init(
            records: {
                self.recordReads += 1
                try self.onRead?(self.recordReads)
                return self.records
            }, devices: {
                self.deviceReads += 1
                if let error = self.deviceError { throw error }
                return self.devices
            }, refresh: { record, device, verification, progress in
                self.calls.append(record)
                self.options.append(verification.verifyLaunch)
                #expect(record.app.deviceUDID == device.udid)
                if self.cancelledID == record.app.id { throw CancellationError() }
                if self.failedIDs.contains(record.app.id) { throw AutoSignError.command("failed \(record.app.id)") }
                progress("refresh \(record.app.name)")
                let expiration = self.returnedExpiry ?? self.now.addingTimeInterval(7 * 86_400)
                if expiration > record.app.expiration { self.setExpiry(record.app.id, expiration) }
                return AppRefreshResult(method: .profileOnly, expiration: expiration, fallbackReason: nil, verification: verification)
            }, log: { self.logs.append($0) }, notify: { title, _ in self.notifications.append(title) }
        ))
    }
}

@Test @MainActor func backgroundRefreshesAllDueAppsUsingTheirOwnSavedRecords() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [
        harness.record("store", isStore: true), harness.record("a"), harness.record("b", team: "OTHER"),
        harness.record("fresh", remaining: 3 * 86_400), harness.record("unselected", device: "tablet")
    ]
    harness.preferences.set("/unrelated/current.ipa", forKey: "ipaPath")
    harness.preferences.set("/unrelated/current.mobileprovision", forKey: "profilePath")
    harness.preferences.set("UNRELATED", forKey: "identityID")
    harness.preferences.set(true, forKey: RefreshVerificationOptions.launchPreferenceKey)
    await harness.run()

    #expect(harness.calls.map(\.app.id) == ["a", "b", "store"])
    #expect(harness.calls.map(\.ipaPath) == ["/saved/a/original.ipa", "/saved/b/original.ipa", "/saved/store/original.ipa"])
    #expect(harness.calls.map(\.profilePath) == ["/saved/a/profile.mobileprovision", "/saved/b/profile.mobileprovision", "/saved/store/profile.mobileprovision"])
    #expect(harness.calls.map(\.identityID) == ["CERT-TEAM", "CERT-OTHER", "CERT-TEAM"])
    #expect(harness.options == [true, true, true])
    #expect(try harness.status("fresh").state == "未到续签窗口")
    #expect(try harness.status("a").lastSuccess != nil)
    #expect(RefreshStatusStore.load("tablet", preferences: harness.preferences) == nil)
    #expect(harness.preferences.string(forKey: "ipaPath") == "/unrelated/current.ipa")
    #expect(harness.preferences.string(forKey: "profilePath") == "/unrelated/current.mobileprovision")
    #expect(harness.preferences.string(forKey: "identityID") == "UNRELATED")
    #expect(harness.logs.last?.contains("4 个应用") == true)
    #expect(harness.notifications == ["AutoSign 自动续签成功"])
}

@Test @MainActor func backgroundWindowIncludesExactBoundaryAndExpiredApps() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [harness.record("boundary", remaining: 86_400), harness.record("expired", remaining: -1),
                       harness.record("later", remaining: 86_401)]
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["expired", "boundary"])
    #expect(harness.options == [false, false])
    #expect(try harness.status("later").expiration == harness.now.addingTimeInterval(86_401))
}

@Test @MainActor func backgroundTreatsSameAppOnDifferentDevicesIndependently() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    DeviceSelectionStore.save(["phone", "tablet"], to: harness.preferences)
    harness.devices.append(harness.device("tablet"))
    harness.records = [harness.record("phone-demo", bundle: "com.test.demo"),
        harness.record("tablet-demo", device: "tablet", remaining: 6 * 86_400, bundle: "com.test.demo")]
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["phone-demo"])
    #expect(try harness.status("tablet-demo").lastSuccess == nil)
    #expect(RefreshStatusStore.load("tablet", preferences: harness.preferences)?.expiration == harness.now.addingTimeInterval(6 * 86_400))
}

@Test @MainActor func backgroundFailureDoesNotBlockOtherAppsAndOnlyFailedAppRetries() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [harness.record("a"), harness.record("b"), harness.record("store", isStore: true)]
    let oldExpiry = harness.records[0].app.expiration
    harness.failedIDs = ["a"]
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["a", "b", "store"])
    #expect(try harness.status("a").expiration == oldExpiry)
    #expect(try harness.status("a").lastSuccess == nil)
    #expect(try harness.status("a").failure?.contains("failed a") == true)
    #expect(try harness.status("b").failure == nil)
    #expect(RefreshStatusStore.load("phone", preferences: harness.preferences)?.failure?.contains("failed a") == true)
    let siblingSuccess = try harness.status("b").lastSuccess

    harness.failedIDs = []
    harness.calls = []
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["a"])
    #expect(try harness.status("a").failure == nil)
    #expect(try harness.status("a").lastSuccess != nil)
    #expect(try harness.status("b").lastSuccess == siblingSuccess)
    #expect(RefreshStatusStore.load("phone", preferences: harness.preferences)?.failure == nil)
    #expect(harness.notifications == ["AutoSign 自动续签部分完成", "AutoSign 自动续签成功"])
}

@Test @MainActor func backgroundOfflineDeviceRetriesAllItsDueAppsWithoutRepeatingSuccessfulDevices() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    DeviceSelectionStore.save(["phone", "tablet"], to: harness.preferences)
    harness.records = [harness.record("phone-app"), harness.record("tablet-a", device: "tablet"),
                       harness.record("tablet-b", device: "tablet"), harness.record("tablet-fresh", device: "tablet", remaining: 2 * 86_400)]
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["phone-app"])
    #expect(try harness.status("tablet-a").state == "等待设备就绪")
    #expect(try harness.status("tablet-b").lastSuccess == nil)
    #expect(try harness.status("tablet-fresh").failure == nil)

    harness.devices.append(harness.device("tablet"))
    harness.calls = []
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["tablet-a", "tablet-b"])
    #expect(try harness.status("tablet-a").failure == nil)
    #expect(try harness.status("tablet-b").lastSuccess != nil)
}

@Test(arguments: ["offline", "unpaired", "developer-mode"])
@MainActor func backgroundWaitsForReadyDevicesWithoutAttemptingRefresh(reason: String) async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.devices = [harness.device("phone", connected: reason != "offline", paired: reason != "unpaired", developerMode: reason != "developer-mode")]
    harness.records = [harness.record("due")]
    await harness.run()
    #expect(harness.calls.isEmpty)
    #expect(try harness.status("due").failure != nil)
    #expect(harness.notifications.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func backgroundRereadsEachRecordToAvoidRefreshingUpdatedOrRemovedApps(removed: Bool) async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [harness.record("due")]
    harness.onRead = { read in
        if read == 2 {
            if removed { harness.records = [] }
            else { harness.setExpiry("due", harness.now.addingTimeInterval(7 * 86_400)) }
        }
    }
    await harness.run()
    #expect(harness.calls.isEmpty)
    #expect(harness.notifications.isEmpty)
}

@Test @MainActor func backgroundIgnoresLegacyPendingDevicesAndDoesNotInstallAppsWithoutRecords() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [harness.record("fresh", remaining: 7 * 86_400)]
    await harness.run()
    #expect(harness.calls.isEmpty)
    #expect(harness.deviceReads == 0)
    #expect(harness.notifications.isEmpty)
    harness.records = []
    await harness.run()
    #expect(harness.calls.isEmpty)
    #expect(harness.deviceReads == 0)
    #expect(RefreshStatusStore.load("phone", preferences: harness.preferences)?.state.contains("暂无应用记录") == true)
    #expect(harness.preferences.string(forKey: "ipaPath") == nil)
}

@Test @MainActor func backgroundRecordReadFailureIsIsolatedToOneApp() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [harness.record("a"), harness.record("b")]
    harness.onRead = { read in if read == 2 { throw AutoSignError.command("temporary library failure") } }
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["b"])
    #expect(try harness.status("a").failure?.contains("temporary library failure") == true)
    #expect(try harness.status("b").lastSuccess != nil)
}

@Test @MainActor func backgroundDiscoveryFailureKeepsExpiryForNextCheck() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [harness.record("a"), harness.record("b")]
    harness.deviceError = AutoSignError.command("device discovery failed")
    let expiration = harness.records[0].app.expiration
    await harness.run()
    #expect(harness.calls.isEmpty)
    #expect(harness.records[0].app.expiration == expiration)
    #expect(RefreshStatusStore.load("phone", preferences: harness.preferences)?.failure?.contains("device discovery failed") == true)
    harness.deviceError = nil
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["a", "b"])
}

@Test @MainActor func backgroundRejectsUnextendedExpiryAndStopsOnCancellation() async throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    harness.records = [harness.record("a"), harness.record("b")]
    harness.returnedExpiry = harness.records[0].app.expiration
    await harness.run()
    #expect(try harness.status("a").lastSuccess == nil)
    #expect(try harness.status("a").failure?.contains("没有延长有效期") == true)
    harness.calls = []
    harness.cancelledID = "a"
    harness.returnedExpiry = nil
    await harness.run()
    #expect(harness.calls.map(\.app.id) == ["a"])
    #expect(harness.logs.last?.contains("已取消") == true)
}

@Test @MainActor func appStatusSurvivesRestartAndSeparatesAppsFromLegacyDeviceStatus() throws {
    let harness = try BackgroundHarness()
    defer { harness.cleanUp() }
    let a = harness.record("a").app
    let b = harness.record("b", remaining: 7 * 86_400).app
    RefreshStatusStore.record("phone", state: "旧版设备状态", expiration: b.expiration, success: true, preferences: harness.preferences)
    RefreshStatusStore.recordApp(a, state: "续签失败", failure: "No Accounts", preferences: harness.preferences)
    let reloaded = try #require(UserDefaults(suiteName: harness.suite))
    #expect(RefreshStatusStore.load("phone", preferences: reloaded)?.state == "旧版设备状态")
    #expect(RefreshStatusStore.loadApp(a, preferences: reloaded).expiration == a.expiration)
    #expect(RefreshStatusStore.loadApp(a, preferences: reloaded).failure == "No Accounts")
    #expect(RefreshStatusStore.loadApp(b, preferences: reloaded).failure == nil)
    #expect(RefreshStatusStore.loadApp(b, preferences: reloaded).lastSuccess == nil)

    let updated = StoreApp(id: a.id, deviceUDID: a.deviceUDID, name: a.name, bundleIdentifier: a.bundleIdentifier,
        version: a.version, expiration: b.expiration, refreshedAt: Date().addingTimeInterval(1), isStore: false)
    #expect(RefreshStatusStore.loadApp(updated, preferences: reloaded).failure == nil)
    #expect(RefreshStatusStore.loadApp(updated, preferences: reloaded).expiration == b.expiration)
}
