import Foundation

enum BackgroundRefreshCoordinator {
    /// Renew during the last day, invalidating only the matching Xcode cache to request a fresh profile.
    private static let renewalWindow: TimeInterval = 24 * 60 * 60

    static func run() async {
        UserDefaults.standard.set(Date(), forKey: "backgroundCheckStarted")
        do {
            let preferences = UserDefaults.standard
            guard let ipaPath = preferences.string(forKey: "ipaPath"),
                  FileManager.default.fileExists(atPath: ipaPath) else {
                for udid in DeviceSelectionStore.load(from: .standard) {
                    RefreshStatusStore.record(udid, state: "续签配置不完整", failure: "等待用户在 AutoSign 中选择 IPA")
                }
                BackgroundRefreshManager.record("等待用户在 AutoSign 中选择 IPA")
                return
            }
            guard let profilePath = preferences.string(forKey: "profilePath"),
                  FileManager.default.fileExists(atPath: profilePath) else {
                for udid in DeviceSelectionStore.load(from: .standard) {
                    RefreshStatusStore.record(udid, state: "续签配置不完整", failure: "找不到上次使用的描述文件")
                }
                BackgroundRefreshManager.record("找不到上次使用的描述文件")
                return
            }
            let targetUDIDs = DeviceSelectionStore.load(from: preferences)
            guard !targetUDIDs.isEmpty else {
                BackgroundRefreshManager.record("等待用户完成一次手动安装")
                return
            }

            let sourceProfile = URL(fileURLWithPath: profilePath)
            let oldProfile = try await SigningService.readProfile(at: sourceProfile)
            let remaining = oldProfile.expirationDate.timeIntervalSinceNow
            let renewalDue = remaining <= renewalWindow
            let targetSet = Set(targetUDIDs)
            let pendingSet = Set(DeviceSelectionStore.loadPending(from: preferences)).intersection(targetSet)
            DeviceSelectionStore.savePending(targetUDIDs.filter { pendingSet.contains($0) }, to: preferences)
            guard renewalDue || !pendingSet.isEmpty else {
                let days = max(1, Int(ceil(remaining / 86_400)))
                for udid in targetUDIDs {
                    RefreshStatusStore.record(udid, state: "未到续签窗口（描述文件剩余约 \(days) 天）", nextEligible: oldProfile.expirationDate.addingTimeInterval(-renewalWindow))
                }
                BackgroundRefreshManager.record("当前描述文件剩余约 \(days) 天，未到续签窗口；设备安装状态见各设备记录")
                return
            }

            let devices = try await DeviceService.connectedDevices()
            let candidateUDIDs = renewalDue ? targetUDIDs : targetUDIDs.filter { pendingSet.contains($0) }
            let connectedDevices = candidateUDIDs.compactMap { udid in
                devices.first(where: { $0.udid == udid && $0.isConnected })
            }
            for udid in candidateUDIDs {
                let device = devices.first { $0.udid == udid }
                if device?.isConnected != true {
                    RefreshStatusStore.record(udid, name: device?.name, state: "等待设备连接", failure: "设备未连接，下一次后台检查时重试。")
                } else if device?.developerModeEnabled != true {
                    RefreshStatusStore.record(udid, name: device?.name, state: "需要开启开发者模式", failure: "请在设备设置中开启开发者模式。")
                }
            }
            let unavailableCount = candidateUDIDs.count - connectedDevices.count
            let readyDevices = connectedDevices.filter(\.developerModeEnabled)
            let developerModeDisabledCount = connectedDevices.count - readyDevices.count
            guard !readyDevices.isEmpty else {
                var reasons: [String] = []
                if unavailableCount > 0 { reasons.append("\(unavailableCount) 台未连接") }
                if developerModeDisabledCount > 0 { reasons.append("\(developerModeDisabledCount) 台未开启开发者模式") }
                let detail = reasons.isEmpty ? "未发现可用设备" : reasons.joined(separator: "，")
                BackgroundRefreshManager.record("没有可续签的已选设备：\(detail)，30 分钟后重试")
                return
            }

            var activeProfileURL = sourceProfile
            var preparedDevices: [AppleDevice] = []
            var failures: [String] = []
            var shouldForceRefresh = renewalDue
            for (index, device) in readyDevices.enumerated() {
                do {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "正在请求续签")
                    activeProfileURL = try await SigningService.ensureUsableProfile(
                        at: activeProfileURL, for: device, forceRefresh: shouldForceRefresh
                    ) { message in
                        BackgroundRefreshManager.record("[\(index + 1)/\(readyDevices.count)] \(message)")
                    }
                    shouldForceRefresh = false
                    preparedDevices.append(device)
                } catch {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "续签失败", failure: error.localizedDescription)
                    failures.append("\(device.name)：\(error.localizedDescription)")
                }
            }
            guard !preparedDevices.isEmpty else {
                let message = "自动续签失败：\(failures.joined(separator: "；"))"
                BackgroundRefreshManager.record(message)
                await BackgroundRefreshManager.notify(title: "AutoSign 自动续签失败", body: message)
                return
            }

            let renewedProfile = try await SigningService.readProfile(at: activeProfileURL)
            let didRenew = oldProfile.isExpired || renewedProfile.expirationDate > oldProfile.expirationDate

            // Never reinstall without a later expiry when handling a scheduled renewal.
            if renewalDue && !didRenew && pendingSet.isEmpty {
                for device in preparedDevices {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "等待 Apple 发放新描述文件")
                }
                var message = "已进入续期窗口，等待 Apple 发放新签名"
                if unavailableCount > 0 { message += "；\(unavailableCount) 台设备未连接" }
                if !failures.isEmpty { message += "；\(failures.joined(separator: "；"))" }
                BackgroundRefreshManager.record(message)
                return
            }

            var remainingPending = didRenew ? targetSet : pendingSet
            DeviceSelectionStore.savePending(
                targetUDIDs.filter { remainingPending.contains($0) }, to: preferences
            )
            preferences.set(activeProfileURL.path, forKey: "profilePath")

            let installSet = didRenew ? targetSet : pendingSet
            let devicesToInstall = preparedDevices.filter { installSet.contains($0.udid) }
            guard !devicesToInstall.isEmpty else {
                BackgroundRefreshManager.record("待更新设备当前未连接或不可用，30 分钟后重试")
                return
            }

            let identities = try await SigningService.identities()
            guard let identity = SigningService.identity(for: renewedProfile, available: identities,
                                                         preferredID: preferences.string(forKey: "identityID")) else {
                throw AutoSignError.missingSelection("续期后仍未找到 Apple Development 证书。")
            }
            preferences.set(identity.id, forKey: "identityID")
            let backgroundFolder = try BackgroundRefreshManager.applicationSupportURL()
                .appendingPathComponent("Background", isDirectory: true)
            var completedDevices: [AppleDevice] = []
            for (index, device) in devicesToInstall.enumerated() {
                do {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "正在签名并安装")
                    let output = backgroundFolder.appendingPathComponent("last-signed-\(device.udid).ipa")
                    _ = try await SigningService.signAndInstall(
                        ipa: URL(fileURLWithPath: ipaPath),
                        profileURL: activeProfileURL,
                        identity: identity,
                        device: device,
                        outputIPA: output
                    ) { _, message in
                        BackgroundRefreshManager.record("[\(index + 1)/\(devicesToInstall.count)] \(device.name)：\(message)")
                    }
                    RefreshStatusStore.record(device.udid, name: device.name, state: "自动续签成功", expiration: renewedProfile.expirationDate, success: true)
                    completedDevices.append(device)
                    remainingPending.remove(device.udid)
                } catch {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "续签失败", failure: error.localizedDescription)
                    failures.append("\(device.name)：\(error.localizedDescription)")
                }
            }
            DeviceSelectionStore.savePending(
                targetUDIDs.filter { remainingPending.contains($0) }, to: preferences
            )

            let names = completedDevices.map(\.name).joined(separator: "、")
            var status = "已通过 Wi‑Fi 自动续签并安装到 \(completedDevices.count) 台设备"
            if !names.isEmpty { status += "：\(names)" }
            if unavailableCount > 0 { status += "；\(unavailableCount) 台未连接，稍后重试" }
            if developerModeDisabledCount > 0 { status += "；\(developerModeDisabledCount) 台未开启开发者模式" }
            if !failures.isEmpty { status += "；失败：\(failures.joined(separator: "；"))" }
            BackgroundRefreshManager.record(status)

            if completedDevices.isEmpty {
                await BackgroundRefreshManager.notify(title: "AutoSign 自动续签失败", body: status)
            } else if failures.isEmpty && unavailableCount == 0 && developerModeDisabledCount == 0 {
                await BackgroundRefreshManager.notify(
                    title: "AutoSign 自动续签成功", body: "已更新 \(completedDevices.count) 台设备上的应用。"
                )
            } else {
                await BackgroundRefreshManager.notify(title: "AutoSign 自动续签部分完成", body: status)
            }
        } catch {
            for udid in DeviceSelectionStore.load(from: .standard) {
                RefreshStatusStore.record(udid, state: "后台检查失败", failure: error.localizedDescription)
            }
            BackgroundRefreshManager.record("自动续签失败：\(error.localizedDescription)")
            await BackgroundRefreshManager.notify(title: "AutoSign 自动续签失败", body: error.localizedDescription)
        }
    }
}
