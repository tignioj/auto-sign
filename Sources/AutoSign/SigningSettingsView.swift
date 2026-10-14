import SwiftUI

struct SigningSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            AppCard(title: "Xcode 账号", symbol: "person.crop.circle") {
                HStack {
                    Text(model.accountStatus.title).font(.headline)
                    Spacer()
                    Button("刷新账号与证书") { Task { await model.refresh() } }
                        .disabled(model.isBusy)
                }
                Text(model.accountStatus.detail).font(.caption).foregroundStyle(.secondary)
                Text("请在 Xcode → Settings → Accounts 中管理 Apple ID。如需重新登录或接受开发者协议，请先在 Xcode 中完成。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            signingSection
        }
    }

    private var signingSection: some View {
        AppCard(title: "证书与描述文件", symbol: "signature") {
            VStack(spacing: 12) {
                settingRow(title: "签名证书", symbol: "person.text.rectangle") {
                    if model.identities.isEmpty {
                        Text("未找到证书；安装时将尝试通过 Xcode 自动创建").foregroundStyle(.orange).font(.callout)
                    } else {
                        Picker("", selection: Binding(get: { model.selectedIdentityID }, set: { model.rememberIdentity($0) })) {
                            ForEach(model.identities) { identity in Text(identity.name).tag(Optional(identity.id)) }
                        }.labelsHidden().frame(maxWidth: 440)
                    }
                }
                Divider().opacity(0.35)
                settingRow(title: "描述文件", symbol: "doc.badge.gearshape") {
                    Text(model.profileURL?.lastPathComponent ?? "首次安装请选择描述文件以确定签名团队")
                        .font(.callout).foregroundStyle(model.profileURL == nil ? .secondary : .primary).lineLimit(1)
                    Button("选择…") { model.chooseProfile() }
                }
                Text("首次安装使用所选描述文件的签名团队，为每个应用单独生成描述文件；续签使用各应用已保存的团队和证书。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.isBusy)
        }
    }

    private func settingRow<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.cyan).frame(width: 24)
            Text(title).font(.callout.weight(.medium)).frame(width: 80, alignment: .leading)
            Spacer()
            content()
        }.frame(minHeight: 32)
    }

}
