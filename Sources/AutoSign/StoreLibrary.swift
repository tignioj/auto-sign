import Darwin
import Foundation

struct StoreRecord: Codable, Sendable {
    var app: StoreApp
    let ipaPath: String
    let profilePath: String
    var identityID: String
    var teamIdentifier: String? = nil
    var sourceBundleIdentifier: String? = nil
    var sourceURL: String? = nil
    var signedEntitlements: Data? = nil
    var extensionBundleIdentifiers: [String]? = nil
}

/// Shared with the existing launchd process. The flock protects read/modify/write across processes.
enum StoreLibrary {
    static func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("AutoSign/Store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    static func records() throws -> [StoreRecord] {
        try withLock { try readUnlocked() }
    }

    static func recordInstall(ipa: URL, profileURL: URL, identity: SigningIdentity,
                              device: AppleDevice, bundle: URL, expiration: Date, teamIdentifier: String,
                              sourceBundleIdentifier: String? = nil, sourceURL: String? = nil,
                              signedEntitlements: Data? = nil, extensionBundleIdentifiers: [String]? = nil) throws {
        let data = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw AutoSignError.invalidIPA("无法记录应用标识。")
        }
        try withLock {
            var records = try readUnlocked()
            let existing = records.first { $0.app.deviceUDID == device.udid && $0.app.bundleIdentifier == bundleID }
            let id = existing?.app.id ?? UUID().uuidString
            let folder = try directory().appendingPathComponent("Packages/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let savedIPA = folder.appendingPathComponent("original.ipa")
            let savedProfile = folder.appendingPathComponent("profile.mobileprovision")
            try copyIfDifferent(ipa, to: savedIPA)
            try copyIfDifferent(profileURL, to: savedProfile)
            let app = StoreApp(id: id, deviceUDID: device.udid,
                               name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID,
                               bundleIdentifier: bundleID, version: info["CFBundleShortVersionString"] as? String ?? "1.0",
                               expiration: expiration, refreshedAt: Date(), isStore: info["AutoSignStoreClient"] as? Bool == true,
                               buildVersion: info["CFBundleVersion"] as? String)
            records.removeAll { $0.app.id == id }
            records.append(StoreRecord(app: app, ipaPath: savedIPA.path, profilePath: savedProfile.path,
                                       identityID: identity.id, teamIdentifier: teamIdentifier,
                                       sourceBundleIdentifier: sourceBundleIdentifier ?? existing?.sourceBundleIdentifier,
                                       sourceURL: sourceURL ?? existing?.sourceURL,
                                       signedEntitlements: signedEntitlements,
                                       extensionBundleIdentifiers: extensionBundleIdentifiers))
            try StoreJSON.encoder().encode(records).write(to: try directory().appendingPathComponent("library.json"), options: .atomic)
        }
    }

    static func recordProfileRefresh(_ previous: StoreRecord, profileURL: URL, expiration: Date) throws {
        try withLock {
            var records = try readUnlocked()
            guard let index = records.firstIndex(where: { $0.app.id == previous.app.id }),
                  records[index].app.refreshedAt == previous.app.refreshedAt,
                  records[index].identityID == previous.identityID else {
                throw AutoSignError.command("原应用记录已变化，请重新同步后再续签。")
            }
            let app = records[index].app
            try copyIfDifferent(profileURL, to: URL(fileURLWithPath: records[index].profilePath))
            records[index].app = StoreApp(id: app.id, deviceUDID: app.deviceUDID, name: app.name,
                bundleIdentifier: app.bundleIdentifier, version: app.version, expiration: expiration,
                refreshedAt: Date(), isStore: app.isStore, buildVersion: app.buildVersion)
            records[index].signedEntitlements = previous.signedEntitlements
            records[index].extensionBundleIdentifiers = previous.extensionBundleIdentifiers
            try StoreJSON.encoder().encode(records).write(to: try directory().appendingPathComponent("library.json"), options: .atomic)
        }
    }

    private static func copyIfDifferent(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func readUnlocked() throws -> [StoreRecord] {
        let url = try directory().appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try StoreJSON.decoder().decode([StoreRecord].self, from: Data(contentsOf: url))
    }

    private static func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(try directory().appendingPathComponent("library.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw AutoSignError.command("无法打开应用库锁。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AutoSignError.command("无法锁定应用库。") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// Avoid simultaneous Xcode provisioning or signing between GUI, LAN requests and launchd.
final class SigningOperationLock: @unchecked Sendable {
    private let descriptor: Int32
    init() throws {
        let opened = open(try StoreLibrary.directory().appendingPathComponent("signing.lock").path, O_CREAT | O_RDWR, 0o600)
        guard opened >= 0 else { throw AutoSignError.command("无法打开签名锁。") }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            throw AutoSignError.command("Mac 正在执行另一个签名任务，请稍后重试。")
        }
        descriptor = opened
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
