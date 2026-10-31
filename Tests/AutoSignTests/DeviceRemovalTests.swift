import Foundation
import Testing
@testable import AutoSign

private func removalDevice(_ udid: String, name: String = "SE3", id: String? = nil) -> AppleDevice {
    AppleDevice(id: id ?? "core-\(udid)", udid: udid, name: name, marketingName: "iPhone",
                kind: .iPhone, osVersion: "27.0", isPaired: true, developerModeEnabled: true, isConnected: true)
}

private func removalRecord(_ udid: String) -> StoreRecord {
    StoreRecord(app: StoreApp(id: "app-\(udid)", deviceUDID: udid, name: "Demo", bundleIdentifier: "app.demo",
                             version: "1.0", expiration: Date().addingTimeInterval(3_600), refreshedAt: .distantPast,
                             isStore: false), ipaPath: "/saved/\(udid)/original.ipa",
                profilePath: "/saved/\(udid)/profile.mobileprovision", identityID: "CERT")
}

@Test func removingDevicePersistsByUDIDAndRestoresItsPreviousRenewalSetting() throws {
    let suite = "AutoSignTests.DeviceRemovalStore.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    DeviceSelectionStore.save(["se3", "17pm"], to: preferences)
    RefreshStatusStore.record("se3", name: "SE3", state: "saved history", success: true, preferences: preferences)
    ProfileRefreshPolicy.setProfileOnly(true, on: "se3", preferences: preferences)

    try DeviceRemovalStore.remove(udid: "se3", name: "SE3", preferences: preferences)
    try DeviceRemovalStore.remove(udid: "se3", name: "Renamed phone", preferences: preferences)
    #expect(DeviceSelectionStore.load(from: preferences) == ["17pm"])
    #expect(DeviceSelectionStore.loadPending(from: preferences) == ["17pm"])
    #expect(preferences.string(forKey: DeviceSelectionStore.legacyDeviceUDIDKey) == "17pm")
    let reloaded = try #require(UserDefaults(suiteName: suite))
    #expect(DeviceRemovalStore.load(from: reloaded) == [RemovedDevice(udid: "se3", name: "SE3", wasAutomaticRefreshTarget: true)])
    #expect(RefreshStatusStore.load("se3", preferences: reloaded)?.state == "saved history")
    #expect(ProfileRefreshPolicy.profileOnly(on: "se3", preferences: reloaded))

    try DeviceRemovalStore.remove(udid: "17pm", name: "17PM", preferences: preferences)
    #expect(DeviceSelectionStore.load(from: preferences).isEmpty)
    #expect(DeviceSelectionStore.loadPending(from: preferences).isEmpty)
    #expect(preferences.string(forKey: DeviceSelectionStore.legacyDeviceUDIDKey) == nil)
    try DeviceRemovalStore.restore("se3", preferences: preferences)
    #expect(DeviceSelectionStore.load(from: preferences) == ["se3"])
    #expect(DeviceSelectionStore.loadPending(from: preferences) == ["se3"])
    #expect(DeviceRemovalStore.removedUDIDs(from: preferences) == ["17pm"])

    // A device that was never a renewal target must not join automatic refresh when restored.
    try DeviceRemovalStore.remove(udid: "unused", name: "SE3", preferences: preferences)
    try DeviceRemovalStore.restore("unused", preferences: preferences)
    #expect(DeviceSelectionStore.load(from: preferences) == ["se3"])
}

@Test @MainActor func removingCurrentDeviceClearsSelectionAndSurvivesDiscoveryAndRestart() throws {
    let suite = "AutoSignTests.RemoveSelectedDevice.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let library = SourceLibraryModel(preferences: preferences)
    let model = AppModel(performInitialRefresh: false, preferences: preferences, sourceLibrary: library,
                         dependencies: .init(records: { [] }))
    let phone = removalDevice("se3")
    let other = removalDevice("other", name: "SE3") // Same name, different physical device.
    model.updateDevices([phone, other])
    let catalog = try AppSourceService.parseCatalog(Data(#"{"name":"Demo Source","apps":[{"name":"Demo","bundleIdentifier":"app.demo","version":"1.0","downloadURL":"https://example.test/demo.ipa"}]}"#.utf8))
    let source = SavedAppSource(url: URL(string: "https://example.test/apps.json")!, catalog: catalog, updatedAt: .distantPast)
    model.toggleApp(try #require(catalog.apps.first), in: source)
    model.setProfileOnlyRefresh(true)
    #expect(model.selectedApps.count == 1)

    model.removeDevice(udid: phone.udid, name: phone.name)
    #expect(model.selectedDevice == nil)
    #expect(model.selectedApps.isEmpty)
    #expect(model.operationItems.isEmpty)
    #expect(!model.profileOnlyRefresh)
    #expect(preferences.string(forKey: AppModel.selectedDevicePreferenceKey) == nil)
    #expect(model.devices.map(\.udid) == [other.udid])
    model.updateDevices([removalDevice("se3", name: "Renamed", id: "new-core-id"), other])
    #expect(model.devices.map(\.udid) == [other.udid])
    #expect(model.selectedDevice == nil)
    let restarted = AppModel(performInitialRefresh: false, preferences: preferences, sourceLibrary: library,
                             dependencies: .init(records: { [] }))
    restarted.updateDevices([phone, other])
    #expect(restarted.devices.map(\.udid) == [other.udid])
    #expect(restarted.removedDevices.map(\.udid) == [phone.udid])
}

@Test @MainActor func removingOfflineDeviceKeepsOtherSelectionAndIsBlockedDuringOperations() throws {
    let suite = "AutoSignTests.RemoveOfflineDevice.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let library = SourceLibraryModel(preferences: preferences)
    let model = AppModel(performInitialRefresh: false, preferences: preferences, sourceLibrary: library,
                         dependencies: .init(records: { [] }))
    model.updateDevices([removalDevice("active")])
    DeviceSelectionStore.save(["active", "offline"], to: preferences)
    model.renewalStatuses = [RefreshStatus(id: "offline", name: "17PM")]
    model.appRenewalStatuses = ["offline": []]
    #expect(library.beginDeviceOperation())
    model.removeDevice(udid: "offline", name: "17PM")
    #expect(model.removedDevices.isEmpty)
    library.endDeviceOperation()
    model.stage = .installing
    model.removeDevice(udid: "offline", name: "17PM")
    #expect(model.removedDevices.isEmpty)
    model.stage = .idle
    model.removeDevice(udid: "offline", name: "17PM")
    #expect(model.selectedDevice?.udid == "active")
    #expect(model.renewalStatuses.isEmpty)
    #expect(model.appRenewalStatuses["offline"] == nil)
    #expect(DeviceSelectionStore.load(from: preferences) == ["active"])
}

@Test @MainActor func phoneSnapshotImmediatelyHidesRemovedDevicesAndRejectsStaleRequests() async throws {
    let suite = "AutoSignTests.RemovedPhoneAPI.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let devices = [removalDevice("se3"), removalDevice("17pm", name: "17PM")]
    let records = [removalRecord("se3"), removalRecord("17pm")]
    let server = StoreServer(preferences: preferences, jobsDirectory: folder,
        devicesProvider: { devices }, recordsProvider: { records })
    func status() async throws -> StoreSnapshot {
        let response = await server.handle(StoreHTTPRequest(method: "GET", path: "/v1/status",
            headers: ["authorization": "Bearer \(server.token)"], body: Data()))
        #expect(response.status == 200)
        return try StoreJSON.decoder().decode(StoreSnapshot.self, from: response.body)
    }
    #expect(try await status().devices.count == 2)
    try DeviceRemovalStore.remove(udid: "se3", name: "SE3", preferences: preferences)
    // The second snapshot uses the same ten-second discovery cache.
    let hidden = try await status()
    #expect(hidden.devices.map(\.id) == ["17pm"])
    #expect(hidden.apps.map(\.deviceUDID) == ["17pm"])
    let refresh = RefreshRequest(requestID: UUID().uuidString, deviceUDID: "se3", appIDs: ["app-se3"])
    let install = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: "se3",
        sourceURL: "https://example.test/apps.json", bundleIdentifier: "app.demo")
    for (path, body) in [("/v1/refresh", try StoreJSON.encoder().encode(refresh)),
                         ("/v1/updates", try StoreJSON.encoder().encode(refresh)),
                         ("/v1/install", try StoreJSON.encoder().encode(install))] {
        let response = await server.handle(StoreHTTPRequest(method: "POST", path: path,
            headers: ["authorization": "Bearer \(server.token)", "content-type": "application/json"], body: body))
        #expect(response.status == 400)
        #expect(!server.isBusy)
    }
    try DeviceRemovalStore.restore("se3", preferences: preferences)
    let restored = try await status()
    #expect(restored.devices.count == 2)
    #expect(restored.apps.map(\.id) == records.map(\.app.id))
}
