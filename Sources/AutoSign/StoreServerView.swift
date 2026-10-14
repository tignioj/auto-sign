import SwiftUI

struct StoreServerView: View {
    @ObservedObject private var server = StoreServer.shared
    @State private var showToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AutoSign Store · 手机安装与续签", systemImage: "wifi")
                    .font(.headline)
                Spacer()
                Toggle("开启局域网服务", isOn: Binding(get: { server.isEnabled }, set: { server.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(server.isBusy)
            }
            Text(server.status).font(.callout).foregroundStyle(server.isEnabled ? .cyan : .secondary)
            if server.isEnabled {
                LabeledContent("连接地址") {
                    Text(server.address).textSelection(.enabled).font(.callout.monospaced())
                    Button("复制") { copy(server.address) }
                }
                HStack {
                    Text("配对密钥")
                    Spacer()
                    if showToken { Text(server.token).font(.caption.monospaced()).textSelection(.enabled) }
                    Button(showToken ? "隐藏" : "显示") { showToken.toggle() }
                    Button("复制密钥") { copy(server.token) }
                    Button("重置密钥") { server.rotateToken() }.disabled(server.isBusy)
                }
                Text("手机与 Mac 连接同一可信局域网，在 AutoSign Store 中发现此 Mac、输入密钥并选择本机设备。服务使用局域网 HTTP；请勿映射到公网。Mac 需要保持运行。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("手机可添加应用源、浏览并选择应用，由 Mac 自动下载、配置签名并安装。新应用使用当前选定的签名团队，安装后保留原始 IPA 和独立描述文件以供续签；升级保留原应用标识和团队。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
