import AutoSignLocalization
import Foundation

@MainActor
enum BackgroundRefreshCoordinator {
    nonisolated static let renewalWindow: TimeInterval = 24 * 60 * 60

    struct Dependencies {
        var records: () throws -> [StoreRecord] = { try StoreLibrary.records() }
        var devices: () async throws -> [AppleDevice] = { try await DeviceService.connectedDevices() }
        var refresh: (StoreRecord, AppleDevice, RefreshVerificationOptions,
                      @escaping @MainActor @Sendable (String) -> Void) async throws -> AppRefreshResult = {
            try await AppRefreshService.refresh($0, on: $1, verification: $2, statusChanged: $3)
        }
        var log: @MainActor @Sendable (String) -> Void = { BackgroundRefreshManager.record($0) }
        var notify: (String, String) async -> Void = { await BackgroundRefreshManager.notify(title: $0, body: $1) }
    }

    private struct DeviceSummary {
        var expirations: [String: Date] = [:]
        var completed = 0
        var skipped = 0
        var waiting = 0
        var failures: [String] = []
        var waitingReasons: [String] = []

        var message: String {
            guard !expirations.isEmpty else { return L10n.tr("暂无应用记录，请先通过 AutoSign 安装应用") }
            return L10n.tr("已检查 \(expirations.count) 个应用：续签成功 \(completed)，未到窗口 \(skipped)，等待设备 \(waiting)，失败 \(failures.count)")
        }
    }

    static func run(preferences: UserDefaults = .standard, now: Date = Date(),
                    dependencies: Dependencies = Dependencies()) async {
        preferences.set(now, forKey: "backgroundCheckStarted")
        let removedUDIDs = DeviceRemovalStore.removedUDIDs(from: preferences)
        let targets = DeviceSelectionStore.load(from: preferences).filter { !removedUDIDs.contains($0) }
        guard !targets.isEmpty else {
            dependencies.log(L10n.tr("等待用户选择自动续签设备"))
            return
        }
        let targetSet = Set(targets)
        do {
            let verification = RefreshVerificationOptions.load(from: preferences)
            // Each installation has its own profile and expiry, including the same app on different devices.
            let records = try dependencies.records().filter { targetSet.contains($0.app.deviceUDID) }.sorted {
                if $0.app.isStore != $1.app.isStore { return !$0.app.isStore }
                if $0.app.expiration != $1.app.expiration { return $0.app.expiration < $1.app.expiration }
                return $0.app.id < $1.app.id
            }
            let hasDueApps = records.contains { $0.app.expiration <= now.addingTimeInterval(renewalWindow) }
            let devices = hasDueApps ? try await dependencies.devices() : []
            var summaries = Dictionary(uniqueKeysWithValues: targets.map { ($0, DeviceSummary()) })

            for (index, planned) in records.enumerated() {
                try Task.checkCancellation()
                let udid = planned.app.deviceUDID
                var app = planned.app
                do {
                    // A phone/manual refresh may have completed since the initial snapshot.
                    guard let current = try dependencies.records().first(where: {
                        $0.app.id == app.id && $0.app.deviceUDID == udid
                    }) else { continue }
                    // The GUI may remove a device during discovery or while another app is refreshing.
                    guard DeviceSelectionStore.load(from: preferences).contains(udid),
                          !DeviceRemovalStore.removedUDIDs(from: preferences).contains(udid) else { continue }
                    app = current.app
                    summaries[udid]?.expirations[app.id] = app.expiration
                    guard app.expiration <= now.addingTimeInterval(renewalWindow) else {
                        RefreshStatusStore.recordApp(app, state: L10n.tr("未到续签窗口"), preferences: preferences)
                        summaries[udid]?.skipped += 1
                        continue
                    }

                    let device = devices.first { $0.udid == udid }
                    let waitReason: String?
                    if device?.isConnected != true { waitReason = L10n.tr("设备未连接，下一次后台检查时重试。") }
                    else if device?.isPaired != true { waitReason = L10n.tr("请先将设备与此 Mac 配对。") }
                    else if device?.developerModeEnabled != true { waitReason = L10n.tr("请在设备设置中开启开发者模式。") }
                    else { waitReason = nil }
                    guard let device, waitReason == nil else {
                        let reason = waitReason ?? L10n.tr("等待设备就绪")
                        RefreshStatusStore.recordApp(app, state: L10n.tr("等待设备就绪"), failure: reason, preferences: preferences)
                        summaries[udid]?.waiting += 1
                        summaries[udid]?.waitingReasons.append("\(app.name)：\(reason)")
                        continue
                    }

                    RefreshStatusStore.recordApp(app, state: L10n.tr("正在请求续签"), preferences: preferences)
                    let label = "[\(index + 1)/\(records.count)] \(device.name) · \(app.name)"
                    let log = dependencies.log
                    let result = try await dependencies.refresh(current, device, verification) { message in
                        log("\(label)：\(message)")
                    }
                    guard result.expiration > app.expiration, result.expiration > now else {
                        throw AutoSignError.invalidProfile(L10n.tr("新的描述文件没有延长有效期，已保留原续签记录。"))
                    }
                    RefreshStatusStore.recordApp(app, state: result.message, expiration: result.expiration,
                                                 success: true, preferences: preferences)
                    summaries[udid]?.expirations[app.id] = result.expiration
                    summaries[udid]?.completed += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A failed refresh leaves the installed expiry unchanged, so it is due again next check.
                    RefreshStatusStore.recordApp(app, state: L10n.tr("续签失败"), failure: error.localizedDescription, preferences: preferences)
                    summaries[udid]?.expirations[app.id] = app.expiration
                    summaries[udid]?.failures.append("\(app.name)：\(error.localizedDescription)")
                }
            }

            for udid in targets {
                guard !DeviceRemovalStore.removedUDIDs(from: preferences).contains(udid) else { continue }
                guard let summary = summaries[udid] else { continue }
                let expiration = summary.expirations.values.min()
                let errors = summary.failures + summary.waitingReasons
                RefreshStatusStore.record(udid, name: devices.first { $0.udid == udid }?.name, state: summary.message,
                    failure: errors.isEmpty ? nil : errors.joined(separator: "；"), expiration: expiration,
                    nextEligible: expiration?.addingTimeInterval(-renewalWindow), success: summary.completed > 0,
                    preferences: preferences)
            }
            let total = summaries.values.reduce(0) { $0 + $1.expirations.count }
            let completed = summaries.values.reduce(0) { $0 + $1.completed }
            let skipped = summaries.values.reduce(0) { $0 + $1.skipped }
            let waiting = summaries.values.reduce(0) { $0 + $1.waiting }
            let failures = targets.flatMap { udid in
                (summaries[udid]?.failures ?? []).map { "\(devices.first { $0.udid == udid }?.name ?? udid) · \($0)" }
            }
            var message = L10n.tr("已检查 \(targets.count) 台已选设备的 \(total) 个应用：续签成功 \(completed)，未到窗口 \(skipped)，等待设备 \(waiting)，失败 \(failures.count)")
            if total == 0 { message += L10n.tr("；请先通过 AutoSign 安装应用以保存续签记录") }
            if waiting > 0 { message += L10n.tr("；等待设备就绪后在后续检查中重试") }
            if !failures.isEmpty { message += "；" + failures.joined(separator: "；") }
            dependencies.log(message)
            if completed > 0 {
                let title = failures.isEmpty && waiting == 0 ? L10n.tr("AutoSign 自动续签成功") : L10n.tr("AutoSign 自动续签部分完成")
                await dependencies.notify(title, message)
            } else if !failures.isEmpty {
                await dependencies.notify(L10n.tr("AutoSign 自动续签失败"), message)
            }
        } catch is CancellationError {
            dependencies.log(L10n.tr("后台检查已取消，下次检查将继续处理到期应用"))
        } catch {
            for udid in targets {
                guard !DeviceRemovalStore.removedUDIDs(from: preferences).contains(udid) else { continue }
                RefreshStatusStore.record(udid, state: L10n.tr("后台检查失败"), failure: error.localizedDescription, preferences: preferences)
            }
            dependencies.log(L10n.tr("自动续签失败：\(error.localizedDescription)"))
            await dependencies.notify(L10n.tr("AutoSign 自动续签失败"), error.localizedDescription)
        }
    }
}
