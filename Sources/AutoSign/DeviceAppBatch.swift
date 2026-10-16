import AutoSignLocalization
import Foundation

struct SourceAppSelection: Identifiable, Sendable {
    let sourceURL: String
    let app: SourceApp
    var id: String { app.id }
}

enum DeviceAppOperation: Sendable {
    case install, refresh

    var title: String { self == .install ? L10n.tr("安装") : L10n.tr("续签") }
}

@MainActor
enum DeviceAppBatch {
    @MainActor struct Dependencies {
        var records: () throws -> [StoreRecord] = { try StoreLibrary.records() }
        var originalID: @Sendable (URL) async -> String? = { try? await AppSourceService.packageBundleIdentifier(at: $0) }
        var install: @MainActor (StoreInstallRequest, SourceAppVersion, UserDefaults,
                      @escaping @MainActor @Sendable (String) -> Void) async throws -> Date = {
            try await StoreInstallService.install($0, version: $1, preferences: $2, statusChanged: $3)
        }
        var refresh: @MainActor (StoreRecord, AppleDevice, RefreshVerificationOptions,
                      @escaping @MainActor @Sendable (String) -> Void) async throws -> AppRefreshResult = {
            try await AppRefreshService.refresh($0, on: $1, verification: $2, statusChanged: $3)
        }
    }

    static func managedApps(on device: AppleDevice, dependencies: Dependencies) async throws -> [String: StoreRecord] {
        let records = try dependencies.records().filter { $0.app.deviceUDID == device.udid }
        var result: [String: StoreRecord] = [:]
        for record in records {
            let sourceID: String
            if let known = record.sourceBundleIdentifier { sourceID = known }
            else { sourceID = await dependencies.originalID(URL(fileURLWithPath: record.ipaPath)) ?? record.app.bundleIdentifier }
            result[sourceID] = record
        }
        return result
    }

    static func run(_ selections: [SourceAppSelection], operation: DeviceAppOperation, on device: AppleDevice,
                    library: SourceLibraryModel, preferences: UserDefaults, dependencies: Dependencies,
                    itemChanged: @escaping @MainActor @Sendable (RefreshItem) -> Void) async -> [RefreshItem] {
        // Preserve the selection order while handling the phone client last.
        let managed = (try? await managedApps(on: device, dependencies: dependencies)) ?? [:]
        let ordered = selections.filter { managed[$0.id]?.app.isStore != true }
            + selections.filter { managed[$0.id]?.app.isStore == true }
        var results: [RefreshItem] = []
        let verification = RefreshVerificationOptions.load(from: preferences)
        for selection in ordered {
            var item = RefreshItem(id: selection.id, name: selection.app.name, state: .running,
                                   message: L10n.tr("正在\(operation.title)…"))
            itemChanged(item)
            let progress: @MainActor @Sendable (String) -> Void = { message in
                itemChanged(RefreshItem(id: selection.id, name: selection.app.name, state: .running, message: message))
            }
            var installedApp: StoreApp?
            do {
                try Task.checkCancellation()
                let records = try dependencies.records()
                let existing = await StoreInstallService.existingRecord(sourceID: selection.id, deviceUDID: device.udid,
                    records: records, originalID: dependencies.originalID)
                installedApp = existing?.app
                if operation == .install {
                    guard library.sources.contains(where: { $0.id == selection.sourceURL }) else {
                        throw AppSourceError.invalid(L10n.tr("应用源已移除，请重新选择应用。"))
                    }
                    progress(L10n.tr("正在检查源中的最新版本…"))
                    let source = try await library.fetchAndSaveSource(selection.sourceURL, forDeviceOperation: true)
                    guard let version = source.catalog.apps.first(where: { $0.id == selection.id })?.latestVersion else {
                        throw AppSourceError.invalid(L10n.tr("源中已没有这个应用的可下载版本，请刷新列表。"))
                    }
                    let input = StoreInstallRequest(requestID: UUID().uuidString, deviceUDID: device.udid,
                        sourceURL: selection.sourceURL, bundleIdentifier: selection.id)
                    item.expiration = try await dependencies.install(input, version, preferences, progress)
                    item.message = L10n.tr("已安装 \(version.displayVersion)")
                } else {
                    guard let existing else {
                        throw AutoSignError.missingSelection(L10n.tr("此设备没有该应用的安装记录，请先安装。"))
                    }
                    RefreshStatusStore.recordApp(existing.app, state: L10n.tr("正在手动续签"), preferences: preferences)
                    let result = try await dependencies.refresh(existing, device, verification, progress)
                    guard result.expiration > existing.app.expiration, result.expiration > Date() else {
                        throw AutoSignError.invalidProfile(L10n.tr("新的描述文件没有延长有效期，已保留原续签记录。"))
                    }
                    item.expiration = result.expiration
                    item.message = result.message
                }
                item.state = .completed
                if let app = try dependencies.records().first(where: {
                    $0.app.deviceUDID == device.udid && ($0.sourceBundleIdentifier == selection.id || $0.app.id == installedApp?.id)
                })?.app {
                    RefreshStatusStore.recordApp(app, state: item.message, expiration: item.expiration,
                                                 success: true, preferences: preferences)
                }
            } catch {
                item.state = .failed
                item.message = error.localizedDescription
                if let installedApp {
                    RefreshStatusStore.recordApp(installedApp, state: L10n.tr("手动\(operation.title)失败"),
                                                 failure: item.message, preferences: preferences)
                }
            }
            results.append(item)
            itemChanged(item)
        }
        return results
    }
}
