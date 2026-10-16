import AutoSignLocalization
import SwiftUI

struct LocalNetworkAccessView: View {
    @Environment(\.locale) private var locale
    @ObservedObject private var access = LocalNetworkAccess.shared

    var body: some View {
        // Recompute String-based translations when the app language changes.
        let _ = locale
        AppCard(title: L10n.tr("本地网络权限"), symbol: "network.badge.shield.half.filled") {
            Text(access.state.detail)
                .font(.callout)
                .foregroundStyle(access.state == .ready ? Color.cyan : Color.orange)
            Text(L10n.tr("用于通过局域网连接 iPhone / iPad，并在无人值守时续签。请在前台完成系统授权和检查，再开启后台任务。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if access.isChecking { ProgressView().controlSize(.small) }
                Button(access.isChecking ? L10n.tr("取消检查") : L10n.tr("检查本地网络权限")) {
                    if access.isChecking { access.cancel() }
                    else { Task { await access.check() } }
                }
                Button(L10n.tr("打开本地网络设置")) { access.openSettings() }
            }
        }
    }
}
