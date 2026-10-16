import AutoSignLocalization
import Foundation

/// Temporarily removes only eligible profiles for this team/bundle, following Apple's automatic-signing guidance.
/// A disk journal lets the next run recover the cache after a process interruption.
enum ProvisioningProfileCache {
    struct Entry: Codable, Sendable {
        let original: URL
        let backupName: String
        let sharedWildcard: Bool
    }

    struct Lease: Sendable {
        let directory: URL
        let entries: [Entry]
        let cacheFolders: [URL]

        func rollback() throws { try finish(success: false) }
        func commit() throws { try finish(success: true) }

        private func finish(success: Bool) throws {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            for entry in entries {
                guard cacheFolders.map(\.standardizedFileURL).contains(entry.original.deletingLastPathComponent().standardizedFileURL),
                      entry.original.pathExtension.lowercased() == "mobileprovision",
                      entry.backupName.range(of: #"^[0-9]+\.mobileprovision$"#, options: .regularExpression) != nil else {
                    throw AutoSignError.command(L10n.tr("描述文件缓存恢复记录无效，已保留备份供检查。"))
                }
                let backup = directory.appendingPathComponent(entry.backupName)
                if (!success || entry.sharedWildcard),
                   FileManager.default.fileExists(atPath: backup.path),
                   !FileManager.default.fileExists(atPath: entry.original.path) {
                    try FileManager.default.copyItem(at: backup, to: entry.original)
                }
            }
            try FileManager.default.removeItem(at: directory)
        }
    }

    static var defaultFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
                home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")]
    }

    static func isolate(teamID: String, bundleID: String, backupRoot: URL,
                        cacheFolders: [URL] = defaultFolders,
                        readProfile: @Sendable (URL) async throws -> ProvisioningProfile = { try await SigningService.readProfile(at: $0) }) async throws -> Lease {
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try recoverInterrupted(in: backupRoot, cacheFolders: cacheFolders)
        var candidates: [(URL, ProvisioningProfile)] = []
        for folder in cacheFolders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
            for file in files where file.pathExtension.lowercased() == "mobileprovision" {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let profile = try? await readProfile(file), profile.teamIdentifier == teamID,
                      SigningService.profileSupports(profile.applicationIdentifier, bundleID: bundleID) else { continue }
                candidates.append((file, profile))
            }
        }
        let directory = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let entries = candidates.enumerated().map { index, item in
            Entry(original: item.0, backupName: "\(index).mobileprovision", sharedWildcard: item.1.applicationIdentifier.contains("*"))
        }
        let lease = Lease(directory: directory, entries: entries, cacheFolders: cacheFolders)
        do {
            // Copy and journal every original before removing any cache file.
            for entry in entries { try FileManager.default.copyItem(at: entry.original, to: directory.appendingPathComponent(entry.backupName)) }
            try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            for entry in entries {
                guard FileManager.default.contentsEqual(atPath: entry.original.path, andPath: directory.appendingPathComponent(entry.backupName).path) else {
                    throw AutoSignError.command(L10n.tr("Xcode 的描述文件缓存正在变化，请稍后重试续签。"))
                }
                try FileManager.default.removeItem(at: entry.original)
            }
            return lease
        } catch {
            try? lease.rollback()
            throw error
        }
    }

    static func recoverInterrupted(in backupRoot: URL, cacheFolders: [URL] = defaultFolders) throws {
        let directories = (try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            let manifest = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifest))
            try Lease(directory: directory, entries: entries, cacheFolders: cacheFolders).rollback()
        }
    }
}
