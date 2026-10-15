import Foundation
import Testing
@testable import AutoSign

@MainActor private func networkPreferences() throws -> (String, UserDefaults) {
    let name = "AutoSignTests.LocalNetwork.\(UUID().uuidString)"
    return (name, try #require(UserDefaults(suiteName: name)))
}

@Test @MainActor func foregroundNetworkCheckRecordsOnlyAConfirmedCurrentExecutable() async throws {
    let (suite, preferences) = try networkPreferences()
    defer { preferences.removePersistentDomain(forName: suite) }
    let access = LocalNetworkAccess(preferences: preferences, required: true, identity: { "current-build" }, probe: { .ready })
    #expect(access.state == .notChecked)
    #expect(!LocalNetworkPreparation.isPrepared(preferences: preferences, identity: "current-build", required: true))
    #expect(await access.check())
    #expect(access.state == .ready)
    #expect(LocalNetworkPreparation.isPrepared(preferences: preferences, identity: "current-build", required: true))
    #expect(!LocalNetworkPreparation.isPrepared(preferences: preferences, identity: "updated-build", required: true))
    #expect(!LocalNetworkPreparation.isPrepared(preferences: preferences, identity: nil, required: true))
}

@Test(arguments: [LocalNetworkAccess.State.needsPermission, .unavailable, .cancelled])
@MainActor func inconclusiveNetworkChecksNeverAuthorizeBackgroundActivation(result: LocalNetworkAccess.State) async throws {
    let (suite, preferences) = try networkPreferences()
    defer { preferences.removePersistentDomain(forName: suite) }
    let access = LocalNetworkAccess(preferences: preferences, required: true, identity: { "build" }, probe: { result })
    #expect(!(await access.check()))
    #expect(access.state == result)
    #expect(!LocalNetworkPreparation.isPrepared(preferences: preferences, identity: "build", required: true))
}

@Test @MainActor func deniedNetworkCheckInvalidatesAnEarlierForegroundPreparation() async throws {
    let (suite, preferences) = try networkPreferences()
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("build", forKey: LocalNetworkPreparation.preferenceKey)
    let access = LocalNetworkAccess(preferences: preferences, required: true, identity: { "build" }, probe: { .needsPermission })
    #expect(!(await access.check()))
    #expect(!LocalNetworkPreparation.isPrepared(preferences: preferences, identity: "build", required: true))
}

@Test @MainActor func concurrentForegroundRequestsShareOneProbeAndBothWaitForTheReceipt() async throws {
    let (suite, preferences) = try networkPreferences()
    defer { preferences.removePersistentDomain(forName: suite) }
    var probes = 0
    let access = LocalNetworkAccess(preferences: preferences, required: true, identity: { "build" }, probe: {
        probes += 1
        await Task.yield()
        return .ready
    })
    let first = Task { await access.check() }
    let second = Task { await access.check() }
    #expect(await first.value)
    #expect(await second.value)
    #expect(probes == 1)
    #expect(LocalNetworkPreparation.isPrepared(preferences: preferences, identity: "build", required: true))
}

@Test @MainActor func cancelledProbeCannotWriteAStaleSuccessReceipt() async throws {
    let (suite, preferences) = try networkPreferences()
    defer { preferences.removePersistentDomain(forName: suite) }
    var completion: CheckedContinuation<LocalNetworkAccess.State, Never>?
    let access = LocalNetworkAccess(preferences: preferences, required: true, identity: { "build" }, probe: {
        await withCheckedContinuation { completion = $0 }
    })
    let request = Task { await access.check() }
    while completion == nil { await Task.yield() }
    access.cancel()
    completion?.resume(returning: .ready)
    #expect(!(await request.value))
    #expect(access.state == .cancelled)
    #expect(!LocalNetworkPreparation.isPrepared(preferences: preferences, identity: "build", required: true))
}

@Test @MainActor func macOSWithoutLocalNetworkPrivacyDoesNotRunAnAuthorizationProbe() async throws {
    let (suite, preferences) = try networkPreferences()
    defer { preferences.removePersistentDomain(forName: suite) }
    let access = LocalNetworkAccess(preferences: preferences, required: false, probe: {
        Issue.record("macOS 14 needs no local network privacy prompt")
        return .unavailable
    })
    #expect(await access.check())
    #expect(LocalNetworkPreparation.isPrepared(preferences: preferences, identity: nil, required: false))
}

@Test func foregroundPreparationTracksContentAndLocationInsteadOfVersionNumber() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSignNetworkIdentity-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("AutoSign")
    let moved = root.appendingPathComponent("AutoSign-Moved")
    try Data("build-one".utf8).write(to: app)
    let first = try #require(LocalNetworkPreparation.executableIdentity(url: app, bundleID: "test"))
    try Data("build-two".utf8).write(to: app)
    let second = try #require(LocalNetworkPreparation.executableIdentity(url: app, bundleID: "test"))
    try FileManager.default.copyItem(at: app, to: moved)
    #expect(first != second)
    #expect(LocalNetworkPreparation.executableIdentity(url: moved, bundleID: "test") != second)
}

@Test func launchAgentAssociatesForegroundAppAndMigratesLegacyLaunchers() {
    let app = URL(fileURLWithPath: "/Applications/AutoSign.app/Contents/MacOS/AutoSign")
    let logs = URL(fileURLWithPath: "/logs")
    let current = BackgroundRefreshManager.configuration(executable: app, logs: logs, bundleID: "local.autosign.desktop")
    #expect(current["AssociatedBundleIdentifiers"] as? [String] == ["local.autosign.desktop"])
    #expect(!BackgroundRefreshManager.requiresMigration(current, executable: app, bundleID: "local.autosign.desktop"))
    var legacy = current
    legacy.removeValue(forKey: "AssociatedBundleIdentifiers")
    #expect(BackgroundRefreshManager.requiresMigration(legacy, executable: app, bundleID: "local.autosign.desktop"))
    legacy = current
    legacy["ProgramArguments"] = ["/usr/bin/open", "-n", "-g", "/old/AutoSign.app", "--args", "--background-refresh"]
    #expect(BackgroundRefreshManager.requiresMigration(legacy, executable: app, bundleID: "local.autosign.desktop"))
}
