import AutoSignLocalization
import SwiftUI

struct SetupGuideView: View {
    @Environment(\.locale) private var locale
    var body: some View {
        // Recompute String-based translations when the app language changes.
        let _ = locale
        VStack(spacing: 20) {
            AppCard(title: L10n.tr("首次使用"), symbol: "list.number") {
                guideRow(symbol: "person.crop.circle", title: L10n.tr("1. 准备签名"), text: L10n.tr("在 Xcode 的 Settings → Accounts 登录 Apple ID，然后到“签名设置”确认签名证书与描述文件。"))
                guideRow(symbol: "cable.connector", title: L10n.tr("2. 连接设备"), text: L10n.tr("通过 USB 连接并解锁 iPhone 或 iPad，信任此电脑，在“设备管理”中完成配对，并在设备上开启开发者模式。"))
                guideRow(symbol: "square.stack.3d.up", title: L10n.tr("3. 添加应用源并安装"), text: L10n.tr("在“应用源”中添加 AltStore / SideStore 格式的源，再到“安装应用”选择设备与应用，点击“安装所选应用”。"))
                guideRow(symbol: "wifi", title: L10n.tr("4. 设置无线续签"), text: L10n.tr("首次打开 AutoSign 时允许本地网络访问，并确认检查通过；拒绝后可到系统设置 → 隐私与安全性 → 本地网络中允许 AutoSign，再重新检查。在 Finder 中启用“连接到 Wi-Fi 时显示此设备”，保持 Mac 与设备处于同一局域网，再在“自动续签”开启后台任务。新版本或移动应用后也需先在前台完成检查。"))
            }
            provisioningGuide
        }
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
