import Foundation

enum BackgroundRefreshCoordinator {
    /// Xcode Personal Team profiles cannot reliably be replaced before Apple considers them expired.
    /// We probe during the last day, then launchd retries every 30 minutes at/after expiration.
    private static let renewalWindow: TimeInterval = 24 * 60 * 60

    static func run() async {
        do {
            let preferences = UserDefaults.standard
            guard let ipaPath = preferences.string(forKey: "ipaPath"),
                  FileManager.default.fileExists(atPath: ipaPath) else {
                BackgroundRefreshManager.record("等待用户在 AutoSign 中选择 IPA")
                return
            }
            guard let profilePath = preferences.string(forKey: "profilePath"),
                  FileManager.default.fileExists(atPath: profilePath) else {
                BackgroundRefreshManager.record("找不到上次使用的描述文件")
                return
            }
            guard let deviceUDID = preferences.string(forKey: "deviceUDID") else {
                BackgroundRefreshManager.record("等待用户完成一次手动安装")
                return
            }

            let sourceProfile = URL(fileURLWithPath: profilePath)
            let oldProfile = try await SigningService.readProfile(at: sourceProfile)
            let remaining = oldProfile.expirationDate.timeIntervalSinceNow
            guard remaining <= renewalWindow else {
                let days = max(1, Int(ceil(remaining / 86_400)))
                BackgroundRefreshManager.record("签名正常，剩余约 \(days) 天")
                return
            }

            let devices = try await DeviceService.connectedDevices()
            guard let device = devices.first(where: { $0.udid == deviceUDID && $0.isConnected }) else {
                BackgroundRefreshManager.record("未在局域网发现 iPad，30 分钟后重试")
                return
            }
            guard device.developerModeEnabled else {
                BackgroundRefreshManager.record("iPad 开发者模式未开启")
                return
            }

            let renewedURL = try await SigningService.ensureUsableProfile(
                at: sourceProfile, for: device, forceRefresh: true
            ) { message in BackgroundRefreshManager.record(message) }
            let renewedProfile = try await SigningService.readProfile(at: renewedURL)

            // Before expiry Xcode may return the existing profile. Avoid a pointless reinstall;
            // launchd will retry and obtain a new profile as soon as Apple expires the old one.
            if !oldProfile.isExpired && renewedProfile.expirationDate <= oldProfile.expirationDate {
                BackgroundRefreshManager.record("已进入续期窗口，等待 Apple 发放新签名")
                return
            }

            let identities = try await SigningService.identities()
            guard let identity = identities.first else {
                throw AutoSignError.missingSelection("续期后仍未找到 Apple Development 证书。")
            }
            preferences.set(renewedURL.path, forKey: "profilePath")
            preferences.set(identity.id, forKey: "identityID")
            let output = try BackgroundRefreshManager.applicationSupportURL()
                .appendingPathComponent("Background/last-signed.ipa")
            _ = try await SigningService.signAndInstall(
                ipa: URL(fileURLWithPath: ipaPath),
                profileURL: renewedURL,
                identity: identity,
                device: device,
                outputIPA: output
            ) { _, message in BackgroundRefreshManager.record(message) }
            BackgroundRefreshManager.record("已通过 Wi‑Fi 自动续签并安装到 \(device.name)")
            await BackgroundRefreshManager.notify(title: "AutoSign 自动续签成功", body: "已更新 \(device.name) 上的应用。")
        } catch {
            BackgroundRefreshManager.record("自动续签失败：\(error.localizedDescription)")
            await BackgroundRefreshManager.notify(title: "AutoSign 自动续签失败", body: error.localizedDescription)
        }
    }
}
