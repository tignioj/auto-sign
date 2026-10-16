import AutoSignLocalization
import Foundation

struct AppRefreshResult: Sendable {
    enum Method: String, Sendable { case profileOnly, reinstalled }
    let method: Method
    let expiration: Date
    let fallbackReason: String?
    let verification: RefreshVerificationOptions

    var message: String {
        let methodMessage = method == .profileOnly ? L10n.tr("已更新描述文件，无需重装") : L10n.tr("已重新签名并覆盖安装")
        return L10n.tr("\(methodMessage)；有效期已延长，\(verification.completionMessage)") + (fallbackReason.map { "（\($0)）" } ?? "")
    }
}

enum ProfileRefreshCompatibility {
    static func reason(record: StoreRecord, original: ProvisioningProfile, renewed: ProvisioningProfile) -> String? {
        guard original.signingCertificateHashes.contains(record.identityID.uppercased()),
              renewed.signingCertificateHashes.contains(record.identityID.uppercased()) else {
            return L10n.tr("签名证书已变化，需要重新签名")
        }
        guard let data = record.signedEntitlements,
              let required = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return L10n.tr("旧安装缺少签名权限记录，需要覆盖安装一次")
        }
        guard let extensions = record.extensionBundleIdentifiers, extensions.isEmpty else {
            return L10n.tr("应用包含扩展或缺少扩展记录，需要完整更新签名")
        }
        let allowed = renewed.entitlements.mapValues(\.value)
        guard required.allSatisfy({ key, value in allowed[key].map { permits($0, value) } ?? false }) else {
            return L10n.tr("新的描述文件不兼容原应用的签名权限")
        }
        return nil
    }

    static func permits(_ allowed: Any, _ required: Any) -> Bool {
        if let required = required as? String, let allowed = allowed as? String {
            if allowed == required { return true }
            if allowed.hasSuffix("*"), !allowed.dropLast().contains("*") {
                return required.hasPrefix(String(allowed.dropLast()))
            }
            return false
        }
        if let required = required as? [Any], let allowed = allowed as? [Any] {
            return required.allSatisfy { item in allowed.contains { permits($0, item) } }
        }
        if let required = required as? [String: Any], let allowed = allowed as? [String: Any] {
            return required.allSatisfy { key, value in allowed[key].map { permits($0, value) } ?? false }
        }
        return (allowed as? NSObject)?.isEqual(required) == true
    }
}

enum AppRefreshService {
    static func refresh(_ record: StoreRecord, on device: AppleDevice,
                        verification: RefreshVerificationOptions = .load(),
                        allowReinstall: Bool = true,
                        statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws -> AppRefreshResult {
        let profileURL = try await SigningService.ensureUsableProfile(
            at: URL(fileURLWithPath: record.profilePath), for: device, forceRefresh: true,
            bundleIdentifier: record.app.bundleIdentifier, statusChanged: statusChanged)
        return try await apply(record, profileURL: profileURL, on: device, verification: verification,
                               allowReinstall: allowReinstall, statusChanged: statusChanged)
    }

    static func apply(_ record: StoreRecord, profileURL: URL, on device: AppleDevice,
                      verification: RefreshVerificationOptions = .load(),
                      allowReinstall: Bool = true,
                      statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws -> AppRefreshResult {
        let original = try await SigningService.readProfile(at: URL(fileURLWithPath: record.profilePath))
        let renewed = try await SigningService.readProfile(at: profileURL)
        try validate(record: record, original: original, renewed: renewed, deviceUDID: device.udid)
        let signedRecord = try await signatureMetadata(record, original: original)
        let reason = ProfileRefreshCompatibility.reason(record: signedRecord, original: original, renewed: renewed)
        return try await perform(expiration: renewed.expirationDate, incompatibility: reason, verification: verification,
                                 allowReinstall: allowReinstall && !ProfileRefreshPolicy.profileOnly(on: device.udid), profileOnly: {
            let lock = try SigningOperationLock()
            defer { withExtendedLifetime(lock) {} }
            guard let before = try await DeviceAppVerification.application(record.app.bundleIdentifier, on: device, statusChanged: statusChanged) else {
                throw ProfileRefreshError.incompatible(L10n.tr("设备上未找到原应用，需要完整安装"))
            }
            await statusChanged(L10n.tr("正在更新描述文件，无需重新安装应用…"))
            try await DeviceProfileService.install(profileURL, on: device, statusChanged: statusChanged)
            await statusChanged(verification.verifyLaunch
                ? L10n.tr("正在从设备读回描述文件并验证应用启动…") : L10n.tr("正在从设备读回并校验描述文件…"))
            try await verification.verify(profile: {
                try await DeviceProfileService.verify(profileURL, on: device, statusChanged: statusChanged)
            }, launch: {
                try await DeviceAppVerification.verifyLaunch(record.app.bundleIdentifier, on: device)
            })
            guard try await DeviceAppVerification.application(record.app.bundleIdentifier, on: device, statusChanged: statusChanged) == before else {
                throw ProfileRefreshError.verification(L10n.tr("验证期间设备上的应用已变化，无法确认本次续签结果。"))
            }
            try StoreLibrary.recordProfileRefresh(signedRecord, profileURL: profileURL, expiration: renewed.expirationDate)
        }, reinstall: { fallbackReason in
            await statusChanged(L10n.tr("\(fallbackReason)；正在改用覆盖安装…"))
            let identities = try await SigningService.identities()
            guard let identity = SigningService.identity(for: renewed, available: identities, preferredID: record.identityID) else {
                throw AutoSignError.command(L10n.tr("找不到此应用所属团队的签名证书，请在 Mac 检查 Xcode 账号。"))
            }
            let output = try StoreLibrary.directory().appendingPathComponent("Packages/\(record.app.id)/signed.ipa")
            _ = try await SigningService.signAndInstall(ipa: URL(fileURLWithPath: record.ipaPath),
                profileURL: profileURL, identity: identity, device: device, outputIPA: output,
                installedBundleIdentifier: record.app.bundleIdentifier, refreshVerification: verification
            ) { _, message in statusChanged(message) }
        })
    }

    private static func signatureMetadata(_ record: StoreRecord, original: ProvisioningProfile) async throws -> StoreRecord {
        var result = record
        // Legacy AutoSign always signed with the expanded entitlements from the
        // saved profile. This is conservative if later profiles add permissions.
        if result.signedEntitlements == nil {
            result.signedEntitlements = try PropertyListSerialization.data(
                fromPropertyList: SigningService.expandWildcards(original.entitlements.mapValues(\.value),
                    bundleID: record.app.bundleIdentifier), format: .binary, options: 0)
        }
        if result.extensionBundleIdentifiers == nil {
            let contents = try await ProcessRunner.checked("/usr/bin/unzip", ["-Z", "-1", record.ipaPath], context: L10n.tr("无法检查原 IPA 的应用扩展。"))
            result.extensionBundleIdentifiers = contents.output.split(separator: "\n")
                .filter { $0.contains(".appex/") || $0.contains(".xpc/") }.map(String.init)
        }
        return result
    }

    static func validate(record: StoreRecord, original: ProvisioningProfile, renewed: ProvisioningProfile,
                         deviceUDID: String) throws {
        guard record.app.deviceUDID == deviceUDID,
              original.teamIdentifier == renewed.teamIdentifier,
              record.teamIdentifier == nil || record.teamIdentifier == renewed.teamIdentifier,
              SigningService.profileSupports(original.applicationIdentifier, bundleID: record.app.bundleIdentifier),
              SigningService.profileSupports(renewed.applicationIdentifier, bundleID: record.app.bundleIdentifier),
              renewed.provisionsAllDevices || renewed.provisionedDevices.contains(deviceUDID) else {
            throw ProfileRefreshError.verification(L10n.tr("新描述文件与原应用、签名团队或设备不匹配，已停止续签。"))
        }
        guard renewed.uuid != original.uuid,
              renewed.expirationDate > max(original.expirationDate, record.app.expiration),
              !renewed.isExpired else {
            throw ProfileRefreshError.verification(L10n.tr("新的描述文件没有延长有效期，已保留原续签记录。"))
        }
    }

    // Only a capability/signature incompatibility permits replacement. Offline,
    // locked, cancelled or unverified requests never silently trigger a reinstall.
    static func perform(expiration: Date, incompatibility: String?,
                        verification: RefreshVerificationOptions,
                        allowReinstall: Bool = true,
                        profileOnly: () async throws -> Void,
                        reinstall: (String) async throws -> Void) async throws -> AppRefreshResult {
        try Task.checkCancellation()
        var reason = incompatibility
        if reason == nil {
            do {
                try await profileOnly()
                return AppRefreshResult(method: .profileOnly, expiration: expiration, fallbackReason: nil, verification: verification)
            } catch ProfileRefreshError.incompatible(let message) { reason = message }
              catch ProfileRefreshError.unsupported(let message) { reason = message }
        }
        try Task.checkCancellation()
        let fallbackReason = reason ?? L10n.tr("设备不支持单独刷新描述文件")
        guard allowReinstall else {
            throw ProfileRefreshError.verification(L10n.tr("本次仅允许更新描述文件，已停止操作且未重装应用：\(fallbackReason)"))
        }
        try await reinstall(fallbackReason)
        return AppRefreshResult(method: .reinstalled, expiration: expiration, fallbackReason: fallbackReason, verification: verification)
    }
}
