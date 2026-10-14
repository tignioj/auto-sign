import SwiftUI

struct StoreServerView: View {
    @ObservedObject private var server = StoreServer.shared
    @State private var showToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AutoSign Store · 手机续签", systemImage: "wifi")
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
                Text("成功安装的应用会自动保留原始 IPA 和独立描述文件，供手机续签。首次请用此版本 AutoSign 安装 Store IPA；自身刷新会最后执行，关闭后重新打开即可查看结果。")
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
