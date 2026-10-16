import SwiftUI

struct IndependentAccountView: View {
    @ObservedObject private var account = IndependentAccountModel.shared
    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var anisetteServer = UserDefaults.standard.string(forKey: WindowsAnisetteProvider.serverKey) ?? ""

    var body: some View {
        AppCard(title: "AutoSign 独立 Apple 账号", symbol: "person.badge.key.fill") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设备认证服务").font(.subheadline.weight(.medium))
                    Text(WindowsAnisetteProvider.configuredURL.map { "当前：" + ($0.host ?? $0.absoluteString) } ?? "当前：本机设备认证")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Apple 当前可能拒绝本机认证并返回 -80045。可填写自己托管的 Windows Anisette v3 服务。服务会接收独立生成的设备身份与认证资料；Apple 账号、密码、验证码和签名私钥只在本机与 Apple 之间使用。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("自托管服务地址", text: $anisetteServer).autocorrectionDisabled()
                        Button("启用此服务") { account.configureWindowsAnisette(anisetteServer) }
                        Button("使用本机认证") { account.configureWindowsAnisette(nil) }
                    }.disabled(account.isBusy || account.summary != nil)
                    if account.summary != nil {
                        Text("退出独立账号后可更换设备认证服务。").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                if let summary = account.summary {
                    Text(summary.name + " · " + summary.email).font(.headline)
                    Picker("签名团队", selection: $account.selectedTeamID) {
                        ForEach(summary.teams) { team in
                            Text(team.name + (team.isFree ? "（免费账号）" : "")).tag(team.id)
                        }
                    }.disabled(account.isBusy)
                    Text("续签始终沿用每个应用原有的团队、应用标识和证书。").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Apple 账号（电子邮件）", text: $email).textContentType(.username)
                    .autocorrectionDisabled().disabled(account.isBusy)
                SecureField("Apple 账号密码", text: $password).textContentType(.password).disabled(account.isBusy)
                HStack {
                    Button(account.summary == nil ? "登录并启用独立续签" : "重新登录") {
                        let submittedPassword = password
                        password = ""
                        Task { await account.signIn(email: email, password: submittedPassword) }
                    }.disabled(account.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    if account.summary != nil {
                        Button("退出独立账号") { account.signOut() }.disabled(account.isBusy)
                    }
                    if account.isBusy { ProgressView().controlSize(.small) }
                }
                if account.needsVerification {
                    HStack {
                        TextField("六位 Apple 验证码", text: $verificationCode).frame(maxWidth: 180)
                            .onSubmit { account.submitVerification(verificationCode); verificationCode = "" }
                        Button("验证") { account.submitVerification(verificationCode); verificationCode = "" }
                        Button("取消") { account.cancelVerification() }
                    }
                }
                Text(account.status).font(.callout).textSelection(.enabled)
                Text("支持免费 Apple 账号。密码、会话和设备认证资料加密保存在系统登录钥匙串，由 AutoSign 的代码签名限制访问。重启后先登录 Mac，并保持登录钥匙串解锁；屏幕可以锁定。自动锁屏设置保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { if email.isEmpty { email = account.summary?.email ?? "" } }
        }
    }
}
