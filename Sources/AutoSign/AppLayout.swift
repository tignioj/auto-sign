import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case install, sources, devices, renewal, connection, signing, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .install: "安装应用"
        case .sources: "应用源"
        case .devices: "设备管理"
        case .renewal: "自动续签"
        case .connection: "手机连接"
        case .signing: "签名设置"
        case .help: "使用指南"
        }
    }

    var symbol: String {
        switch self {
        case .install: "arrow.down.app"
        case .sources: "square.stack.3d.up"
        case .devices: "ipad.and.iphone"
        case .renewal: "clock.arrow.circlepath"
        case .connection: "wifi"
        case .signing: "signature"
        case .help: "questionmark.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .install: "为一台设备选择应用，批量安装或续签。"
        case .sources: "管理订阅地址，在安装页浏览和选择应用。"
        case .devices: "连接、配对并选择本次操作的目标设备。"
        case .renewal: "管理后台续签，查看各设备应用的签名有效期。"
        case .connection: "连接 AutoSign Store，在手机上安装和续签应用。"
        case .signing: "查看 Xcode 账号，配置签名证书与描述文件。"
        case .help: "从首次安装到无线续签，按需查看操作说明。"
        }
    }
}

struct AppCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }
}

func displayDate(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .shortened) ?? "暂无记录"
}
