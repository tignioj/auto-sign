import Foundation
import CryptoKit
@preconcurrency import AltSign
import AnisetteKit

/// Same local, emulated ADI provider used by current AltServer on macOS 27.
/// No third-party anisette server receives credentials or provisioning material.
@MainActor
enum LocalAnisetteProvider {
    static var providerID: String { WindowsAnisetteProvider.configuredURL?.absoluteString ?? "local-anisette-v1" }
    private struct Identity: Codable {
        var id = UUID()
        var blob: Data?
        var routingInfo: String?
    }

    private static let identityAccount = "anisette-identity-v1"
    private static var inFlight: Task<AltAppleBridge.Transfer<ALTAnisetteData>, Error>?

    static func fetch(statusChanged: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> ALTAnisetteData {
        if WindowsAnisetteProvider.configuredURL != nil {
            let remote = try await WindowsAnisetteProvider.shared.fetchAnisetteData()
            ALTAppleAPI.shared.authenticationUserAgent = remote.userAgent
            return remote.makeAnisetteData()
        }
        ALTAppleAPI.shared.authenticationUserAgent = nil
        // All native signing calls are serialized by SigningOperationLock. Avoid
        // a second provisioning operation from an overlapping foreground login.
        if let inFlight { return try await inFlight.value.value }
        let task = Task { AltAppleBridge.Transfer(try await generate(statusChanged: statusChanged)) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value.value
    }

    private static func generate(statusChanged: @MainActor @Sendable (String) -> Void) async throws -> ALTAnisetteData {
        AnisetteKitLogging.setLogging(false)
        let root = try BackgroundRefreshManager.applicationSupportURL().appendingPathComponent("Anisette", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let libraries = root.appendingPathComponent("Libraries", isDirectory: true)
        try await prepareLibraries(at: libraries, statusChanged: statusChanged)
        var identity = try AppleAccountStore.loadData(account: identityAccount).map {
            try JSONDecoder().decode(Identity.self, from: $0)
        } ?? Identity()
        try AppleAccountStore.saveData(JSONEncoder().encode(identity), account: identityAccount)
        let work = root.appendingPathComponent("Work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let client = try AnisetteClient(provisioningDir: work,
            provider: UnicornAnisetteDataProvider(), libraryDirectoryResolver: { libraries })
        let localID = withUnsafeBytes(of: identity.id.uuid) { bytes in
            SHA256.hash(data: Data(bytes)).map { String(format: "%02X", $0) }.joined()
        }
        var headers = AnisetteRequestHeaders()
        headers.localUserID = localID
        headers.routingInfo = identity.routingInfo
        let values: [String: String]
        let blob: Data?
        do {
            (values, blob) = try await client.getAnisetteData(identifier: identity.id,
                storage: .memory(existingBlob: identity.blob), headers: headers)
        } catch AnisetteKit.AnisetteError.adiError {
            // Re-provision once for a rejected ADI blob, never for a network error.
            (values, blob) = try await client.getAnisetteData(identifier: identity.id,
                storage: .memory(), headers: headers)
        }
        guard let machine = values[AnisetteConstants.Headers.machineID], !machine.isEmpty,
              let otp = values[AnisetteConstants.Headers.oneTimePassword], !otp.isEmpty,
              let routing = values[AnisetteConstants.Headers.routingInfo], let routingNumber = UInt64(routing) else {
            throw AutoSignError.command("本机未能生成有效的 Apple 设备认证数据，请稍后重试。")
        }
        if let blob { identity.blob = blob }
        identity.routingInfo = routing
        try AppleAccountStore.saveData(JSONEncoder().encode(identity), account: identityAccount)
        return ALTAnisetteData(machineID: machine, oneTimePassword: otp, localUserID: localID,
            routingInfo: routingNumber, deviceUniqueIdentifier: identity.id.uuidString.uppercased(),
            deviceSerialNumber: AnisetteConstants.defaultSerialNumber, deviceDescription: client.clientInfo,
            date: Date(), locale: .current, timeZone: .current)
    }

    private static func prepareLibraries(at directory: URL,
                                         statusChanged: @MainActor @Sendable (String) -> Void) async throws {
        if AnisetteClient.validateLibrariesExist(at: directory) { return }
        statusChanged("首次登录：正在从 Apple 下载本机设备认证组件…")
        let source = URL(string: "https://apps.mzstatic.com/content/android-apple-music-apk/applemusic.apk")!
        let (archive, response) = try await URLSession.shared.download(from: source)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let temporary = directory.deletingLastPathComponent().appendingPathComponent("Extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let names = AnisetteConstants.Libraries.requiredNames
        _ = try await ProcessRunner.checked("/usr/bin/unzip",
            ["-o", "-j", "-q", archive.path] + names.map { "lib/arm64-v8a/\($0)" } + ["-d", temporary.path],
            context: "无法提取 Apple 设备认证组件。")
        guard AnisetteClient.validateLibrariesExist(at: temporary) else { throw URLError(.cannotDecodeContentData) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in names {
            let destination = directory.appendingPathComponent(name)
            let extracted = temporary.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: extracted)
            } else { try FileManager.default.moveItem(at: extracted, to: destination) }
        }
    }
}
