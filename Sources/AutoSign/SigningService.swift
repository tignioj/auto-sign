import AutoSignLocalization
import Foundation
import CryptoKit

enum SigningService {
    static func identities() async throws -> [SigningIdentity] {
        let result = try await ProcessRunner.checked(
            "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"],
            context: L10n.tr("无法读取钥匙串中的签名证书。")
        )
        let pattern = /^\s*\d+\)\s+([0-9A-F]+)\s+"(.+)"$/
        return result.output.split(separator: "\n").compactMap { line in
            guard let match = String(line).wholeMatch(of: pattern) else { return nil }
            return SigningIdentity(hash: String(match.1), name: String(match.2))
        }
    }

    static func readProfile(at url: URL) async throws -> ProvisioningProfile {
        let result = try await ProcessRunner.checked(
            "/usr/bin/security", ["cms", "-D", "-i", url.path],
            context: L10n.tr("无法读取描述文件。")
        )
        guard let raw = try PropertyListSerialization.propertyList(from: result.data, options: [], format: nil) as? [String: Any],
              let name = raw["Name"] as? String,
              let uuid = raw["UUID"] as? String,
              let expiration = raw["ExpirationDate"] as? Date,
              let entitlements = raw["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String else {
            throw AutoSignError.invalidProfile(L10n.tr("描述文件内容不完整，请重新选择 `.mobileprovision` 文件。"))
        }
        return ProvisioningProfile(
            name: name,
            uuid: uuid,
            expirationDate: expiration,
            applicationIdentifier: appID,
            teamIdentifier: (raw["TeamIdentifier"] as? [String])?.first ?? String(appID.split(separator: ".").first ?? ""),
            provisionedDevices: Set(raw["ProvisionedDevices"] as? [String] ?? []),
            provisionsAllDevices: raw["ProvisionsAllDevices"] as? Bool ?? false,
            entitlements: entitlements.mapValues(AnySendable.init),
            signingCertificateHashes: Set((raw["DeveloperCertificates"] as? [Data] ?? []).map {
                Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined()
            }),
            creationDate: raw["CreationDate"] as? Date,
            timeToLiveDays: raw["TimeToLive"] as? Int
        )
    }

    static func identity(for profile: ProvisioningProfile, available: [SigningIdentity], preferredID: String?) -> SigningIdentity? {
        let matching = available.filter { identity in
            if !profile.signingCertificateHashes.isEmpty {
                return profile.signingCertificateHashes.contains(identity.hash.uppercased())
            }
            return identity.name.contains("(\(profile.teamIdentifier))")
        }
        return matching.first { $0.id == preferredID } ?? matching.first
    }

    static func ensureUsableProfile(
        at profileURL: URL,
        for device: AppleDevice,
        forceRefresh: Bool,
        bundleIdentifier: String? = nil,
        statusChanged: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> URL {
        let operationLock = try SigningOperationLock()
        defer { withExtendedLifetime(operationLock) {} }
        let profile = try await readProfile(at: profileURL)
        let deviceMissing = !profile.provisionsAllDevices && !profile.provisionedDevices.contains(device.udid)
        guard profileNeedsRefresh(profile, for: device.udid, forceRefresh: forceRefresh) else {
            return profileURL
        }
        guard let bundleID = bundleIdentifier ?? explicitBundleIdentifier(from: profile.applicationIdentifier),
              !bundleID.isEmpty, !bundleID.contains("*"),
              profileSupports(profile.applicationIdentifier, bundleID: bundleID),
              !profile.teamIdentifier.isEmpty else {
            throw AutoSignError.invalidProfile(L10n.tr("无法从旧描述文件读取续期所需的 Team ID 或 Bundle ID。"))
        }

        let refreshMessage: String
        if deviceMissing {
            refreshMessage = L10n.tr("描述文件未包含 \(device.name)，正在通过 Xcode 注册设备并更新…")
        } else if profile.isExpired {
            refreshMessage = L10n.tr("描述文件已过期，正在通过 Xcode 自动续期…")
        } else {
            refreshMessage = L10n.tr("正在请求 Apple 重新签发描述文件…")
        }
        await statusChanged(refreshMessage)
        return try await generateProfile(for: device, bundleIdentifier: bundleID, seed: profile,
                                        requireExtendedExpiry: forceRefresh,
                                        statusChanged: statusChanged)
    }

    static func requestProfile(for device: AppleDevice, bundleIdentifier bundleID: String,
                               seed profile: ProvisioningProfile,
                               statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws -> URL {
        let operationLock = try SigningOperationLock()
        defer { withExtendedLifetime(operationLock) {} }
        return try await generateProfile(for: device, bundleIdentifier: bundleID, seed: profile, statusChanged: statusChanged)
    }

    private static func generateProfile(for device: AppleDevice, bundleIdentifier bundleID: String,
                                        seed profile: ProvisioningProfile,
                                        requireExtendedExpiry: Bool = false,
                                        statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws -> URL {
        guard isValidBundleIdentifier(bundleID), !profile.teamIdentifier.isEmpty else {
            throw AutoSignError.invalidProfile(L10n.tr("应用标识或签名团队无效。"))
        }
        if IndependentAccountModel.isEnabled {
            return try await IndependentProvisioningService.profile(for: device, bundleID: bundleID,
                original: profile, requireExtendedExpiry: requireExtendedExpiry, statusChanged: statusChanged)
        }
        // Check before isolating any cached profiles, then again at each actual
        // invocation in case the screen locked while preparing or retrying.
        try await XcodeCredentialAccess.waitUntilAvailable(statusChanged: statusChanged)
        await statusChanged(L10n.tr("正在为 \(bundleID) 请求新的描述文件…"))
        let project = try provisioningHelperProjectURL()
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("AutoSign", isDirectory: true)
        let cacheLease = try await ProvisioningProfileCache.isolate(
            teamID: profile.teamIdentifier, bundleID: bundleID,
            backupRoot: appSupport.appendingPathComponent("ProfileCacheBackups", isDirectory: true)
        )
        defer { try? cacheLease.rollback() }
        // A new build directory also prevents reuse of an embedded profile from a previous helper build.
        let derivedData = appSupport.appendingPathComponent("ProvisioningDerivedData/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: derivedData) }
        let requestedAt = Date()

        try await DevicePreparationRetry.run {
            try await XcodeCredentialAccess.waitUntilAvailable(statusChanged: statusChanged)
            let result = try await ProcessRunner.run(
                "/usr/bin/xcrun",
                [
                    "xcodebuild", "-project", project.path, "-scheme", "ProvisioningHelper",
                    "-configuration", "Debug", "-destination", "id=\(device.udid)",
                    "-derivedDataPath", derivedData.path, "-allowProvisioningUpdates",
                    "-allowProvisioningDeviceRegistration", "DEVELOPMENT_TEAM=\(profile.teamIdentifier)",
                    "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)", "build"
                ]
            )
            guard result.status == 0 else {
                throw AutoSignError.command(XcodeCredentialAccess.provisioningFailure(result.output))
            }
        } beforeRetry: {
            await statusChanged(L10n.tr("\(device.name) 的开发者服务尚未准备好，等待 15 秒后自动重试 1 次…"))
            try await Task.sleep(for: .seconds(15))
        }

        let generated = derivedData
            .appendingPathComponent("Build/Products/Debug-iphoneos/ProvisioningHelper.app/embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: generated.path) else {
            throw AutoSignError.invalidProfile(L10n.tr("Xcode 已完成构建，但没有生成新的描述文件。"))
        }
        let renewed = try await readProfile(at: generated)
        try ProfileRenewalPolicy.validate(original: profile, renewed: renewed, bundleID: bundleID,
                                           deviceUDID: device.udid, requestedAt: requestedAt,
                                           requireExtendedExpiry: requireExtendedExpiry)
        let profilesFolder = appSupport.appendingPathComponent("Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesFolder, withIntermediateDirectories: true)
        let destination = profilesFolder.appendingPathComponent("\(bundleID).mobileprovision")
        try FileManager.default.copyItemReplacing(generated, to: destination)
        try cacheLease.commit()
        return destination
    }

    static func profileNeedsRefresh(
        _ profile: ProvisioningProfile,
        for deviceUDID: String,
        forceRefresh: Bool
    ) -> Bool {
        forceRefresh
            || profile.isExpired
            || (!profile.provisionsAllDevices && !profile.provisionedDevices.contains(deviceUDID))
    }

    static func bestInstalledProfileURL(for device: AppleDevice?) async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")
        ]
        let candidates = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }.filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension.lowercased()) }

        var matches: [(URL, ProvisioningProfile)] = []
        for url in candidates {
            guard let profile = try? await readProfile(at: url), !profile.isExpired else { continue }
            if let device,
               !profile.provisionsAllDevices,
               !profile.provisionedDevices.contains(device.udid) { continue }
            matches.append((url, profile))
        }
        return matches.sorted { $0.1.expirationDate > $1.1.expirationDate }.first?.0
    }

    static func signAndInstall(
        ipa: URL,
        profileURL: URL,
        identity: SigningIdentity,
        device: AppleDevice,
        outputIPA: URL? = nil,
        expectedBundleIdentifier: String? = nil,
        installedBundleIdentifier: String? = nil,
        sourceURL: String? = nil,
        refreshVerification: RefreshVerificationOptions? = nil,
        stageChanged: @escaping @MainActor @Sendable (InstallStage, String) -> Void
    ) async throws -> URL {
        let operationLock = try SigningOperationLock()
        defer { withExtendedLifetime(operationLock) {} }
        await stageChanged(.preparing, L10n.tr("正在解包并检查 IPA…"))
        guard ipa.pathExtension.lowercased() == "ipa" else {
            throw AutoSignError.invalidIPA(L10n.tr("请选择 `.ipa` 文件；iOS 应用安装包不是 `.ipk`。"))
        }
        guard device.isConnected else { throw AutoSignError.missingSelection(L10n.tr("目标设备当前未连接。")) }
        guard device.developerModeEnabled else {
            throw AutoSignError.missingSelection(L10n.tr("请先在设备的“设置 → 隐私与安全性 → 开发者模式”中开启开发者模式，然后重启设备。"))
        }

        let profile = try await readProfile(at: profileURL)
        guard !profile.isExpired else { throw AutoSignError.invalidProfile(L10n.tr("描述文件已过期：\(profile.name)")) }
        guard profile.provisionsAllDevices || profile.provisionedDevices.contains(device.udid) else {
            if profile.provisionedDevices.isEmpty {
                throw AutoSignError.incompatibleProfile(L10n.tr("这是 App Store 描述文件，不能直接安装到设备。请选择开发、Ad Hoc 或企业描述文件。"))
            }
            throw AutoSignError.incompatibleProfile(L10n.tr("描述文件不包含所选设备的 UDID（\(device.udid)）。"))
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try await ProcessRunner.checked(
            "/usr/bin/ditto", ["-x", "-k", ipa.path, work.path], context: L10n.tr("IPA 解包失败。")
        )

        let payload = work.appendingPathComponent("Payload")
        let appURLs = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard appURLs.count == 1, let app = appURLs.first else {
            throw AutoSignError.invalidIPA(L10n.tr("IPA 必须在 Payload 中包含且只包含一个 `.app`。"))
        }

        var mainBundleID = try bundleIdentifier(at: app)
        let originalBundleID = mainBundleID
        if let expectedBundleIdentifier, mainBundleID != expectedBundleIdentifier {
            throw AutoSignError.invalidIPA(L10n.tr("下载的 IPA 应用标识与源记录不一致，已停止安装。"))
        }
        if let installedBundleIdentifier, installedBundleIdentifier != mainBundleID {
            guard profileSupports(profile.applicationIdentifier, bundleID: installedBundleIdentifier) else {
                throw AutoSignError.incompatibleProfile(L10n.tr("描述文件不支持原应用标识，已停止覆盖安装。"))
            }
            try replaceBundleIdentifier(at: app, with: installedBundleIdentifier)
            mainBundleID = installedBundleIdentifier
        }
        if expectedBundleIdentifier != nil, !profileSupports(profile.applicationIdentifier, bundleID: mainBundleID) {
            throw AutoSignError.incompatibleProfile(L10n.tr("描述文件与应用标识不匹配，已停止安装。"))
        }
        if !profileSupports(profile.applicationIdentifier, bundleID: mainBundleID) {
            guard let replacement = explicitBundleIdentifier(from: profile.applicationIdentifier) else {
                throw AutoSignError.incompatibleProfile(
                    L10n.tr("描述文件对应 \(profile.applicationIdentifier)，但应用标识是 \(mainBundleID)。请创建匹配的描述文件。")
                )
            }
            try replaceBundleIdentifier(at: app, with: replacement)
            mainBundleID = replacement
        }

        // Always use the actual installation target, including when updating or
        // re-signing a saved IPA that was originally prepared for another device.
        try writeStoreDeviceBinding(at: app, deviceUDID: device.udid)
        await stageChanged(.signing, L10n.tr("正在签名框架与应用主体…"))
        try FileManager.default.copyItemReplacing(profileURL, to: app.appendingPathComponent("embedded.mobileprovision"))
        let allFiles = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let libraries = allFiles.filter { $0.pathExtension == "framework" || $0.pathExtension == "dylib" }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for library in libraries {
            try await codesign(library, identity: identity, entitlementsURL: nil)
        }

        let nestedBundles = allFiles.filter { ["appex", "xpc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for bundle in nestedBundles {
            let bundleID = try bundleIdentifier(at: bundle)
            guard profileSupports(profile.applicationIdentifier, bundleID: bundleID) else {
                throw AutoSignError.incompatibleProfile(L10n.tr("描述文件不支持扩展 \(bundleID)。建议使用通配符开发描述文件。"))
            }
            try FileManager.default.copyItemReplacing(profileURL, to: bundle.appendingPathComponent("embedded.mobileprovision"))
            let entitlementsURL = try writeEntitlements(profile.entitlements, bundleID: bundleID, in: work)
            try await codesign(bundle, identity: identity, entitlementsURL: entitlementsURL)
        }

        let entitlementsURL = try writeEntitlements(profile.entitlements, bundleID: mainBundleID, in: work)
        try await codesign(app, identity: identity, entitlementsURL: entitlementsURL)
        _ = try await ProcessRunner.checked(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], context: L10n.tr("签名验证失败。")
        )

        let output = outputIPA ?? uniqueOutputURL(for: ipa)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if outputIPA != nil, FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        _ = try await ProcessRunner.checked(
            "/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, output.path],
            context: L10n.tr("无法生成签名后的 IPA。")
        )

        await stageChanged(.installing, L10n.tr("正在将应用安装到 \(device.name)…"))
        _ = try await ProcessRunner.checked(
            "/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", device.udid, app.path, "--timeout", "180"],
            context: L10n.tr("设备安装失败。")
        )
        if let verification = refreshVerification {
            await stageChanged(.installing, verification.verifyLaunch
                ? L10n.tr("已安装，正在验证描述文件和应用启动…") : L10n.tr("已安装，正在验证描述文件…"))
            try await verification.verify(profile: {
                do { try await DeviceProfileService.verify(profileURL, on: device) }
                catch ProfileRefreshError.unsupported {
                    // Without profile read-back, rely on the validated signed
                    // package and successful install, plus launch if enabled.
                    // A missing profile on a supported device remains a failure.
                    await stageChanged(.installing, verification.verifyLaunch
                        ? L10n.tr("设备不支持读回描述文件，正在验证已签名安装包的启动…")
                        : L10n.tr("设备不支持读回描述文件，已确认签名包与安装结果"))
                }
            }, launch: {
                try await DeviceAppVerification.verifyLaunch(mainBundleID, on: device)
            })
        }
        try StoreLibrary.recordInstall(ipa: ipa, profileURL: profileURL, identity: identity,
                                       device: device, bundle: app, expiration: profile.expirationDate,
                                       teamIdentifier: profile.teamIdentifier,
                                       sourceBundleIdentifier: originalBundleID, sourceURL: sourceURL,
                                       signedEntitlements: Data(contentsOf: entitlementsURL),
                                       extensionBundleIdentifiers: try nestedBundles.map { try bundleIdentifier(at: $0) })
        return output
    }

    static func isValidBundleIdentifier(_ value: String) -> Bool {
        value.count <= 255 && value.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) == value.startIndex..<value.endIndex
    }

    static func profileSupports(_ applicationIdentifier: String, bundleID: String) -> Bool {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return false }
        let profileBundleID = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        if profileBundleID == "*" { return true }
        if profileBundleID.hasSuffix(".*") {
            return bundleID.hasPrefix(String(profileBundleID.dropLast(1)))
        }
        return profileBundleID == bundleID
    }

    static func explicitBundleIdentifier(from applicationIdentifier: String) -> String? {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return nil }
        let bundleID = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        return bundleID.contains("*") ? nil : bundleID
    }

    private static func bundleIdentifier(at bundle: URL) throws -> String {
        let plist = bundle.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plist)
        guard let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let identifier = raw["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw AutoSignError.invalidIPA(L10n.tr("无法读取 \(bundle.lastPathComponent) 的应用标识。"))
        }
        return identifier
    }

    private static func provisioningHelperProjectURL() throws -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("ProvisioningHelper/ProvisioningHelper.xcodeproj")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ProvisioningHelper/ProvisioningHelper.xcodeproj")
        if FileManager.default.fileExists(atPath: development.path) { return development }
        throw AutoSignError.command(L10n.tr("AutoSign 应用包中缺少自动续期组件，请重新构建或下载完整版本。"))
    }

    static func writeStoreDeviceBinding(at bundle: URL, deviceUDID: String) throws {
        let plist = bundle.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plist)
        guard var raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AutoSignError.invalidIPA(L10n.tr("无法读取 \(bundle.lastPathComponent) 的应用标识。"))
        }
        guard raw["AutoSignStoreClient"] as? Bool == true else { return }
        raw["AutoSignStoreDeviceUDID"] = deviceUDID
        let updated = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        try updated.write(to: plist, options: .atomic)
    }

    private static func replaceBundleIdentifier(at bundle: URL, with identifier: String) throws {
        let plist = bundle.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plist)
        guard var raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AutoSignError.invalidIPA(L10n.tr("无法修改 \(bundle.lastPathComponent) 的应用标识。"))
        }
        raw["CFBundleIdentifier"] = identifier
        let updated = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        try updated.write(to: plist, options: .atomic)
    }

    private static func writeEntitlements(
        _ wrapped: [String: AnySendable], bundleID: String, in directory: URL
    ) throws -> URL {
        let values = wrapped.mapValues(\.value)
        let expanded = expandWildcards(values, bundleID: bundleID)
        let data = try PropertyListSerialization.data(fromPropertyList: expanded, format: .xml, options: 0)
        let url = directory.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func expandWildcards(_ value: Any, bundleID: String) -> Any {
        if let string = value as? String { return string.replacingOccurrences(of: "*", with: bundleID) }
        if let array = value as? [Any] { return array.map { expandWildcards($0, bundleID: bundleID) } }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { expandWildcards($0, bundleID: bundleID) }
        }
        return value
    }

    private static func codesign(_ url: URL, identity: SigningIdentity, entitlementsURL: URL?) async throws {
        var arguments = ["--force", "--sign", identity.hash, "--timestamp=none"]
        if let entitlementsURL { arguments += ["--entitlements", entitlementsURL.path] }
        arguments.append(url.path)
        _ = try await ProcessRunner.checked("/usr/bin/codesign", arguments, context: L10n.tr("签名失败：\(url.lastPathComponent)"))
    }

    private static func uniqueOutputURL(for ipa: URL) -> URL {
        let folder = ipa.deletingLastPathComponent()
        let stem = ipa.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(stem)-signed.ipa")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-signed-\(number).ipa")
            number += 1
        }
        return candidate
    }
}

private extension FileManager {
    func copyItemReplacing(_ source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) { try removeItem(at: destination) }
        try copyItem(at: source, to: destination)
    }
}
