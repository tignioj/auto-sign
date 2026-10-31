import AutoSignLocalization
import SwiftUI

struct DevicesView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    let onInstall: () -> Void
    let onHelp: () -> Void

    var body: some View {
        // Recompute String-based translations when the app language changes.
        let _ = locale
        VStack(spacing: 20) {
            deviceSection
            if !model.removedDevices.isEmpty {
                AppCard(title: L10n.tr("已移除的设备"), symbol: "archivebox") {
                    Text(L10n.tr("恢复设备后会重新显示，并恢复移除前的自动续签设置。"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.removedDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.headline)
                                Text(device.udid).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button(L10n.tr("恢复设备")) { Task { await model.restoreDevice(device) } }
                                .disabled(!model.canManageDevices)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            AppCard(title: L10n.tr("连接与配对"), symbol: "link") {
                Text(L10n.tr("首次使用请通过 USB 连接、解锁设备并信任此 Mac。无线使用前，请在 Finder 中启用“连接到 Wi-Fi 时显示此设备”。"))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.tr("切换目标设备会清空本次应用选择，已安装应用的自动续签记录会保留。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.tr("查看使用指南"), action: onHelp)
                    Spacer()
                    Button(L10n.tr("为此设备安装应用"), action: onInstall)
                        .buttonStyle(.borderedProminent).tint(.cyan)
                        .disabled(model.selectedDevice?.isReadyForInstallation != true)
                }
            }
        }
    }

    private var deviceSection: some View {
        AppCard(title: L10n.tr("目标设备"), symbol: "cable.connector") {
            VStack(spacing: 16) {
                HStack {
                    Picker(L10n.tr("设备类型"), selection: Binding(get: { model.deviceKind }, set: { model.changeKind($0) })) {
                        ForEach(DeviceKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    .disabled(model.isBusy)
                    Spacer()
                    Text(model.selectedDevice.map { L10n.tr("当前设备：") + $0.name } ?? L10n.tr("请选择一台设备"))
                        .font(.caption)
                        .foregroundStyle(model.selectedDevice == nil ? .orange : .secondary)
                    Button { Task { await model.refresh() } } label: {
                        Label(L10n.tr("刷新"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing || model.isBusy)
                }

                if model.filteredDevices.isEmpty {
                    emptyRow(symbol: model.deviceKind.symbol, text: L10n.tr("没有发现 \(model.deviceKind.title)，请连接 USB 并解锁设备"))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.filteredDevices) { device in
                                VStack(spacing: 8) {
                                    deviceCard(device)
                                    HStack {
                                        if !device.isPaired {
                                            Button { model.pair(device) } label: {
                                                HStack(spacing: 7) {
                                                    if model.pairingDeviceID == device.id {
                                                        ProgressView().controlSize(.small)
                                                    } else {
                                                        Image(systemName: "link")
                                                    }
                                                    Text(model.pairingDeviceID == device.id ? L10n.tr("正在配对…") : L10n.tr("发起配对"))
                                                }
                                                .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.indigo)
                                            .disabled(model.isBusy)
                                        }
                                        Spacer(minLength: 0)
                                        RemoveDeviceButton(name: device.name, udid: device.udid) {
                                            model.removeDevice(udid: device.udid, name: device.name)
                                        }
                                        .disabled(!model.canManageDevices)
                                    }
                                }
                                .frame(width: 250)
                            }
                        }
                    }

                    if !devicesRequiringDeveloperMode.isEmpty {
                        developerModeNotice
                    }
                }
                Text(L10n.tr("移除设备会停止其自动续签，并从 Mac 和手机 Store 的设备列表隐藏；应用资料和系统配对保留，可随时恢复。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var devicesRequiringDeveloperMode: [AppleDevice] {
        model.filteredDevices.filter { $0.isPaired && !$0.developerModeEnabled }
    }

    private var developerModeNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("请在 \(devicesRequiringDeveloperMode.count) 台设备上开启开发者模式"))
                    .font(.callout.weight(.semibold))
                Text(L10n.tr("前往“设置 → 隐私与安全性 → 开发者模式”，开启后按提示重启设备，再返回这里刷新。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.22))
        }
    }

    private func deviceCard(_ device: AppleDevice) -> some View {
        let selected = model.selectedDeviceID == device.id
        return Button { model.selectDevice(device) } label: {
            HStack(spacing: 12) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 26)).foregroundStyle(selected ? .cyan : .secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.headline).lineLimit(1)
                    Text("\(device.marketingName) · \(device.osVersion)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Label(device.statusText, systemImage: device.isReadyForInstallation ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(device.isReadyForInstallation ? .green : .orange).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? .cyan : .secondary)
            }
            .padding(14).frame(width: 250, alignment: .leading)
            .background(selected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? Color.cyan.opacity(0.7) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }

    private func emptyRow(symbol: String, text: String) -> some View {
        HStack { Image(systemName: symbol); Text(text) }.foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(20).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

}

struct RemoveDeviceButton: View {
    @Environment(\.locale) private var locale
    let name: String
    let udid: String
    let onRemove: () -> Void
    @State private var isConfirming = false

    var body: some View {
        let _ = locale
        Button(role: .destructive) { isConfirming = true } label: {
            Label(L10n.tr("移除设备"), systemImage: "trash")
        }
        .confirmationDialog(L10n.tr("移除设备“\(name)”？"), isPresented: $isConfirming, titleVisibility: .visible) {
            Button(L10n.tr("移除设备"), role: .destructive, action: onRemove)
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("设备标识：\(udid)\n移除后停止自动续签，应用资料和系统配对保留。可在“已移除的设备”中恢复。"))
        }
    }
}
