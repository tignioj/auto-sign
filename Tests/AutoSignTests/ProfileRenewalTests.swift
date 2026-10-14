import Foundation
import Testing
@testable import AutoSign

private func renewalProfile(uuid: String = "new", team: String = "TEAM", app: String = "com.example.app",
                            created: Date, duration: TimeInterval = 7 * 86_400,
                            devices: Set<String> = ["phone"]) -> ProvisioningProfile {
    ProvisioningProfile(name: "Test", uuid: uuid, expirationDate: created.addingTimeInterval(duration),
        applicationIdentifier: "\(team).\(app)", teamIdentifier: team, provisionedDevices: devices,
        provisionsAllDevices: false, entitlements: [:], creationDate: created, timeToLiveDays: 7)
}

@Test func freshSevenDayProfileIsAcceptedButCachedOrShortProfileIsRejected() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let old = renewalProfile(uuid: "old", created: now.addingTimeInterval(-86_400))
    let fresh = renewalProfile(created: now)
    try ProfileRenewalPolicy.validate(original: old, renewed: fresh, bundleID: "com.example.app", deviceUDID: "phone", requestedAt: now, now: now.addingTimeInterval(25))
    let invalid = [
        old,
        renewalProfile(uuid: "old", created: now),
        renewalProfile(created: now.addingTimeInterval(-3600)),
        renewalProfile(created: now, duration: 6 * 86_400),
        renewalProfile(team: "OTHER", created: now),
        renewalProfile(app: "other.app", created: now),
        renewalProfile(created: now, devices: ["other-phone"]),
        renewalProfile(created: now.addingTimeInterval(3600))
    ]
    for profile in invalid {
        #expect(throws: AutoSignError.self) {
            try ProfileRenewalPolicy.validate(original: old, renewed: profile, bundleID: "com.example.app", deviceUDID: "phone", requestedAt: now, now: now)
        }
    }
}

@Test func insufficientRemainingTimeAndMissingIssueDateAreRejected() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let old = renewalProfile(uuid: "old", created: now.addingTimeInterval(-86_400))
    let fresh = renewalProfile(created: now)
    #expect(throws: AutoSignError.self) {
        try ProfileRenewalPolicy.validate(original: old, renewed: fresh, bundleID: "com.example.app", deviceUDID: "phone", requestedAt: now, now: now.addingTimeInterval(601))
    }
    var missing = fresh
    missing.creationDate = nil
    #expect(throws: AutoSignError.self) {
        try ProfileRenewalPolicy.validate(original: old, renewed: missing, bundleID: "com.example.app", deviceUDID: "phone", requestedAt: now, now: now)
    }
}

private struct CacheFixture {
    let root: URL
    let cache: URL
    let backups: URL
    let profiles: [String: ProvisioningProfile]
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = root.appendingPathComponent("cache")
        backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let now = Date()
        profiles = [
            "target.mobileprovision": renewalProfile(created: now),
            "shared.mobileprovision": renewalProfile(uuid: "shared", app: "com.example.*", created: now),
            "other-app.mobileprovision": renewalProfile(uuid: "other", app: "unrelated.app", created: now),
            "other-team.mobileprovision": renewalProfile(uuid: "other-team", team: "OTHER", created: now)
        ]
        for name in profiles.keys { try Data(name.utf8).write(to: cache.appendingPathComponent(name)) }
        try Data("unknown".utf8).write(to: cache.appendingPathComponent("unreadable.mobileprovision"))
    }
    func isolate() async throws -> ProvisioningProfileCache.Lease {
        let values = profiles
        return try await ProvisioningProfileCache.isolate(teamID: "TEAM", bundleID: "com.example.app", backupRoot: backups, cacheFolders: [cache]) { url in
            guard let profile = values[url.lastPathComponent] else { throw AutoSignError.invalidProfile("Unreadable fixture") }
            return profile
        }
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: cache.appendingPathComponent(name).path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func isolatesOnlyEligibleTeamAndAppAndRollsBackWithoutChangingOriginalBytes() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let lease = try await fixture.isolate()
    #expect(lease.entries.count == 2)
    #expect(!fixture.exists("target.mobileprovision"))
    #expect(!fixture.exists("shared.mobileprovision"))
    #expect(fixture.exists("other-app.mobileprovision"))
    #expect(fixture.exists("other-team.mobileprovision"))
    #expect(fixture.exists("unreadable.mobileprovision"))
    try lease.rollback()
    #expect(try Data(contentsOf: fixture.cache.appendingPathComponent("target.mobileprovision")) == Data("target.mobileprovision".utf8))
    #expect(fixture.exists("shared.mobileprovision"))
    #expect(!FileManager.default.fileExists(atPath: lease.directory.path))
}

@Test func successDiscardsStaleExactCacheAndRestoresSharedWildcardWithoutOverwritingNewCache() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let lease = try await fixture.isolate()
    let new = fixture.cache.appendingPathComponent("new.mobileprovision")
    try Data("newly issued profile".utf8).write(to: new)
    try lease.commit()
    #expect(!fixture.exists("target.mobileprovision"))
    #expect(fixture.exists("shared.mobileprovision"))
    #expect(try Data(contentsOf: new) == Data("newly issued profile".utf8))
    try lease.rollback() // The deferred rollback is harmless after a commit.
    #expect(!fixture.exists("target.mobileprovision"))
}

@Test func nextRunRecoversInterruptedCacheTransactionFromDisk() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    _ = try await fixture.isolate()
    #expect(!fixture.exists("target.mobileprovision"))
    try ProvisioningProfileCache.recoverInterrupted(in: fixture.backups, cacheFolders: [fixture.cache])
    #expect(fixture.exists("target.mobileprovision"))
    #expect(fixture.exists("shared.mobileprovision"))
    #expect(try FileManager.default.contentsOfDirectory(at: fixture.backups, includingPropertiesForKeys: nil).isEmpty)
}

@Test func recoveryNeverOverwritesProfileWrittenByXcodeDuringTheTransaction() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let lease = try await fixture.isolate()
    let destination = fixture.cache.appendingPathComponent("target.mobileprovision")
    try Data("Xcode replacement".utf8).write(to: destination)
    try lease.rollback()
    #expect(try Data(contentsOf: destination) == Data("Xcode replacement".utf8))
}

@Test func recoveryRejectsManifestPathsOutsideTheKnownProfileCaches() throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let transaction = fixture.backups.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
    try Data("private backup".utf8).write(to: transaction.appendingPathComponent("0.mobileprovision"))
    let outside = fixture.root.appendingPathComponent("outside.mobileprovision")
    let entries = [ProvisioningProfileCache.Entry(original: outside, backupName: "0.mobileprovision", sharedWildcard: false)]
    try JSONEncoder().encode(entries).write(to: transaction.appendingPathComponent("manifest.json"))
    #expect(throws: AutoSignError.self) {
        try ProvisioningProfileCache.recoverInterrupted(in: fixture.backups, cacheFolders: [fixture.cache])
    }
    #expect(!FileManager.default.fileExists(atPath: outside.path))
    #expect(FileManager.default.fileExists(atPath: transaction.appendingPathComponent("0.mobileprovision").path))
}
