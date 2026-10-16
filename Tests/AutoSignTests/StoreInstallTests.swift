import AutoSignLocalization
import Foundation
import Testing
@testable import AutoSign

private let installCatalog = #"{"name":"Phone Source","apps":[{"name":"Demo","bundleIdentifier":"com.example.demo","versions":[{"version":"2.0","downloadURL":"https://source.test/demo.ipa","size":42}]}]}"#
private let installDevice = AppleDevice(id: "core-device", udid: "phone", name: "Phone", marketingName: "iPhone", kind: .iPhone,
    osVersion: "17.0", isPaired: true, developerModeEnabled: true, isConnected: true)

private final class InstallSourceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let success = request.url?.path == "/apps.json"
        let response = HTTPURLResponse(url: request.url!, statusCode: success ? 200 : 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((success ? installCatalog : "not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func savedInstallSource(_ url: String = "https://source.test/apps.json") throws -> SavedAppSource {
    SavedAppSource(url: URL(string: url)!, catalog: try AppSourceService.parseCatalog(Data(installCatalog.utf8)), updatedAt: Date())
}

@Test func installPlanRequiresSubscribedAppReadyDeviceAndUniqueRequest() throws {
    let input = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: "phone", sourceURL: "https://source.test/apps.json", bundleIdentifier: "com.example.demo")
    let sources = [try savedInstallSource()]
    let job = try StoreJobPlanner.planInstall(input, sources: sources, devices: [installDevice], jobs: [], isBusy: false)
    #expect(job.installRequest == input)
    #expect(job.items.first?.name == "Demo")
    #expect(try StoreJobPlanner.planInstall(input, sources: [], devices: [], jobs: [job], isBusy: true).id == job.id)
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.planInstall(input, sources: [], devices: [installDevice], jobs: [], isBusy: false) }
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.planInstall(input, sources: sources, devices: [], jobs: [], isBusy: false) }
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.planInstall(input, sources: sources, devices: [installDevice], jobs: [], isBusy: true) }
    let changed = StoreInstallRequest(requestID: input.requestID, deviceUDID: "ipad", sourceURL: input.sourceURL, bundleIdentifier: input.bundleIdentifier)
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.existingInstall(changed, jobs: [job]) }
    let refresh = RefreshRequest(requestID: input.requestID, deviceUDID: input.deviceUDID, appIDs: [input.bundleIdentifier])
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.plan(refresh, records: [], jobs: [job], isBusy: false) }
    for id in ["../other", "app.*", "app.bad/value", "app.bad\n", "", "app.$(command)"] {
        let invalid = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: "phone", sourceURL: input.sourceURL, bundleIdentifier: id)
        #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.existingInstall(invalid, jobs: []) }
    }
}

@Test func installJobRestoresRequestAndReportsInterruptedExecution() throws {
    let input = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: "phone", sourceURL: "https://source.test/apps.json", bundleIdentifier: "com.example.demo")
    let job = try StoreJobPlanner.planInstall(input, sources: [savedInstallSource()], devices: [installDevice], jobs: [], isBusy: false)
    let restored = try StoreJSON.decoder().decode([RefreshJob].self, from: StoreJSON.encoder().encode([job]))
    let recovered = try #require(StoreJobPlanner.recoverInterrupted(restored).first)
    #expect(recovered.installRequest == input)
    #expect(recovered.state == .failed)
    #expect(recovered.items[0].message.contains((AppLanguage.current == .english ? "The Mac service stopped" : "Mac 服务曾退出")))
    #expect(try StoreJobPlanner.existingInstall(input, jobs: [recovered])?.id == job.id)
}

@MainActor
private final class InstallHarness {
    let preferences: UserDefaults
    let suite = "AutoSignTests.Install.\(UUID().uuidString)"
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session: URLSession
    let library: SourceLibraryModel
    var server: StoreServer!
    var versions: [String] = []

    init(failInstall: Bool = false) throws {
        preferences = UserDefaults(suiteName: suite)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstallSourceProtocol.self]
        session = URLSession(configuration: config)
        library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server = StoreServer(preferences: preferences, jobsDirectory: folder, sourceLibrary: library,
            devicesProvider: { [installDevice] }, installExecutor: { [weak self] _, version, progress in
                self?.versions.append(version.version)
                progress("正在签名测试应用…")
                if failInstall { throw AutoSignError.command("test install failed") }
                return Date(timeIntervalSince1970: 2_000_000)
            })
    }
    func close() {
        session.invalidateAndCancel()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    func call(_ path: String, method: String = "GET", body: Data = Data(), authorized: Bool = true) async -> StoreHTTPResponse {
        await server.handle(StoreHTTPRequest(method: method, path: path,
            headers: ["authorization": authorized ? "Bearer \(server.token)" : "invalid", "content-type": "application/json"], body: body))
    }
    func waitForJob(_ id: String) async throws -> RefreshJob {
        for _ in 0..<100 {
            let response = await call("/v1/jobs/\(id)")
            let job = try StoreJSON.decoder().decode(RefreshJob.self, from: response.body)
            if job.state.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AutoSignError.command("Timed out waiting for test job")
    }
}

@Test @MainActor func authenticatedSourceCRUDSharesMacLibraryAndRetainsCacheOnFailure() async throws {
    let harness = try InstallHarness()
    defer { harness.close() }
    let body = try StoreJSON.encoder().encode(StoreSourceRequest(url: "https://source.test/apps.json"))
    for (path, method) in [("/v1/sources", "GET"), ("/v1/sources", "POST"), ("/v1/sources/remove", "POST"), ("/v1/sources/refresh", "POST"), ("/v1/install", "POST")] {
        #expect(await harness.call(path, method: method, body: body, authorized: false).status == 401)
    }
    let added = await harness.call("/v1/sources", method: "POST", body: body)
    #expect(added.status == 200)
    #expect(harness.library.sources.count == 1)
    #expect(AppSourceStore.load(from: harness.preferences).count == 1)
    #expect(await harness.call("/v1/sources", method: "POST", body: body).status == 200)
    #expect(harness.library.sources.count == 1)
    #expect(await harness.call("/v1/sources/refresh", method: "POST", body: body).status == 200)
    let invalid = try StoreJSON.encoder().encode(StoreSourceRequest(url: "file:///private/apps.json"))
    #expect(await harness.call("/v1/sources", method: "POST", body: invalid).status == 400)
    let missing = try StoreJSON.encoder().encode(StoreSourceRequest(url: "https://source.test/missing.json"))
    #expect(await harness.call("/v1/sources", method: "POST", body: missing).status == 400)
    #expect(harness.library.sources.count == 1)
    #expect(await harness.call("/v1/sources/remove", method: "POST", body: body).status == 200)
    #expect(harness.library.sources.isEmpty)
}

@Test @MainActor func installPersistsBeforeExecutionFetchesLatestAndRetriesWithoutReinstalling() async throws {
    let harness = try InstallHarness()
    defer { harness.close() }
    _ = try await harness.library.fetchAndSaveSource("https://source.test/apps.json")
    // Simulate a disk cache containing an older release.
    let cached = try AppSourceService.parseCatalog(Data(installCatalog.replacingOccurrences(of: "2.0", with: "1.0").utf8))
    try AppSourceStore.save([SavedAppSource(url: URL(string: "https://source.test/apps.json")!, catalog: cached, updatedAt: Date())], to: harness.preferences)
    let library = SourceLibraryModel(preferences: harness.preferences, service: AppSourceService(session: harness.session))
    let server = StoreServer(preferences: harness.preferences, jobsDirectory: harness.folder, sourceLibrary: library,
        devicesProvider: { [installDevice] }, installExecutor: { [weak harness] _, version, progress in
            harness?.versions.append(version.version)
            progress("正在安装…")
            return Date(timeIntervalSince1970: 2_000_000)
        })
    harness.server = server
    let input = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: "phone", sourceURL: "https://source.test/apps.json", bundleIdentifier: "com.example.demo")
    let body = try StoreJSON.encoder().encode(input)
    let response = await harness.call("/v1/install", method: "POST", body: body)
    #expect(response.status == 202)
    let job = try StoreJSON.decoder().decode(RefreshJob.self, from: response.body)
    let disk = try StoreJSON.decoder().decode([RefreshJob].self, from: Data(contentsOf: harness.folder.appendingPathComponent("jobs.json")))
    #expect(disk.first?.id == job.id)
    #expect(disk.first?.state == .queued)
    #expect(harness.versions.isEmpty)
    #expect(try await server.submitInstall(input).id == job.id)
    let result = try await harness.waitForJob(job.id)
    #expect(result.state == .completed)
    #expect(result.items[0].expiration != nil)
    #expect(harness.versions == ["2.0"])
    let restarted = StoreServer(preferences: harness.preferences, jobsDirectory: harness.folder, devicesProvider: { [] })
    #expect(try await restarted.submitInstall(input).id == job.id)
    #expect(harness.versions.count == 1)
}

@Test @MainActor func installFailuresAreDurableAndDoNotClaimAnExpiration() async throws {
    let harness = try InstallHarness(failInstall: true)
    defer { harness.close() }
    _ = try await harness.library.fetchAndSaveSource("https://source.test/apps.json")
    let input = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: "phone", sourceURL: "https://source.test/apps.json", bundleIdentifier: "com.example.demo")
    let job = try await harness.server.submitInstall(input)
    let result = try await harness.waitForJob(job.id)
    #expect(result.state == .failed)
    #expect(result.items[0].message == "test install failed")
    #expect(result.items[0].expiration == nil)
    let persisted = try StoreJSON.decoder().decode([RefreshJob].self, from: Data(contentsOf: harness.folder.appendingPathComponent("jobs.json")))
    #expect(persisted.first?.state == .failed)
}

@Test @MainActor func newSourceAppsGetStableDistinctTeamScopedIdentifiers() {
    let seed = ProvisioningProfile(name: "Store", uuid: "seed", expirationDate: Date(), applicationIdentifier: "TEAM.com.example.store",
        teamIdentifier: "TEAM", provisionedDevices: ["phone"], provisionsAllDevices: false, entitlements: [:])
    let first = StoreInstallService.newBundleIdentifier(sourceID: "com.publisher.demo", seed: seed)
    let second = StoreInstallService.newBundleIdentifier(sourceID: "com.publisher.other", seed: seed)
    #expect(first == "com.publisher.demo.autosign.team")
    #expect(first != second)
    #expect(first != "com.example.store")
    #expect(StoreInstallService.newBundleIdentifier(sourceID: "com.example.store", seed: seed) == "com.example.store")
    let longID = "com." + String(repeating: "a", count: 250)
    let shortened = StoreInstallService.newBundleIdentifier(sourceID: longID, seed: seed)
    #expect(SigningService.isValidBundleIdentifier(shortened))
    #expect(shortened == StoreInstallService.newBundleIdentifier(sourceID: longID, seed: seed))
}

@Test @MainActor func failedFreshCatalogFetchNeverRunsInstallerWithCachedDownloadURL() async throws {
    let harness = try InstallHarness()
    defer { harness.close() }
    try AppSourceStore.save([savedInstallSource("https://source.test/missing.json")], to: harness.preferences)
    let library = SourceLibraryModel(preferences: harness.preferences, service: AppSourceService(session: harness.session))
    harness.server = StoreServer(preferences: harness.preferences, jobsDirectory: harness.folder, sourceLibrary: library,
        devicesProvider: { [installDevice] }, installExecutor: { [weak harness] _, version, _ in
            harness?.versions.append(version.version)
            return Date()
        })
    let input = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: "phone", sourceURL: "https://source.test/missing.json", bundleIdentifier: "com.example.demo")
    let job = try await harness.server.submitInstall(input)
    let result = try await harness.waitForJob(job.id)
    #expect(result.state == .failed)
    #expect(result.items[0].message.contains("404"))
    #expect(harness.versions.isEmpty)
    #expect(library.sources.first?.catalog.apps.count == 1)
}

@Test func readsRealOriginalBundleIdentifierFromDownloadedIPA() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let app = folder.appendingPathComponent("Payload/Demo.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.original"], format: .binary, options: 0)
    try plist.write(to: app.appendingPathComponent("Info.plist"))
    let ipa = folder.appendingPathComponent("demo.ipa")
    _ = try await ProcessRunner.checked("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.appendingPathComponent("Payload").path, ipa.path], context: "test IPA")
    #expect(try await AppSourceService.packageBundleIdentifier(at: ipa) == "com.example.original")
}

@Test @MainActor func upgradesFindOriginalIdentityWithoutUsingOtherDevicesOrUnrelatedApps() async throws {
    func record(_ id: String, device: String, installedID: String, sourceID: String? = nil) -> StoreRecord {
        StoreRecord(app: StoreApp(id: id, deviceUDID: device, name: id, bundleIdentifier: installedID, version: "1",
            expiration: Date(), refreshedAt: Date(), isStore: false), ipaPath: "/\(id).ipa", profilePath: "/\(id).mobileprovision",
            identityID: "CERT", teamIdentifier: "TEAM", sourceBundleIdentifier: sourceID)
    }
    let others = [record("ipad", device: "ipad", installedID: "com.publisher.demo"),
                  record("store", device: "phone", installedID: "com.my.store")]
    let legacy = record("legacy", device: "phone", installedID: "com.my.demo")
    let found = await StoreInstallService.existingRecord(sourceID: "com.publisher.demo", deviceUDID: "phone", records: others + [legacy],
        originalID: { $0.lastPathComponent == "legacy.ipa" ? "com.publisher.demo" : nil })
    #expect(found?.app.bundleIdentifier == "com.my.demo")
    #expect(found?.teamIdentifier == "TEAM")
    #expect(found?.identityID == "CERT")
    let linked = record("linked", device: "phone", installedID: "com.my.demo", sourceID: "com.publisher.demo")
    let direct = await StoreInstallService.existingRecord(sourceID: "com.publisher.demo", deviceUDID: "phone", records: others + [linked],
        originalID: { _ in Issue.record("Linked source should not inspect IPA"); return nil })
    #expect(direct?.app.id == "linked")
    let fresh = await StoreInstallService.existingRecord(sourceID: "com.publisher.new", deviceUDID: "phone", records: others,
        originalID: { _ in nil })
    #expect(fresh == nil)
}
