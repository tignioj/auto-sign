import SwiftUI

struct SigningSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var independentAccount = IndependentAccountModel.shared

    var body: some View {
        VStack(spacing: 20) {
            IndependentAccountView()
            if independentAccount.summary == nil {
                AppCard(title: "Xcode 兼容模式", symbol: "person.crop.circle") {
                    HStack {
                        Text(model.accountStatus.title).font(.headline)
                        Spacer()
                        Button("刷新账号与证书") { Task { await model.refresh() } }
                            .disabled(model.isBusy)
                    }
                    Text(model.accountStatus.detail).font(.caption).foregroundStyle(.secondary)
                    Text("此模式通过 Xcode 账号签发，锁屏时需等待解锁。登录上方独立账号后，续签改由 AutoSign 直接请求 Apple。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            signingSection
        }
    }

    private var signingSection: some View {
        AppCard(title: "证书与描述文件", symbol: "signature") {
            VStack(spacing: 12) {
                settingRow(title: "签名证书", symbol: "person.text.rectangle") {
                    if model.identities.isEmpty {
                        Text(IndependentAccountModel.isEnabled ? "首次安装时由独立账号创建签名证书" : "未找到证书；安装时将尝试通过 Xcode 自动创建")
                            .foregroundStyle(.orange).font(.callout)
                    } else {
                        Picker("", selection: Binding(get: { model.selectedIdentityID }, set: { model.rememberIdentity($0) })) {
                            ForEach(model.identities) { identity in Text(identity.name).tag(Optional(identity.id)) }
                        }.labelsHidden().frame(maxWidth: 440)
                    }
                }
                Divider().opacity(0.35)
                settingRow(title: "描述文件", symbol: "doc.badge.gearshape") {
                    Text(IndependentAccountModel.isEnabled ? "由独立账号自动签发" : model.profileURL?.lastPathComponent ?? "首次安装请选择描述文件以确定签名团队")
                        .font(.callout).foregroundStyle(model.profileURL == nil ? .secondary : .primary).lineLimit(1)
                    if !IndependentAccountModel.isEnabled { Button("选择…") { model.chooseProfile() } }
                }
                Text(IndependentAccountModel.isEnabled ? "新安装使用上方所选团队，自动签发描述文件；已有应用续签沿用各自的团队和证书。" : "首次安装使用所选描述文件的签名团队，为每个应用单独生成描述文件；续签使用各应用已保存的团队和证书。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新本机证书") { Task { await model.refresh() } }
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
