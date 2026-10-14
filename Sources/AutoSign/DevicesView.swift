import SwiftUI

struct DevicesView: View {
    @ObservedObject var model: AppModel
    let onInstall: () -> Void
    let onHelp: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            deviceSection
            AppCard(title: "连接与配对", symbol: "link") {
                Text("首次使用请通过 USB 连接、解锁设备并信任此 Mac。无线使用前，请在 Finder 中启用“连接到 Wi-Fi 时显示此设备”。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("切换目标设备会清空本次应用选择，已安装应用的自动续签记录会保留。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("查看使用指南", action: onHelp)
                    Spacer()
                    Button("为此设备安装应用", action: onInstall)
                        .buttonStyle(.borderedProminent).tint(.cyan)
                        .disabled(model.selectedDevice?.isReadyForInstallation != true)
                }
            }
        }
    }

    private var deviceSection: some View {
        AppCard(title: "目标设备", symbol: "cable.connector") {
            VStack(spacing: 16) {
                HStack {
                    Picker("设备类型", selection: Binding(get: { model.deviceKind }, set: { model.changeKind($0) })) {
                        ForEach(DeviceKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    .disabled(model.isBusy)
                    Spacer()
                    Text(model.selectedDevice.map { "当前设备：" + $0.name } ?? "请选择一台设备")
                        .font(.caption)
                        .foregroundStyle(model.selectedDevice == nil ? .orange : .secondary)
                    Button { Task { await model.refresh() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing || model.isBusy)
                }

                if model.filteredDevices.isEmpty {
                    emptyRow(symbol: model.deviceKind.symbol, text: "没有发现 \(model.deviceKind.title)，请连接 USB 并解锁设备")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.filteredDevices) { device in
                                VStack(spacing: 8) {
                                    deviceCard(device)
                                    if !device.isPaired {
                                        Button { model.pair(device) } label: {
                                            HStack(spacing: 7) {
                                                if model.pairingDeviceID == device.id {
                                                    ProgressView().controlSize(.small)
                                                } else {
                                                    Image(systemName: "link")
                                                }
                                                Text(model.pairingDeviceID == device.id ? "正在配对…" : "发起配对")
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.indigo)
                                        .disabled(model.isBusy)
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
                Text("请在 \(devicesRequiringDeveloperMode.count) 台设备上开启开发者模式")
                    .font(.callout.weight(.semibold))
                Text("前往“设置 → 隐私与安全性 → 开发者模式”，开启后按提示重启设备，再返回这里刷新。")
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
