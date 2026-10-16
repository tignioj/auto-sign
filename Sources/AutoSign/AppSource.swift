import AutoSignLocalization
import Foundation

struct AppSourceCatalog: Codable, Sendable {
    let name: String
    let apps: [SourceApp]
}

struct SourceApp: Codable, Identifiable, Sendable {
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let localizedDescription: String?
    let iconURL: URL?
    let versions: [SourceAppVersion]

    var id: String { bundleIdentifier }
    // AltStore defines the first entry as the latest release, regardless of its date/version number.
    var latestVersion: SourceAppVersion? { versions.first }

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, localizedDescription, iconURL, versions
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        developerName = try values.decodeIfPresent(String.self, forKey: .developerName)
        localizedDescription = try values.decodeIfPresent(String.self, forKey: .localizedDescription)
        iconURL = try values.decodeIfPresent(URL.self, forKey: .iconURL)
        if let releases = try values.decodeIfPresent([SourceAppVersion].self, forKey: .versions) {
            versions = releases
        } else {
            let legacy = try LegacyVersion(from: decoder)
            versions = [SourceAppVersion(
                version: legacy.version, buildVersion: legacy.buildVersion,
                date: legacy.versionDate, localizedDescription: legacy.versionDescription,
                downloadURL: legacy.downloadURL, size: legacy.size,
                minOSVersion: legacy.minOSVersion, maxOSVersion: legacy.maxOSVersion
            )]
        }
    }

    private struct LegacyVersion: Decodable {
        let version: String
        let buildVersion: String?
        let versionDate: String?
        let versionDescription: String?
        let downloadURL: URL
        let size: Int64?
        let minOSVersion: String?
        let maxOSVersion: String?
    }
}

struct SourceAppVersion: Codable, Sendable {
    let version: String
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?
    let minOSVersion: String?
    let maxOSVersion: String?

    var displayVersion: String {
        buildVersion.map { "\(version) (\($0))" } ?? version
    }
}

struct SavedAppSource: Codable, Identifiable, Sendable {
    let url: URL
    var catalog: AppSourceCatalog
    var updatedAt: Date
    var id: String { url.absoluteString }
}

enum AppSourceStore {
    static let preferencesKey = "appSources"

    static func load(from preferences: UserDefaults) -> [SavedAppSource] {
        guard let data = preferences.data(forKey: preferencesKey) else { return [] }
        return (try? JSONDecoder().decode([SavedAppSource].self, from: data)) ?? []
    }

    static func save(_ sources: [SavedAppSource], to preferences: UserDefaults) throws {
        preferences.set(try JSONEncoder().encode(sources), forKey: preferencesKey)
    }
}

enum AppSourceError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

struct AppSourceService: Sendable {
    static let kazumiSourceURL = "https://raw.githubusercontent.com/ChouChiu/Kazumi-AltStore-Source/kazumi/generated/apps.json"
    static let autoSignStoreSourceURL = "https://raw.githubusercontent.com/tignioj/auto-sign-store/source/apps.json"
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    static func sourceURL(from input: String) throws -> URL {
        guard var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw AppSourceError.invalid(L10n.tr("请输入完整的 HTTP 或 HTTPS 源地址，指向 AltStore / SideStore 的 JSON 文件。"))
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        guard let url = components.url else { throw AppSourceError.invalid(L10n.tr("源地址无效。")) }
        return url
    }

    static func parseCatalog(_ data: Data) throws -> AppSourceCatalog {
        let catalog: AppSourceCatalog
        do { catalog = try JSONDecoder().decode(AppSourceCatalog.self, from: data) }
        catch { throw AppSourceError.invalid(L10n.tr("无法解析源：请使用 AltStore / SideStore 格式的 JSON。\n\(error.localizedDescription)")) }
        guard !catalog.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppSourceError.invalid(L10n.tr("源缺少名称。"))
        }
        var identifiers = Set<String>()
        for app in catalog.apps {
            guard !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  identifiers.insert(app.bundleIdentifier).inserted else {
                throw AppSourceError.invalid(L10n.tr("源中的应用名称或 Bundle ID 为空，或存在重复的 Bundle ID。"))
            }
        }
        return catalog
    }

    func fetchCatalog(at url: URL) async throws -> AppSourceCatalog {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response)
        return try Self.parseCatalog(data)
    }

    func download(_ version: SourceAppVersion, to directory: URL) async throws -> URL {
        let url = try Self.sourceURL(from: version.downloadURL.absoluteString)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        // Stream into a temporary file rather than keeping an entire IPA in memory.
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try Self.validateResponse(response)
        try await Self.validateIPA(at: temporary, expectedSize: version.size)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A unique directory preserves IPAs referenced by previous installs/background renewal.
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = version.downloadURL.pathExtension.lowercased() == "ipa"
            ? version.downloadURL.lastPathComponent : "app-\(version.version).ipa"
        let safeFilename = filename.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        let destination = folder.appendingPathComponent(String(safeFilename.suffix(180)))
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return destination
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppSourceError.invalid(L10n.tr("服务器没有返回有效的 HTTP 响应。"))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppSourceError.invalid(L10n.tr("请求失败（HTTP \(http.statusCode)），请检查地址或稍后重试。"))
        }
    }

    static func validateIPA(at url: URL, expectedSize: Int64?) async throws {
        let actualSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard actualSize > 0 else { throw AppSourceError.invalid(L10n.tr("下载的 IPA 是空文件。")) }
        if let expectedSize, expectedSize > 0, Int64(actualSize) != expectedSize {
            throw AppSourceError.invalid(L10n.tr("下载大小与源记录不一致，请刷新源后重试。"))
        }
        let listing = try await ProcessRunner.run("/usr/bin/unzip", ["-Z1", url.path])
        let containsApp = listing.output.split(separator: "\n").contains { path in
            let parts = path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard listing.status == 0, containsApp else {
            throw AppSourceError.invalid(L10n.tr("下载内容不是有效的 IPA（缺少 Payload/*.app/Info.plist），可能是网页或不支持的安装格式。"))
        }
        let integrity = try await ProcessRunner.run("/usr/bin/unzip", ["-tq", url.path])
        guard integrity.status == 0 else { throw AppSourceError.invalid(L10n.tr("IPA 压缩包损坏，请重新下载。")) }
    }
}

extension AppSourceService {
    /// Read the original identity before provisioning; source metadata alone cannot identify an IPA.
    static func packageBundleIdentifier(at url: URL) async throws -> String {
        try await packageMetadata(at: url).bundleIdentifier
    }

    struct PackageMetadata: Sendable {
        let bundleIdentifier: String
        let version: String?
        let buildVersion: String?
    }

    static func packageMetadata(at url: URL) async throws -> PackageMetadata {
        let listing = try await ProcessRunner.checked("/usr/bin/unzip", ["-Z1", url.path], context: L10n.tr("无法读取 IPA。"))
        let paths = listing.output.split(separator: "\n").map(String.init).filter { path in
            let parts = path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard paths.count == 1, let path = paths.first else { throw AppSourceError.invalid(L10n.tr("IPA 必须包含一个应用。")) }
        let plist = try await ProcessRunner.checked("/usr/bin/unzip", ["-p", url.path, path], context: L10n.tr("无法读取应用信息。"))
        guard let info = try PropertyListSerialization.propertyList(from: plist.data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, SigningService.isValidBundleIdentifier(id) else {
            throw AppSourceError.invalid(L10n.tr("IPA 的应用标识无效。"))
        }
        return PackageMetadata(bundleIdentifier: id, version: info["CFBundleShortVersionString"] as? String,
                               buildVersion: info["CFBundleVersion"] as? String)
    }
}
