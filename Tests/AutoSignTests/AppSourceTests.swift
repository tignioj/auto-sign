import AutoSignLocalization
import Foundation
import Testing
@testable import AutoSign

private let sourceFixture = #"""
{
  "name": "Test Source",
  "iconURL": "https://source.test/icon.png",
  "apps": [{
    "name": "Kazumi",
    "bundleIdentifier": "com.example.kazumi",
    "developerName": "Predidit",
    "localizedDescription": "测试应用",
    "iconURL": "https://source.test/icon.png",
    "screenshots": {"iphone": ["https://source.test/screenshot.png"], "ipad": []},
    "appPermissions": {"entitlements": [], "privacy": {}},
    "versions": [
      {"version": "2.3.8", "buildVersion": "20308", "date": "2026-10-07T03:41:05.000Z",
       "downloadURL": "https://source.test/Kazumi.ipa", "size": 30463104, "minOSVersion": "13.0"},
      {"version": "9.0", "date": "2026-10-08", "downloadURL": "https://source.test/older.ipa", "size": 1}
    ]
  }]
}
"""#

@Test func sourceUsesPublishedOrderAndIgnoresExtraMetadata() throws {
    let source = try AppSourceService.parseCatalog(Data(sourceFixture.utf8))
    let app = try #require(source.apps.first)
    #expect(source.name == "Test Source")
    #expect(app.id == "com.example.kazumi")
    #expect(app.latestVersion?.displayVersion == "2.3.8 (20308)")
    #expect(app.latestVersion?.size == 30_463_104)
    #expect(app.latestVersion?.minOSVersion == "13.0")
}

@Test func supportsLegacySingleVersionSource() throws {
    let json = #"{"name":"Legacy","apps":[{"name":"Demo","bundleIdentifier":"app.demo","version":"1.2","versionDate":"2020-11-13","versionDescription":"修复错误","downloadURL":"https://source.test/demo.ipa","size":123}]}"#
    let app = try #require(AppSourceService.parseCatalog(Data(json.utf8)).apps.first)
    #expect(app.latestVersion?.version == "1.2")
    #expect(app.latestVersion?.date == "2020-11-13")
    #expect(app.latestVersion?.localizedDescription == "修复错误")
}

@Test func rejectsInvalidSourcesAndDuplicateBundleIdentifiers() throws {
    for invalid in [
        "<html>Not a source</html>",
        #"{"name":" ","apps":[]}"#,
        #"{"name":"Invalid","apps":[{"name":"Demo","bundleIdentifier":"","versions":[]}]}"#,
        #"{"name":"Invalid","apps":[{"name":"One","bundleIdentifier":"app.demo","versions":[]},{"name":"Two","bundleIdentifier":"app.demo","versions":[]}]}"#
    ] {
        #expect(throws: AppSourceError.self) { try AppSourceService.parseCatalog(Data(invalid.utf8)) }
    }
    let empty = try AppSourceService.parseCatalog(Data(#"{"name":"Empty","apps":[]}"#.utf8))
    #expect(empty.apps.isEmpty)
}

@Test func normalizesSourceAddressesAndRejectsNonWebURLs() throws {
    let url = try AppSourceService.sourceURL(from: " \nHTTPS://SOURCE.test:443/catalog.json#ignored \n")
    #expect(url.absoluteString == "https://source.test/catalog.json")
    #expect(try AppSourceService.sourceURL(from: "http://localhost:8000/apps.json").host == "localhost")
    for invalid in ["", "source.test/apps.json", "file:///tmp/apps.json", "ftp://source.test/apps.json", "https://user:password@source.test/apps.json"] {
        #expect(throws: AppSourceError.self) { try AppSourceService.sourceURL(from: invalid) }
    }
}

@Test func sourceStoreRestoresCatalogAndLastRefresh() throws {
    let suite = "AutoSignTests.Sources.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let date = Date(timeIntervalSince1970: 1_000_000)
    let source = SavedAppSource(
        url: URL(string: "https://source.test/catalog.json")!,
        catalog: try AppSourceService.parseCatalog(Data(sourceFixture.utf8)), updatedAt: date
    )
    try AppSourceStore.save([source], to: preferences)
    let restored = try #require(AppSourceStore.load(from: preferences).first)
    #expect(restored.id == source.id)
    #expect(restored.updatedAt == date)
    #expect(restored.catalog.apps.first?.latestVersion?.version == "2.3.8")
    try AppSourceStore.save([], to: preferences)
    #expect(AppSourceStore.load(from: preferences).isEmpty)
}

private final class SourceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let success = request.url?.path == "/catalog.json"
        let response = HTTPURLResponse(url: request.url!, statusCode: success ? 200 : 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((success ? sourceFixture : "Not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func sourceTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SourceURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Test @MainActor func addsDeduplicatesAndRemovesSourcesPersistently() async throws {
    let suite = "AutoSignTests.SourceLibrary.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let session = sourceTestSession()
    defer { session.invalidateAndCancel() }
    let library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
    await library.addSource("https://source.test/catalog.json")
    #expect(library.sources.count == 1)
    #expect(library.selectedSource?.catalog.name == "Test Source")
    #expect(!library.isBusy)
    await library.addSource("https://SOURCE.test:443/catalog.json#duplicate")
    #expect(library.sources.count == 1)
    #expect(library.errorMessage?.contains((AppLanguage.current == .english ? "already been added" : "已经添加")) == true)
    let reopened = SourceLibraryModel(preferences: preferences)
    #expect(reopened.selectedSource?.catalog.apps.first?.latestVersion?.version == "2.3.8")
    library.removeSelectedSource()
    #expect(library.sources.isEmpty)
    #expect(AppSourceStore.load(from: preferences).isEmpty)
}

@Test @MainActor func failedRefreshKeepsCachedCatalogAndFailedAddDoesNotPersist() async throws {
    let suite = "AutoSignTests.FailedSource.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let session = sourceTestSession()
    defer { session.invalidateAndCancel() }
    let source = SavedAppSource(
        url: URL(string: "https://source.test/missing.json")!,
        catalog: try AppSourceService.parseCatalog(Data(sourceFixture.utf8)),
        updatedAt: Date(timeIntervalSince1970: 1_000_000)
    )
    try AppSourceStore.save([source], to: preferences)
    let library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
    await library.refreshSources()
    #expect(library.selectedSource?.updatedAt == source.updatedAt)
    #expect(library.selectedSource?.catalog.apps.count == 1)
    #expect(library.sourceErrors[source.id]?.contains("404") == true)
    await library.addSource("https://source.test/another-missing.json")
    #expect(library.sources.count == 1)
    #expect(library.errorMessage?.contains("404") == true)
    // Downloading must re-fetch successfully; the stale cached IPA URL must never be used.
    let app = try #require(library.selectedSource?.catalog.apps.first)
    #expect(await library.downloadLatest(app) == nil)
    #expect(library.errorMessage?.contains("404") == true)
    #expect(!library.isBusy)
}

@Test @MainActor func refreshReplacesCachedVersionAndPersistsIt() async throws {
    let suite = "AutoSignTests.RefreshSource.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let session = sourceTestSession()
    defer { session.invalidateAndCancel() }
    try AppSourceStore.save([SavedAppSource(
        url: URL(string: "https://source.test/catalog.json")!,
        catalog: try AppSourceService.parseCatalog(Data(sourceFixture.replacingOccurrences(of: "2.3.8", with: "2.3.0").utf8)),
        updatedAt: Date(timeIntervalSince1970: 1_000_000)
    )], to: preferences)
    let library = SourceLibraryModel(preferences: preferences, service: AppSourceService(session: session))
    await library.refreshSources()
    #expect(library.selectedSource?.catalog.apps.first?.latestVersion?.version == "2.3.8")
    #expect(AppSourceStore.load(from: preferences).first?.catalog.apps.first?.latestVersion?.version == "2.3.8")
}

@Test func validatesDownloadedIPAAndRejectsWrongSizeOrHTML() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSignSourceTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = directory.appendingPathComponent("Fixture/Payload/Demo.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.demo"], format: .xml, options: 0)
    try plist.write(to: bundle.appendingPathComponent("Info.plist"))
    let archive = directory.appendingPathComponent("Demo.ipa")
    _ = try await ProcessRunner.checked("/usr/bin/ditto", ["-c", "-k", directory.appendingPathComponent("Fixture").path, archive.path], context: "Create test IPA")
    let size = try #require(archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    try await AppSourceService.validateIPA(at: archive, expectedSize: Int64(size))
    await #expect(throws: AppSourceError.self) {
        try await AppSourceService.validateIPA(at: archive, expectedSize: Int64(size + 1))
    }
    let html = directory.appendingPathComponent("error.ipa")
    try Data("<html>Download unavailable</html>".utf8).write(to: html)
    await #expect(throws: AppSourceError.self) {
        try await AppSourceService.validateIPA(at: html, expectedSize: nil)
    }
}

@Test func integrationFetchAndDownloadSourceWhenConfigured() async throws {
    guard let input = ProcessInfo.processInfo.environment["AUTOSIGN_SOURCE_INTEGRATION_URL"] else { return }
    let service = AppSourceService()
    let catalog = try await service.fetchCatalog(at: AppSourceService.sourceURL(from: input))
    let app = try #require(catalog.apps.first)
    let version = try #require(app.latestVersion)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSignLiveSource-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try await service.download(version, to: directory)
    #expect(url.pathExtension == "ipa")
    #expect(FileManager.default.fileExists(atPath: url.path))
}
