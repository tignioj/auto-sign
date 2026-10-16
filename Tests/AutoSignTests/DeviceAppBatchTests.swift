import AutoSignLocalization
import Foundation
import Testing
@testable import AutoSign

private func batchDevice(_ udid: String, ready: Bool = true, kind: DeviceKind = .iPhone) -> AppleDevice {
    AppleDevice(id: "core-" + udid, udid: udid, name: udid, marketingName: kind.title,
                kind: kind, osVersion: "27.0", isPaired: ready, developerModeEnabled: ready, isConnected: ready)
}

private func batchSource(_ path: String = "latest", version: String = "1.0") throws -> SavedAppSource {
    let apps = ["one", "two", "store"].map { name in
        ["name": name, "bundleIdentifier": "app." + name,
         "versions": [["version": version, "downloadURL": "https://batch.test/\(name).ipa"]]] as [String: Any]
    }
    let data = try JSONSerialization.data(withJSONObject: ["name": path, "apps": apps])
    return SavedAppSource(url: URL(string: "https://batch.test/\(path).json")!,
                          catalog: try AppSourceService.parseCatalog(data), updatedAt: .distantPast)
}

private func batchRecord(_ name: String, device: String = "phone", isStore: Bool = false) -> StoreRecord {
    StoreRecord(app: StoreApp(id: device + "-" + name, deviceUDID: device, name: name,
        bundleIdentifier: "app.\(name).autosign.team", version: "1.0", expiration: Date().addingTimeInterval(3_600),
        refreshedAt: .distantPast, isStore: isStore), ipaPath: "/fixture/\(name).ipa",
        profilePath: "/fixture/\(name).mobileprovision", identityID: "certificate", teamIdentifier: "TEAM",
        sourceBundleIdentifier: "app." + name)
}

private final class BatchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let success = request.url?.path == "/latest.json"
        let data = success ? try! JSONEncoder().encode(batchSource(version: "2.0").catalog) : Data("Not found".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: success ? 200 : 404,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func batchSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BatchURLProtocol.self]
    return URLSession(configuration: config)
}

@Test @MainActor func interfaceSelectsOneDeviceAndKeepsEarlierRenewalTargets() throws {
    let suite = "AutoSignTests.SingleDevice.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    DeviceSelectionStore.save(["phone", "tablet"], to: preferences)
    let model = AppModel(performInitialRefresh: false, preferences: preferences,
                         sourceLibrary: SourceLibraryModel(preferences: preferences), dependencies: .init(records: { [] }))
    let phone = batchDevice("phone")
    let tablet = batchDevice("tablet", kind: .iPad)
    model.updateDevices([phone, tablet])
    #expect(model.selectedDevice?.udid == "phone")
    model.selectDevice(tablet)
    #expect(model.selectedDeviceID == tablet.id)
    #expect(model.deviceKind == .iPad)
    #expect(DeviceSelectionStore.load(from: preferences) == ["phone", "tablet"])
    model.updateDevices([phone])
    #expect(model.selectedDevice == nil) // Do not silently retarget when the chosen device disappears.
    model.updateDevices([phone, tablet])
    #expect(model.selectedDevice?.udid == "tablet")
}

@Test @MainActor func multiAppSelectionSpansSourcesDeduplicatesAndClearsWhenDeviceChanges() throws {
    let suite = "AutoSignTests.AppSelection.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = try batchSource()
    let other = try batchSource("other")
    try AppSourceStore.save([source, other], to: preferences)
    let library = SourceLibraryModel(preferences: preferences)
    let model = AppModel(performInitialRefresh: false, preferences: preferences, sourceLibrary: library,
                         dependencies: .init(records: { [] }))
    model.updateDevices([batchDevice("phone"), batchDevice("other")])
    #expect(model.selectedDevice?.udid == "phone")
    model.toggleApp(source.catalog.apps[0], in: source)
    model.toggleApp(other.catalog.apps[1], in: other)
    #expect(model.selectedApps.map(\.id) == ["app.one", "app.two"])
    #expect(!model.canInstall)
    model.profileURL = URL(fileURLWithPath: "/fixture/seed.mobileprovision")
    #expect(model.canInstall)
    #expect(!model.canRefreshApps)
    model.toggleApp(other.catalog.apps[0], in: other)
    #expect(model.selectedApps.count == 2)
    #expect(!model.isAppSelected(source.catalog.apps[0], in: source))
    #expect(model.isAppSelected(other.catalog.apps[0], in: other))
    model.selectDevice(batchDevice("other"))
    #expect(model.selectedApps.isEmpty)
    #expect(!model.canInstall)
}

@Test @MainActor func batchInstallFetchesLatestTargetsOneDeviceAndContinuesAfterFailure() async throws {
    let suite = "AutoSignTests.BatchInstall.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = try batchSource()
    try AppSourceStore.save([source], to: preferences)
    DeviceSelectionStore.save(["earlier-device"], to: preferences)
    let session = batchSession()
    defer { session.invalidateAndCancel() }
    let library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
    var calls: [StoreInstallRequest] = []
    let model = AppModel(performInitialRefresh: false, preferences: preferences, sourceLibrary: library,
        dependencies: .init(records: { [] }, install: { input, version, _, progress in
            calls.append(input)
            #expect(version.version == "2.0") // Ignore the cached 1.0 release.
            progress("安装中")
            if input.bundleIdentifier == "app.one" { throw AutoSignError.command("模拟失败") }
            return Date().addingTimeInterval(7 * 86_400)
        }))
    model.updateDevices([batchDevice("phone"), batchDevice("other")])
    model.selectDevice(batchDevice("phone"))
    model.profileURL = URL(fileURLWithPath: "/fixture/seed.mobileprovision")
    for app in source.catalog.apps.prefix(2) { model.toggleApp(app, in: source) }
    let task = try #require(model.perform(.install))
    #expect(model.stage.isRunning)
    #expect(library.isPerformingDeviceOperation)
    #expect(model.perform(.install) == nil) // A repeated click must not queue a second batch.
    model.selectDevice(batchDevice("other"))
    model.clearAppSelection()
    #expect(model.selectedDevice?.udid == "phone")
    #expect(model.selectedApps.count == 2)
    await task.value
    #expect(calls.map(\.deviceUDID) == ["phone", "phone"])
    #expect(calls.map(\.bundleIdentifier) == ["app.one", "app.two"])
    #expect(Set(calls.map(\.requestID)).count == 2)
    #expect(model.operationItems.map(\.state) == [.failed, .completed])
    #expect(model.completedAppCount == 1)
    #expect(!library.isBusy)
    #expect(DeviceSelectionStore.load(from: preferences) == ["earlier-device", "phone"])
    #expect(model.detail.contains("1/2"))
}

@Test @MainActor func batchInstallRejectsUnavailableFreshSourceAndNeverUsesCachedRelease() async throws {
    let suite = "AutoSignTests.BatchFreshSource.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = try batchSource("gone")
    try AppSourceStore.save([source], to: preferences)
    let session = batchSession()
    defer { session.invalidateAndCancel() }
    let library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
    #expect(library.beginDeviceOperation())
    defer { library.endDeviceOperation() }
    var calls = 0
    let results = await DeviceAppBatch.run([SourceAppSelection(sourceURL: source.id, app: source.catalog.apps[0])],
        operation: .install, on: batchDevice("phone"), library: library, preferences: preferences,
        dependencies: .init(records: { [] }, install: { _, _, _, _ in calls += 1; return Date() }), itemChanged: { _ in })
    #expect(calls == 0)
    #expect(results.first?.state == .failed)
    #expect(results.first?.message.contains("404") == true)
    #expect(results.first?.expiration == nil)
}

@Test @MainActor func batchRefreshUsesInstalledRecordsOrdersStoreLastAndDoesNotFetchSources() async throws {
    let suite = "AutoSignTests.BatchRefresh.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: RefreshVerificationOptions.launchPreferenceKey)
    // This source returns 404: refresh must use the saved IPA without contacting it.
    let source = try batchSource("gone")
    try AppSourceStore.save([source], to: preferences)
    let session = batchSession()
    defer { session.invalidateAndCancel() }
    let library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
    let records = [batchRecord("one"), batchRecord("two"), batchRecord("store", isStore: true),
                   batchRecord("one", device: "other")]
    let apps = source.catalog.apps
    let selections = [apps[2], apps[0], apps[1]].map { SourceAppSelection(sourceURL: source.id, app: $0) }
    var refreshed: [String] = []
    let results = await DeviceAppBatch.run(selections, operation: .refresh, on: batchDevice("phone"),
        library: library, preferences: preferences,
        dependencies: .init(records: { records }, refresh: { record, device, verification, _ in
            #expect(device.udid == "phone")
            #expect(record.app.deviceUDID == "phone")
            #expect(record.app.version == "1.0")
            #expect(record.app.bundleIdentifier.hasSuffix(".autosign.team"))
            #expect(verification.verifyLaunch)
            refreshed.append(record.app.name)
            if record.app.name == "one" { throw AutoSignError.command("设备锁定") }
            return AppRefreshResult(method: .profileOnly, expiration: record.app.expiration.addingTimeInterval(86_400),
                                    fallbackReason: nil, verification: verification)
        }), itemChanged: { _ in })
    #expect(refreshed == ["one", "two", "store"])
    #expect(results.map(\.state) == [.failed, .completed, .completed])
    #expect(results.last?.message.contains((AppLanguage.current == .english ? "without reinstalling" : "无需重装")) == true)
    #expect(library.sourceErrors.isEmpty)
    #expect(RefreshStatusStore.loadApp(records[0].app, preferences: preferences).failure == "设备锁定")
    #expect(RefreshStatusStore.loadApp(records[1].app, preferences: preferences).lastSuccess != nil)
    #expect(RefreshStatusStore.loadApp(records[3].app, preferences: preferences).lastSuccess == nil)
}

@Test @MainActor func refreshRequiresEverySelectedAppToBelongToCurrentDevice() async throws {
    let suite = "AutoSignTests.RefreshOwnership.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = try batchSource()
    try AppSourceStore.save([source], to: preferences)
    let model = AppModel(performInitialRefresh: false, preferences: preferences,
        sourceLibrary: SourceLibraryModel(preferences: preferences),
        dependencies: .init(records: { [batchRecord("one"), batchRecord("two", device: "other")] }))
    model.updateDevices([batchDevice("phone")])
    await model.refreshDashboard()
    model.toggleApp(source.catalog.apps[0], in: source)
    #expect(model.canRefreshApps)
    model.toggleApp(source.catalog.apps[1], in: source)
    #expect(!model.canRefreshApps)
    #expect(model.perform(.refresh) == nil)
    model.removeSelectedApp("app.two")
    #expect(model.canRefreshApps)
}

@Test @MainActor func batchRefreshRejectsUnextendedExpiryAndMissingDeviceRecord() async throws {
    let suite = "AutoSignTests.RefreshValidation.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = try batchSource()
    let record = batchRecord("one")
    var calls = 0
    let results = await DeviceAppBatch.run(source.catalog.apps.prefix(2).map { SourceAppSelection(sourceURL: source.id, app: $0) },
        operation: .refresh, on: batchDevice("phone"), library: SourceLibraryModel(preferences: preferences),
        preferences: preferences, dependencies: .init(records: { [record, batchRecord("two", device: "other")] },
            refresh: { record, _, verification, _ in
                calls += 1
                return AppRefreshResult(method: .profileOnly, expiration: record.app.expiration,
                                        fallbackReason: nil, verification: verification)
            }), itemChanged: { _ in })
    #expect(calls == 1)
    #expect(results.map(\.state) == [.failed, .failed])
    #expect(results[0].message.contains((AppLanguage.current == .english ? "does not extend validity" : "没有延长有效期")))
    #expect(results[1].message.contains((AppLanguage.current == .english ? "Install it first" : "请先安装")))
    #expect(results.allSatisfy { $0.expiration == nil })
    #expect(RefreshStatusStore.loadApp(record.app, preferences: preferences).lastSuccess == nil)
}

@Test @MainActor func sourceReservationBlocksMutationsUntilDeviceOperationEnds() async throws {
    let suite = "AutoSignTests.SourceReservation.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let source = try batchSource()
    try AppSourceStore.save([source], to: preferences)
    let session = batchSession()
    defer { session.invalidateAndCancel() }
    let library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
    #expect(library.beginDeviceOperation())
    #expect(!library.beginDeviceOperation())
    #expect(throws: AppSourceError.self) { try library.removeSource(source.id) }
    await #expect(throws: AppSourceError.self) { try await library.fetchAndSaveSource(source.id) }
    #expect(!(await library.checkSourcesIfDue()))
    let fresh = try await library.fetchAndSaveSource(source.id, forDeviceOperation: true)
    #expect(fresh.catalog.apps[0].latestVersion?.version == "2.0")
    library.endDeviceOperation()
    #expect(!library.isBusy)
    try library.removeSource(source.id)
    #expect(library.sources.isEmpty)
}
