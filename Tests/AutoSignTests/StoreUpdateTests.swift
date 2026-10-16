import AutoSignLocalization
import Foundation
import Testing
@testable import AutoSign

private let updateURL = "https://updates.test/apps.json"
private let updateDevice = AppleDevice(id: "device", udid: "phone", name: "Phone", marketingName: "iPhone", kind: .iPhone,
    osVersion: "17.0", isPaired: true, developerModeEnabled: true, isConnected: true)
private let updateCatalog = #"{"name":"Updates","apps":[{"name":"Demo","bundleIdentifier":"com.publisher.demo","versions":[{"version":"2.0","buildVersion":"20","downloadURL":"https://updates.test/demo.ipa"}]},{"name":"Store","bundleIdentifier":"local.autosign.store","versions":[{"version":"2.0","buildVersion":"20","downloadURL":"https://updates.test/store.ipa"}]}]}"#

private func updateRecord(_ id: String = "demo", device: String = "phone", version: String = "1.0", build: String? = "10",
                          sourceURL: String? = updateURL, sourceID: String? = "com.publisher.demo", isStore: Bool = false) -> StoreRecord {
    StoreRecord(app: StoreApp(id: id, deviceUDID: device, name: id, bundleIdentifier: "com.my.\(id)", version: version,
        expiration: Date(timeIntervalSince1970: 2_000_000), refreshedAt: Date(), isStore: isStore, buildVersion: build),
        ipaPath: "/\(id).ipa", profilePath: "/\(id).mobileprovision", identityID: "CERT", teamIdentifier: "TEAM",
        sourceBundleIdentifier: sourceID, sourceURL: sourceURL)
}

private func updateSource(_ url: String = updateURL, version: String = "2.0") throws -> SavedAppSource {
    SavedAppSource(url: URL(string: url)!, catalog: try AppSourceService.parseCatalog(Data(updateCatalog.replacingOccurrences(of: "2.0", with: version).utf8)),
                   updatedAt: Date(timeIntervalSince1970: 1_000_000))
}

@Test func updateVersionsIncludeBuildsAndNeverOfferDowngrades() throws {
    let release = try #require(updateSource().catalog.apps.first?.latestVersion)
    #expect(StoreUpdateDetector.isNewer(release, than: updateRecord(version: "1.10").app))
    #expect(StoreUpdateDetector.isNewer(release, than: updateRecord(version: "2.0", build: "19").app))
    #expect(!StoreUpdateDetector.isNewer(release, than: updateRecord(version: "2.0", build: "20").app))
    #expect(!StoreUpdateDetector.isNewer(release, than: updateRecord(version: "2.0", build: "21").app))
    #expect(!StoreUpdateDetector.isNewer(release, than: updateRecord(version: "2.0", build: nil).app))
    #expect(!StoreUpdateDetector.isNewer(release, than: updateRecord(version: "3.0").app))
    #expect(StoreUpdateDetector.compareVersions("1.10", "1.9") == .orderedDescending)
    #expect(StoreUpdateDetector.compareVersions("v1.0", "1.0.0") == .orderedSame)
    #expect(StoreUpdateDetector.compareVersions("2.0-rc.2", "2.0-rc.10") == .orderedAscending)
    #expect(StoreUpdateDetector.compareVersions("2.0", "2.0-rc.10") == .orderedDescending)
    #expect(StoreUpdateDetector.compareVersions("2.0+build", "2.0") == .orderedSame)
    #expect(StoreUpdateDetector.compareVersions("", "2.0") == .orderedAscending)
}

@Test @MainActor func updatesResolveRewrittenLegacyIDsAndPinTheSource() async throws {
    let sources = [try updateSource(), try updateSource("https://other.test/apps.json", version: "9.0")]
    let linked = updateRecord()
    let result = await StoreUpdateDetector.updates(records: [linked], sources: sources)
    #expect(result.first?.id == linked.app.id)
    #expect(result.first?.version == "2.0")
    #expect(result.first?.sourceURL == updateURL)
    #expect(await StoreUpdateDetector.updates(records: [linked], sources: [sources[1]]).isEmpty)
    let legacy = updateRecord(sourceURL: nil, sourceID: nil)
    #expect(await StoreUpdateDetector.updates(records: [legacy], sources: sources, packageMetadata: { _ in .init(bundleIdentifier: "com.publisher.demo", version: "1.0", buildVersion: "10") }).isEmpty)
    let detected = await StoreUpdateDetector.updates(records: [legacy], sources: [sources[0]], packageMetadata: { _ in .init(bundleIdentifier: "com.publisher.demo", version: "1.0", buildVersion: "10") })
    #expect(detected.first?.bundleIdentifier == "com.publisher.demo")
    #expect(await StoreUpdateDetector.updates(records: [legacy], sources: [sources[0]], packageMetadata: { _ in .init(bundleIdentifier: "com.unrelated.app", version: "1.0", buildVersion: "10") }).isEmpty)
    let oldBuildRecord = updateRecord(version: "2.0", build: nil)
    let buildUpdate = await StoreUpdateDetector.updates(records: [oldBuildRecord], sources: [sources[0]],
        packageMetadata: { _ in .init(bundleIdentifier: "com.publisher.demo", version: "2.0", buildVersion: "19") })
    #expect(buildUpdate.first?.installedBuildVersion == "19")
    #expect(buildUpdate.first?.buildVersion == "20")
}

@Test @MainActor func updatesMatchGitHubBranchAliasesWithoutChangingPublishers() async throws {
    let shortURL = AppSourceService.kazumiSourceURL
    let explicitURL = shortURL.replacingOccurrences(of: "/kazumi/generated/", with: "/refs/heads/kazumi/generated/")
    let source = try updateSource(shortURL, version: "2.3.9")
    let record = updateRecord(version: "2.3.8", build: "20308", sourceURL: explicitURL)
    let updates = await StoreUpdateDetector.updates(records: [record], sources: [source])
    #expect(updates.count == 1)
    #expect(updates.first?.installedVersion == "2.3.8")
    #expect(updates.first?.version == "2.3.9")
    #expect(updates.first?.sourceURL == shortURL)
    let explicitSource = try updateSource(explicitURL, version: "2.3.9")
    #expect(await StoreUpdateDetector.updates(records: [updateRecord(sourceURL: shortURL)], sources: [explicitSource]).count == 1)
    // Keeping both spellings subscribed must not make a pinned install ambiguous.
    #expect(await StoreUpdateDetector.updates(records: [record], sources: [source, explicitSource]).count == 1)
    for unrelated in [
        shortURL.replacingOccurrences(of: "/kazumi/generated/", with: "/main/generated/"),
        shortURL.replacingOccurrences(of: "/kazumi/generated/", with: "/refs/tags/kazumi/generated/"),
        shortURL.replacingOccurrences(of: "ChouChiu/", with: "another-publisher/"),
        shortURL.replacingOccurrences(of: "Kazumi-AltStore-Source/", with: "another-repository/")
    ] {
        #expect(await StoreUpdateDetector.updates(records: [record], sources: [try updateSource(unrelated)]).isEmpty)
    }
}

private final class UpdateSourceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let success = request.url?.path == "/apps.json"
        let response = HTTPURLResponse(url: request.url!, statusCode: success ? 200 : 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((success ? updateCatalog : "offline").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class UpdateHarness {
    let suite = "AutoSignTests.Updates.\(UUID().uuidString)"
    let preferences: UserDefaults
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session: URLSession
    let library: SourceLibraryModel
    var server: StoreServer!
    var records: [StoreRecord]
    var installed: [String] = []

    init(failDemo: Bool = false, sourceURL: String = updateURL, freshVersion: String = "1.5") throws {
        preferences = UserDefaults(suiteName: suite)!
        records = [updateRecord(), updateRecord("store", sourceID: "local.autosign.store", isStore: true)]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateSourceProtocol.self]
        session = URLSession(configuration: configuration)
        try AppSourceStore.save([updateSource(sourceURL, version: freshVersion)], to: preferences)
        library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = StoreServer(preferences: preferences, jobsDirectory: directory, sourceLibrary: library,
            devicesProvider: { [updateDevice] }, installExecutor: { [weak self] input, release, progress in
                guard let self, let index = self.records.firstIndex(where: { $0.sourceBundleIdentifier == input.bundleIdentifier }) else {
                    throw AutoSignError.command("Missing fixture")
                }
                progress("正在更新测试应用…")
                if failDemo && input.bundleIdentifier == "com.publisher.demo" { throw AutoSignError.command("下载测试失败") }
                let old = self.records[index]
                self.installed.append(input.bundleIdentifier)
                self.records[index] = updateRecord(old.app.id, version: release.version, build: release.buildVersion,
                    sourceID: input.bundleIdentifier, isStore: old.app.isStore)
                return Date(timeIntervalSince1970: 3_000_000)
            }, recordsProvider: { [weak self] in self?.records ?? [] })
    }
    func close() {
        preferences.removePersistentDomain(forName: suite)
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
    func call(_ path: String, method: String = "GET", body: Data = Data(), authorized: Bool = true) async -> StoreHTTPResponse {
        await server.handle(StoreHTTPRequest(method: method, path: path, headers: ["authorization": authorized ? "Bearer \(server.token)" : "bad",
            "content-type": "application/json"], body: body))
    }
    func finish(_ id: String) async throws -> RefreshJob {
        for _ in 0..<100 {
            let response = await call("/v1/jobs/\(id)")
            let job = try StoreJSON.decoder().decode(RefreshJob.self, from: response.body)
            if job.state.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AutoSignError.command("Timed out waiting for update test")
    }
}

@Test @MainActor func scheduledChecksPersistAcrossRestartThrottleAndKeepFailuresVisible() async throws {
    let harness = try UpdateHarness()
    defer { harness.close() }
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(await harness.server.checkSourcesIfDue(at: now))
    #expect(harness.library.lastCheckedAt == now)
    #expect(harness.library.sources[0].catalog.apps[0].latestVersion?.version == "2.0")
    #expect(!(await harness.server.checkSourcesIfDue(at: now.addingTimeInterval(1_799))))
    let reopened = SourceLibraryModel(preferences: harness.preferences, service: AppSourceService(session: harness.session))
    #expect(!(await reopened.checkSourcesIfDue(at: now.addingTimeInterval(1_799))))
    #expect(await reopened.checkSourcesIfDue(at: now.addingTimeInterval(1_800)))
    reopened.automaticChecks = false
    #expect(!(await reopened.checkSourcesIfDue(at: now.addingTimeInterval(9_000))))
    #expect(!SourceLibraryModel(preferences: harness.preferences).automaticChecks)
    try AppSourceStore.save([updateSource("https://updates.test/offline.json")], to: harness.preferences)
    let failing = SourceLibraryModel(preferences: harness.preferences, service: AppSourceService(session: harness.session))
    await failing.refreshSources(checkedAt: now)
    #expect(failing.sources[0].updatedAt == now)
    #expect(failing.sourceErrors.values.first?.contains("503") == true)
    #expect(SourceLibraryModel(preferences: harness.preferences).sourceErrors.values.first?.contains("503") == true)
}

@Test @MainActor func updateAPIIsAuthenticatedPersistsTasksOrdersSelfLastAndClearsSuccessfulUpdates() async throws {
    let harness = try UpdateHarness()
    defer { harness.close() }
    for path in ["/v1/updates", "/v1/updates/check"] {
        #expect(await harness.call(path, method: "POST", authorized: false).status == 401)
    }
    let checked = await harness.call("/v1/updates/check", method: "POST")
    let snapshot = try StoreJSON.decoder().decode(StoreSnapshot.self, from: checked.body)
    #expect(snapshot.capabilities?.contains("updates") == true)
    #expect(snapshot.availableUpdates?.count == 2)
    #expect(snapshot.sourceCheck?.checkedAt != nil)
    let input = RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["store", "demo"])
    let response = await harness.call("/v1/updates", method: "POST", body: try StoreJSON.encoder().encode(input))
    #expect(response.status == 202)
    let job = try StoreJSON.decoder().decode(RefreshJob.self, from: response.body)
    #expect(job.items.map(\.id) == ["demo", "store"])
    #expect(job.updateRequest?.requestID == input.requestID)
    let disk = try StoreJSON.decoder().decode([RefreshJob].self, from: Data(contentsOf: harness.directory.appendingPathComponent("jobs.json")))
    #expect(disk.first?.state == .queued)
    #expect(harness.installed.isEmpty)
    #expect(!(await harness.server.checkSourcesIfDue(at: Date().addingTimeInterval(4_000))))
    #expect(try await harness.server.submitUpdates(input).id == job.id)
    #expect(await harness.call("/v1/updates/check", method: "POST").status == 409)
    let result = try await harness.finish(job.id)
    #expect(result.state == .completed)
    #expect(harness.installed == ["com.publisher.demo", "local.autosign.store"])
    #expect(result.items[0].message.contains("2.0 (20)"))
    let after = await harness.call("/v1/status")
    #expect(try StoreJSON.decoder().decode(StoreSnapshot.self, from: after.body).availableUpdates?.isEmpty == true)
    let restarted = StoreServer(preferences: harness.preferences, jobsDirectory: harness.directory)
    #expect(try await restarted.submitUpdates(input).id == job.id)
    #expect(harness.installed.count == 2)
}

@Test @MainActor func statusOffersUpdatesForAnInstalledGitHubBranchAlias() async throws {
    let shortURL = AppSourceService.kazumiSourceURL
    let harness = try UpdateHarness(sourceURL: shortURL, freshVersion: "2.3.9")
    defer { harness.close() }
    harness.records = [updateRecord(version: "2.3.8", build: "20308",
        sourceURL: shortURL.replacingOccurrences(of: "/kazumi/generated/", with: "/refs/heads/kazumi/generated/"))]
    let snapshot = try StoreJSON.decoder().decode(StoreSnapshot.self, from: await harness.call("/v1/status").body)
    #expect(snapshot.availableUpdates?.count == 1)
    #expect(snapshot.availableUpdates?.first?.version == "2.3.9")
    #expect(snapshot.availableUpdates?.first?.sourceURL == shortURL)
}

@Test @MainActor func macUpdateIndicatorsFollowTheSelectedDeviceAndRefreshedSources() async throws {
    let suite = "AutoSignTests.MacUpdates.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let shortURL = AppSourceService.kazumiSourceURL
    try AppSourceStore.save([updateSource(shortURL, version: "2.3.9")], to: preferences)
    let library = SourceLibraryModel(preferences: preferences)
    let records = [updateRecord(version: "2.3.8", sourceURL: shortURL.replacingOccurrences(of: "/kazumi/generated/", with: "/refs/heads/kazumi/generated/")),
                   updateRecord("tablet-demo", device: "tablet", version: "2.3.9", build: "20", sourceURL: shortURL)]
    let model = AppModel(performInitialRefresh: false, preferences: preferences, sourceLibrary: library,
                         dependencies: .init(records: { records }))
    model.updateDevices([updateDevice])
    await model.refreshAvailableUpdates()
    #expect(model.availableUpdates.map(\.id) == ["demo"])
    #expect(model.availableUpdates.first?.version == "2.3.9")
    try library.removeSource(shortURL)
    await model.refreshAvailableUpdates()
    #expect(model.availableUpdates.isEmpty)
    try AppSourceStore.save([updateSource(shortURL, version: "2.3.9")], to: preferences)
    let reopened = AppModel(performInitialRefresh: false, preferences: preferences,
        sourceLibrary: SourceLibraryModel(preferences: preferences), dependencies: .init(records: { records }))
    reopened.updateDevices([updateDevice])
    await reopened.refreshAvailableUpdates()
    #expect(reopened.availableUpdates.count == 1)
    let tablet = AppleDevice(id: "tablet", udid: "tablet", name: "Tablet", marketingName: "iPad", kind: .iPad,
        osVersion: "17.0", isPaired: true, developerModeEnabled: true, isConnected: true)
    reopened.updateDevices([tablet])
    #expect(reopened.availableUpdates.isEmpty)
    preferences.set("tablet", forKey: AppModel.selectedDevicePreferenceKey)
    reopened.updateDevices([updateDevice, tablet])
    await reopened.refreshAvailableUpdates()
    #expect(reopened.selectedDevice?.udid == "tablet")
    #expect(reopened.availableUpdates.isEmpty)
}

@Test @MainActor func partialUpdateFailureKeepsFailedAppAvailableAndContinuesWithStore() async throws {
    let harness = try UpdateHarness(failDemo: true)
    defer { harness.close() }
    let job = try await harness.server.submitUpdates(RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["store", "demo"]))
    let result = try await harness.finish(job.id)
    #expect(result.state == .failed)
    #expect(result.items[0].state == .failed)
    #expect(result.items[0].expiration == nil)
    #expect(result.items[1].state == .completed)
    let snapshot = try StoreJSON.decoder().decode(StoreSnapshot.self, from: await harness.call("/v1/status").body)
    #expect(snapshot.availableUpdates?.map(\.id) == ["demo"])
}

@Test @MainActor func freshSourceFailureNeverUsesCachedReleaseForUpdate() async throws {
    let harness = try UpdateHarness(sourceURL: "https://updates.test/offline.json")
    defer { harness.close() }
    harness.records = [updateRecord(sourceURL: "https://updates.test/offline.json")]
    let job = try await harness.server.submitUpdates(RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["demo"]))
    let result = try await harness.finish(job.id)
    #expect(result.state == .failed)
    #expect(result.items[0].message.contains("503"))
    #expect(harness.installed.isEmpty)
}

@Test @MainActor func changedSourceDoesNotDowngradeOrReinstallAnAlreadyCurrentApp() async throws {
    let harness = try UpdateHarness(freshVersion: "9.0")
    defer { harness.close() }
    harness.records = [updateRecord(version: "3.0")]
    let job = try await harness.server.submitUpdates(RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["demo"]))
    let result = try await harness.finish(job.id)
    #expect(result.state == .completed)
    #expect(result.items[0].message.contains((AppLanguage.current == .english ? "No update needed" : "无需更新")))
    #expect(harness.installed.isEmpty)
}

@Test @MainActor func updatePlannerRejectsWrongDevicesMissingUpdatesAndRequestCollisions() async throws {
    let records = [updateRecord()]
    let updates = await StoreUpdateDetector.updates(records: records, sources: [try updateSource()])
    let input = RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["demo"])
    let plan = try StoreJobPlanner.planUpdates(input, records: records, updates: updates, jobs: [], isBusy: false)
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.plan(input, records: records, jobs: [plan.job], isBusy: false) }
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.planUpdates(input, records: records, updates: [], jobs: [], isBusy: false) }
    let other = RefreshRequest(requestID: input.requestID, deviceUDID: "ipad", appIDs: ["demo"])
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.planUpdates(other, records: records, updates: updates, jobs: [], isBusy: false) }
    #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.existingUpdate(other, jobs: [plan.job]) }
    let recovered = StoreJobPlanner.recoverInterrupted([plan.job])[0]
    #expect(recovered.state == .failed)
    #expect(recovered.updateRequest?.requestID == input.requestID)
}

@Test @MainActor func rejectsIPAWithWrongAdvertisedVersionOrBuild() throws {
    let release = try #require(updateSource().catalog.apps[0].latestVersion)
    try StoreInstallService.validateRelease(.init(bundleIdentifier: "com.publisher.demo", version: "2.0", buildVersion: "20"), version: release)
    #expect(throws: AppSourceError.self) {
        try StoreInstallService.validateRelease(.init(bundleIdentifier: "com.publisher.demo", version: "1.0", buildVersion: "20"), version: release)
    }
    #expect(throws: AppSourceError.self) {
        try StoreInstallService.validateRelease(.init(bundleIdentifier: "com.publisher.demo", version: "2.0", buildVersion: "19"), version: release)
    }
}
