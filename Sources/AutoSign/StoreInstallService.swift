import AutoSignLocalization
import Foundation
import CryptoKit

@MainActor
enum StoreInstallService {
    static func install(_ input: StoreInstallRequest, version: SourceAppVersion, preferences: UserDefaults, updating record: StoreRecord? = nil,
                        statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws -> Date {
        let available = try await DeviceService.connectedDevices(excluding: DeviceRemovalStore.removedUDIDs(from: preferences))
        guard let device = available.first(where: { $0.udid == input.deviceUDID && $0.isReadyForInstallation }) else {
            throw AutoSignError.command(L10n.tr("设备不可用。请解锁设备，检查 Wi-Fi、USB 配对及开发者模式。"))
        }
        statusChanged(L10n.tr("正在下载 IPA \(version.displayVersion)…"))
        let directory = try BackgroundRefreshManager.applicationSupportURL().appendingPathComponent("Downloads", isDirectory: true)
        let ipa = try await AppSourceService().download(version, to: directory)
        defer { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) }
        let metadata = try await AppSourceService.packageMetadata(at: ipa)
        guard metadata.bundleIdentifier == input.bundleIdentifier else {
            throw AppSourceError.invalid(L10n.tr("下载的 IPA 应用标识与源记录不一致，已停止安装。"))
        }
        try validateRelease(metadata, version: version)
        let records = try StoreLibrary.records().filter { $0.app.deviceUDID == device.udid }
        let existing: StoreRecord?
        if let record {
            guard record.app.deviceUDID == input.deviceUDID,
                  records.contains(where: { $0.app.id == record.app.id && $0.app.bundleIdentifier == record.app.bundleIdentifier }) else {
                throw AutoSignError.command(L10n.tr("原应用记录已变更，请重新同步后再更新。"))
            }
            existing = record
        } else { existing = await existingRecord(sourceID: input.bundleIdentifier, deviceUDID: input.deviceUDID, records: records) }
        let seed: ProvisioningProfile
        if existing == nil && preferences.bool(forKey: IndependentAccountModel.enabledKey) {
            seed = try IndependentProvisioningService.seedProfile()
        } else {
            let profileURL: URL
            if let existing { profileURL = URL(fileURLWithPath: existing.profilePath) }
            else if let path = preferences.string(forKey: "profilePath"), FileManager.default.fileExists(atPath: path) {
                profileURL = URL(fileURLWithPath: path)
            } else if let record = records.first { profileURL = URL(fileURLWithPath: record.profilePath) }
            else if let installed = await SigningService.bestInstalledProfileURL(for: device) { profileURL = installed }
            else { throw AutoSignError.invalidProfile(L10n.tr("请先在 Mac AutoSign 选择签名证书和描述文件，或安装一次应用以配置签名团队。")) }
            seed = try await SigningService.readProfile(at: profileURL)
        }
        if let team = existing?.teamIdentifier, team != seed.teamIdentifier {
            throw AutoSignError.invalidProfile(L10n.tr("签名团队与原应用不一致，已停止覆盖安装。"))
        }
        let targetID = existing?.app.bundleIdentifier ?? newBundleIdentifier(sourceID: input.bundleIdentifier, seed: seed)
        let renewedURL = try await SigningService.requestProfile(for: device, bundleIdentifier: targetID, seed: seed, statusChanged: statusChanged)
        let renewed = try await SigningService.readProfile(at: renewedURL)
        guard renewed.teamIdentifier == seed.teamIdentifier else {
            throw AutoSignError.invalidProfile(L10n.tr("新描述文件的签名团队与原应用不一致，已停止覆盖安装。"))
        }
        let identities = try await SigningService.identities()
        guard let identity = SigningService.identity(for: renewed, available: identities,
                                                    preferredID: existing?.identityID ?? preferences.string(forKey: "identityID")) else {
            throw AutoSignError.invalidProfile(L10n.tr("找不到此签名团队的有效证书，请在 Mac 检查签名账号与本机证书。"))
        }
        let signed = ipa.deletingLastPathComponent().appendingPathComponent("signed.ipa")
        _ = try await SigningService.signAndInstall(ipa: ipa, profileURL: renewedURL, identity: identity,
            device: device, outputIPA: signed, expectedBundleIdentifier: input.bundleIdentifier,
            installedBundleIdentifier: targetID, sourceURL: input.sourceURL
        ) { _, message in statusChanged(message) }
        return renewed.expirationDate
    }

    static func validateRelease(_ metadata: AppSourceService.PackageMetadata, version: SourceAppVersion) throws {
        guard let actual = metadata.version, StoreUpdateDetector.compareVersions(actual, version.version) == .orderedSame,
              version.buildVersion == nil || metadata.buildVersion == version.buildVersion else {
            throw AppSourceError.invalid(L10n.tr("下载的 IPA 实际版本与源发布版本不一致，已停止安装。请等待源修复后重试。"))
        }
    }
    /// Older manual installs may have a rewritten ID. Their original IPA still identifies the source app.
    static func existingRecord(sourceID: String, deviceUDID: String, records: [StoreRecord],
                               originalID: @Sendable (URL) async -> String? = { try? await AppSourceService.packageBundleIdentifier(at: $0) }) async -> StoreRecord? {
        let owned = records.filter { $0.app.deviceUDID == deviceUDID }
        if let exact = owned.first(where: { $0.sourceBundleIdentifier == sourceID || $0.app.bundleIdentifier == sourceID }) { return exact }
        for record in owned {
            if await originalID(URL(fileURLWithPath: record.ipaPath)) == sourceID { return record }
        }
        return nil
    }

    /// A source's public ID may already belong to its publisher. Each team gets a stable, independent ID.
    static func newBundleIdentifier(sourceID: String, seed: ProvisioningProfile) -> String {
        if SigningService.explicitBundleIdentifier(from: seed.applicationIdentifier) == sourceID { return sourceID }
        let candidate = "\(sourceID).autosign.\(seed.teamIdentifier.lowercased())"
        if SigningService.isValidBundleIdentifier(candidate) { return candidate }
        let digest = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.autosign.\(seed.teamIdentifier.lowercased()).app\(digest.prefix(24))"
    }
}
