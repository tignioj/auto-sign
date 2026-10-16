import AutoSignLocalization
import Foundation

struct StoreRefreshPlan {
    let job: RefreshJob
    let records: [StoreRecord]
    let isExisting: Bool
}

enum StoreJobPlanner {
    static func plan(_ input: RefreshRequest, records: [StoreRecord], jobs: [RefreshJob], isBusy: Bool) throws -> StoreRefreshPlan {
        guard UUID(uuidString: input.requestID) != nil, !input.appIDs.isEmpty, input.appIDs.count <= 50,
              Set(input.appIDs).count == input.appIDs.count else {
            throw StoreHTTPError(status: 400, message: L10n.tr("请选择 1–50 个应用并提供唯一请求编号。"))
        }
        if let existing = jobs.first(where: { $0.requestID == input.requestID }) {
            guard existing.installRequest == nil, existing.updateRequest == nil, existing.deviceUDID == input.deviceUDID, Set(existing.items.map(\.id)) == Set(input.appIDs) else {
                throw StoreHTTPError(status: 409, message: L10n.tr("请求编号已用于其他任务。"))
            }
            return StoreRefreshPlan(job: existing, records: [], isExisting: true)
        }
        guard !isBusy else { throw StoreHTTPError(status: 409, message: L10n.tr("Mac 正在处理应用任务，请等待当前任务结束。")) }
        let selected = try input.appIDs.map { id -> StoreRecord in
            guard let record = records.first(where: { $0.app.id == id && $0.app.deviceUDID == input.deviceUDID }) else {
                throw StoreHTTPError(status: 404, message: L10n.tr("应用不属于所选设备，请重新同步。"))
            }
            return record
        }
        // A stable partition keeps the user's order while ensuring self-install is always last.
        let ordered = selected.filter { !$0.app.isStore } + selected.filter { $0.app.isStore }
        let job = RefreshJob(id: UUID().uuidString, requestID: input.requestID, deviceUDID: input.deviceUDID,
            state: .queued, items: ordered.map { RefreshItem(id: $0.app.id, name: $0.app.name, state: .queued, message: L10n.tr("等待刷新")) },
            createdAt: Date(), updatedAt: Date())
        return StoreRefreshPlan(job: job, records: ordered, isExisting: false)
    }

    static func existingInstall(_ input: StoreInstallRequest, jobs: [RefreshJob]) throws -> RefreshJob? {
        guard UUID(uuidString: input.requestID) != nil, !input.deviceUDID.isEmpty,
              SigningService.isValidBundleIdentifier(input.bundleIdentifier) else {
            throw StoreHTTPError(status: 400, message: L10n.tr("安装参数或请求编号无效。"))
        }
        if let existing = jobs.first(where: { $0.requestID == input.requestID }) {
            guard existing.installRequest == input else {
                throw StoreHTTPError(status: 409, message: L10n.tr("请求编号已用于其他任务。"))
            }
            return existing
        }
        return nil
    }

    static func existingUpdate(_ input: RefreshRequest, jobs: [RefreshJob]) throws -> RefreshJob? {
        guard UUID(uuidString: input.requestID) != nil, !input.deviceUDID.isEmpty, !input.appIDs.isEmpty,
              input.appIDs.count <= 50, Set(input.appIDs).count == input.appIDs.count else {
            throw StoreHTTPError(status: 400, message: L10n.tr("请选择 1–50 个应用并提供唯一请求编号。"))
        }
        guard let existing = jobs.first(where: { $0.requestID == input.requestID }) else { return nil }
        guard let previous = existing.updateRequest, previous.deviceUDID == input.deviceUDID,
              Set(previous.appIDs) == Set(input.appIDs) else {
            throw StoreHTTPError(status: 409, message: L10n.tr("请求编号已用于其他任务。"))
        }
        return existing
    }

    static func planUpdates(_ input: RefreshRequest, records: [StoreRecord], updates: [StoreAppUpdate],
                            jobs: [RefreshJob], isBusy: Bool) throws -> StoreRefreshPlan {
        if let existing = try existingUpdate(input, jobs: jobs) {
            return StoreRefreshPlan(job: existing, records: [], isExisting: true)
        }
        guard !isBusy else { throw StoreHTTPError(status: 409, message: L10n.tr("Mac 正在处理应用任务，请等待当前任务结束。")) }
        let selected = try input.appIDs.map { id -> StoreRecord in
            guard let record = records.first(where: { $0.app.id == id && $0.app.deviceUDID == input.deviceUDID }),
                  updates.contains(where: { $0.id == id && $0.deviceUDID == input.deviceUDID }) else {
                throw StoreHTTPError(status: 409, message: L10n.tr("应用已是最新版本或源已变更，请重新检查更新。"))
            }
            return record
        }
        let ordered = selected.filter { !$0.app.isStore } + selected.filter { $0.app.isStore }
        let job = RefreshJob(id: UUID().uuidString, requestID: input.requestID, deviceUDID: input.deviceUDID,
            state: .queued, items: ordered.map { RefreshItem(id: $0.app.id, name: $0.app.name, state: .queued, message: L10n.tr("等待更新")) },
            createdAt: Date(), updatedAt: Date(), updateRequest: input)
        return StoreRefreshPlan(job: job, records: ordered, isExisting: false)
    }

    static func planInstall(_ input: StoreInstallRequest, sources: [SavedAppSource], devices: [AppleDevice],
                            jobs: [RefreshJob], isBusy: Bool) throws -> RefreshJob {
        if let existing = try existingInstall(input, jobs: jobs) { return existing }
        guard !isBusy else { throw StoreHTTPError(status: 409, message: L10n.tr("Mac 正在处理应用任务，请等待当前任务结束。")) }
        let url = try AppSourceService.sourceURL(from: input.sourceURL)
        guard url.absoluteString == input.sourceURL,
              let source = sources.first(where: { $0.url == url }),
              let app = source.catalog.apps.first(where: { $0.id == input.bundleIdentifier }), app.latestVersion != nil else {
            throw StoreHTTPError(status: 404, message: L10n.tr("请先添加或刷新源，再选择可下载的应用。"))
        }
        guard devices.contains(where: { $0.udid == input.deviceUDID && $0.isPaired && $0.isReadyForInstallation }) else {
            throw StoreHTTPError(status: 400, message: L10n.tr("所选设备未配对或尚未就绪。"))
        }
        return RefreshJob(id: UUID().uuidString, requestID: input.requestID, deviceUDID: input.deviceUDID,
            state: .queued, items: [RefreshItem(id: app.id, name: app.name, state: .queued, message: L10n.tr("等待下载并安装"))],
            createdAt: Date(), updatedAt: Date(), installRequest: input)
    }

    static func recoverInterrupted(_ jobs: [RefreshJob]) -> [RefreshJob] {
        jobs.map { original in
            guard !original.state.isTerminal else { return original }
            var job = original
            job.state = .failed
            job.updatedAt = Date()
            for item in job.items.indices where !job.items[item].state.isTerminal {
                job.items[item].state = .failed
                job.items[item].message = L10n.tr("Mac 服务曾退出，请重新发起任务；到期时间以已确认签名记录为准。")
            }
            return job
        }
    }
}
