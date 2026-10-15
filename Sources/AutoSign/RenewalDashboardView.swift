import SwiftUI

struct RenewalDashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var localNetwork = LocalNetworkAccess.shared
    @AppStorage(RefreshVerificationOptions.launchPreferenceKey) private var verifyLaunchAfterRefresh = false

    var body: some View {
        VStack(spacing: 20) {
            LocalNetworkAccessView()
            AppCard(title: "续签设置", symbol: "clock.arrow.circlepath") {
                HStack {
                    Toggle("为已安装的应用自动续签", isOn: Binding(
                        get: { model.autoRefreshEnabled }, set: { model.setAutoRefreshEnabled($0) }
                    ))
                    .toggleStyle(.switch).disabled(model.isBusy || model.isChangingAutoRefresh || localNetwork.isChecking)
                    Spacer()
                    Button("刷新状态") { Task { await model.refreshDashboard() } }
                }
                Text(model.schedulerStatus).font(.callout)
                Text("下次后台检查：" + nextCheckText).font(.callout)
                Text("每 30 分钟检查一次，每个应用在到期前 24 小时独立进入续签窗口。Mac 休眠、设备离线或 Apple 未发放新描述文件时会延后。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("刷新签名后验证应用启动", isOn: $verifyLaunchAfterRefresh)
                    .toggleStyle(.switch)
                Text("适用于手机发起的刷新和后台自动续签。关闭后不会自动启动应用，仍会校验描述文件和有效期；开启后会启动应用并检查进程。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AppCard(title: "设备与应用", symbol: "ipad.and.iphone") {
                Text("成功安装的应用按设备分别纳入自动续签。切换当前设备或应用选择不影响已有续签记录。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.renewalLibraryError {
                    Text("无法读取应用续签记录：" + error).font(.caption).foregroundStyle(.orange)
                }
                if model.renewalStatuses.isEmpty {
                    Text("暂无自动续签设备，请先安装应用").foregroundStyle(.secondary)
                }
                ForEach(model.renewalStatuses) { status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(status.name).font(.headline)
                            Spacer()
                            Text(status.state).foregroundStyle(status.failure == nil ? Color.cyan : Color.orange)
                        }
                        Text("最近记录：\(dateText(status.updatedAt))  ·  最近成功：\(dateText(status.lastSuccess))")
                        if let apps = model.appRenewalStatuses[status.id], !apps.isEmpty {
                            DisclosureGroup("\(apps.count) 个应用 · 最早到期：\(dateText(status.expiration))") {
                                VStack(spacing: 8) {
                                    ForEach(apps) { appStatus in
                                        appRenewalRow(appStatus)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        } else if model.renewalLibraryError == nil {
                            Text("暂无应用记录。通过 AutoSign 安装后将自动纳入续签。").foregroundStyle(.secondary)
                        }
                        if let failure = status.failure {
                            Text("失败原因：" + RefreshStatusStore.failureSummary(failure)).foregroundStyle(.orange)
                            DisclosureGroup("完整错误详情") {
                                Text(failure).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            AppCard(title: "后台检查记录", symbol: "clock") {
                DisclosureGroup("最近后台检查详情（含旧版本记录）") {
                    Text(model.lastBackgroundStatus).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func appRenewalRow(_ item: AppRenewalStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.app.name).fontWeight(.medium)
                Spacer()
                Text(item.status.state).foregroundStyle(item.status.failure == nil ? Color.cyan : Color.orange)
            }
            Text(item.app.bundleIdentifier).foregroundStyle(.secondary).textSelection(.enabled)
            Text("签名到期：\(dateText(item.app.expiration)) · 续签窗口：\(dateText(item.status.nextEligible))起")
            Text("下次续签：" + item.status.nextAttempt(check: model.nextBackgroundCheck, enabled: model.autoRefreshEnabled))
            Text("最近成功：\(dateText(item.status.lastSuccess))").foregroundStyle(.secondary)
            if let failure = item.status.failure {
                Text("失败原因：" + RefreshStatusStore.failureSummary(failure)).foregroundStyle(.orange)
                DisclosureGroup("完整错误详情") {
                    Text(failure).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }

    private var nextCheckText: String {
        guard model.autoRefreshEnabled else { return "已关闭" }
        guard let date = model.nextBackgroundCheck else { return "等待首次后台检查" }
        return date < Date() ? "计划时间已到，等待后台运行" : "预计 " + dateText(date)
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "暂无记录"
    }

}
