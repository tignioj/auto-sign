import AutoSignLocalization
import SwiftUI

struct SetupGuideView: View {
    @Environment(\.locale) private var locale
    var body: some View {
        // Recompute String-based translations when the app language changes.
        let _ = locale
        VStack(spacing: 20) {
            AppCard(title: L10n.tr("首次使用"), symbol: "list.number") {
                guideRow(symbol: "person.crop.circle", title: L10n.tr("1. 准备签名"), text: L10n.tr("在“签名设置”登录独立 Apple 账号并选择团队。如需 Windows 设备认证服务，请先按下方说明启动并启用，再登录账号。使用 Xcode 兼容模式时，在 Xcode 的 Settings → Apple Accounts 登录并确认签名证书与描述文件。"))
                guideRow(symbol: "cable.connector", title: L10n.tr("2. 连接设备"), text: L10n.tr("通过 USB 连接并解锁 iPhone 或 iPad，信任此电脑，在“设备管理”中完成配对，并在设备上开启开发者模式。"))
                guideRow(symbol: "square.stack.3d.up", title: L10n.tr("3. 添加应用源并安装"), text: L10n.tr("在“应用源”中添加 AltStore / SideStore 格式的源，再到“安装应用”选择设备与应用，点击“安装所选应用”。"))
                guideRow(symbol: "wifi", title: L10n.tr("4. 设置无线续签"), text: L10n.tr("首次打开 AutoSign 时允许本地网络访问，并确认检查通过；拒绝后可到系统设置 → 隐私与安全性 → 本地网络中允许 AutoSign，再重新检查。在 Finder 中启用“连接到 Wi-Fi 时显示此设备”，保持 Mac 与设备处于同一局域网，再在“自动续签”开启后台任务。新版本或移动应用后也需先在前台完成检查。"))
            }
            anisetteGuide
            provisioningGuide
        }
    }

    private var anisetteGuide: some View {
        AppCard(title: L10n.tr("本机 Windows Anisette v3 服务"), symbol: "server.rack") {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("首次安装不会自动部署此服务，默认使用本机设备认证。需要 Windows Anisette v3 时，可在这台 Mac 的 Docker Desktop 中运行，无需另一台 Windows 电脑。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                guideRow(
                    symbol: "shippingbox",
                    title: L10n.tr("1. 准备 Docker 与部署脚本"),
                    text: L10n.tr("安装并启动 Docker Desktop，等待引擎就绪。部署脚本位于 AutoSign 项目源码中；仅下载 AutoSign.app 的用户，还需下载并解压项目源码。")
                )
                Link(L10n.tr("获取 AutoSign 项目源码"), destination: URL(string: "https://github.com/tignioj/auto-sign")!)
                    .font(.caption)
                guideRow(
                    symbol: "terminal",
                    title: L10n.tr("2. 首次部署并启动"),
                    text: L10n.tr("在终端进入包含 Scripts 文件夹的项目根目录，运行下方命令。脚本会下载并校验 Apple 认证组件、构建容器并启动服务；等待出现“本机 Windows 认证服务已启动”后继续。")
                )
                guideCommand("./Scripts/setup-local-anisette.sh")
                guideRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: L10n.tr("3. 在 AutoSign 中启用"),
                    text: L10n.tr("打开“签名设置 → 设备认证服务”，填写下方地址并点击“启用此服务”，再登录独立 Apple 账号。已登录时需先退出账号才能更换服务；自定义端口需同步修改地址。")
                )
                guideCommand("http://127.0.0.1:6969")
                guideRow(
                    symbol: "arrow.clockwise",
                    title: L10n.tr("后续启动与停止"),
                    text: L10n.tr("使用期间保持 Docker Desktop 运行。容器会随 Docker 启动恢复；如果曾手动停止，启动 Docker 后运行下方第一条命令恢复服务。第二条命令用于停止服务，已保存的钥匙串凭据会保留。")
                )
                guideCommand("docker start autosign-anisette-local")
                guideCommand("docker stop autosign-anisette-local")
                guideRow(
                    symbol: "stethoscope",
                    title: L10n.tr("提示服务不可用时"),
                    text: L10n.tr("先确认 Docker Desktop 和 autosign-anisette-local 容器正在运行，等待服务就绪，再检查 AutoSign 中的地址与端口。默认服务仅供这台 Mac 访问。")
                )
            }
        }
    }

    private func guideCommand(_ command: String) -> some View {
        Text(verbatim: command)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var provisioningGuide: some View {
        AppCard(title: L10n.tr("设备注册与描述文件"), symbol: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 12) {
                guideRow(
                    symbol: "iphone.and.arrow.forward",
                    title: L10n.tr("开发者模式 ≠ 设备注册"),
                    text: L10n.tr("开发者模式只允许设备运行开发 App，不会自动把 UDID 写入描述文件。")
                )
                guideRow(
                    symbol: "checkmark.shield.fill",
                    title: L10n.tr("首次安装或掉签后：信任开发者证书"),
                    text: L10n.tr("首次安装或掉签后重新签名安装完成，请在 iPhone 或 iPad 上前往“设置 → 通用 → VPN 与设备管理”，在“开发者 App”下选择本次签名使用的开发者，按提示重新信任证书，再打开应用。若已显示信任，则无需重复操作。")
                )
                guideRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: L10n.tr("免费 Apple ID / Personal Team"),
                    text: L10n.tr("AutoSign 会请 Xcode 为所选设备注册应用并生成匹配的描述文件。请保持 Xcode 账号登录、Mac 联网，且设备已解锁并信任此 Mac。免费签名通常有效 7 天。")
                )
                guideRow(
                    symbol: "person.2.badge.gearshape",
                    title: L10n.tr("付费开发者账号"),
                    text: L10n.tr("如果自动注册失败，在 Apple Developer 的 Devices 中添加设备 UDID，然后重新生成并选择 Development 或 Ad Hoc 描述文件。")
                )
                HStack(spacing: 16) {
                    Link(L10n.tr("查看 Apple 设备注册说明"), destination: URL(string: "https://developer.apple.com/help/account/devices/register-a-single-device")!)
                    Link(L10n.tr("查看描述文件更新说明"), destination: URL(string: "https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles")!)
                }
                .font(.caption)
            }
        }
    }

    private func guideRow(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.cyan)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}
