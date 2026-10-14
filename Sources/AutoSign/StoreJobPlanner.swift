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
            throw StoreHTTPError(status: 400, message: "请选择 1–50 个应用并提供唯一请求编号。")
        }
        if let existing = jobs.first(where: { $0.requestID == input.requestID }) {
            guard existing.deviceUDID == input.deviceUDID, Set(existing.items.map(\.id)) == Set(input.appIDs) else {
                throw StoreHTTPError(status: 409, message: "请求编号已用于其他任务。")
            }
            return StoreRefreshPlan(job: existing, records: [], isExisting: true)
        }
        guard !isBusy else { throw StoreHTTPError(status: 409, message: "Mac 正在刷新应用，请等待当前任务结束。") }
        let selected = try input.appIDs.map { id -> StoreRecord in
            guard let record = records.first(where: { $0.app.id == id && $0.app.deviceUDID == input.deviceUDID }) else {
                throw StoreHTTPError(status: 404, message: "应用不属于所选设备，请重新同步。")
            }
            return record
        }
        // A stable partition keeps the user's order while ensuring self-install is always last.
        let ordered = selected.filter { !$0.app.isStore } + selected.filter { $0.app.isStore }
        let job = RefreshJob(id: UUID().uuidString, requestID: input.requestID, deviceUDID: input.deviceUDID,
            state: .queued, items: ordered.map { RefreshItem(id: $0.app.id, name: $0.app.name, state: .queued, message: "等待刷新") },
            createdAt: Date(), updatedAt: Date())
        return StoreRefreshPlan(job: job, records: ordered, isExisting: false)
    }

    static func recoverInterrupted(_ jobs: [RefreshJob]) -> [RefreshJob] {
        jobs.map { original in
            guard !original.state.isTerminal else { return original }
            var job = original
            job.state = .failed
            job.updatedAt = Date()
            for item in job.items.indices where !job.items[item].state.isTerminal {
                job.items[item].state = .failed
                job.items[item].message = "Mac 服务曾退出，请重新发起刷新；到期时间以已确认安装记录为准。"
            }
            return job
        }
    }
}
