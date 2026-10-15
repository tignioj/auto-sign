import SwiftUI

struct InstallAppsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sourceLibrary: SourceLibraryModel
    @Binding var searchText: String
    let onManageDevices: () -> Void
    let onManageSources: () -> Void
    let onSigningSettings: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            installationContext
            appsSection
            actionBar
        }
    }

    private var installationContext: some View {
        AppCard(title: "安装目标", symbol: "arrow.down.app") {
            HStack(spacing: 12) {
                Image(systemName: model.selectedDevice?.kind.symbol ?? "ipad.and.iphone")
                    .font(.title2).foregroundStyle(.cyan).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedDevice?.name ?? "尚未选择设备").font(.headline)
                    Text(model.selectedDevice?.statusText ?? "前往设备管理连接或配对设备")
                        .font(.caption).foregroundStyle(model.selectedDevice?.isReadyForInstallation == true ? Color.secondary : .orange)
                }
                Spacer()
                Menu(model.selectedDevice == nil ? "选择设备" : "切换设备") {
                    ForEach(DeviceKind.allCases) { kind in
                        Section(kind.title) {
                            ForEach(model.devices.filter { $0.kind == kind }) { device in
                                Button { model.selectDevice(device) } label: {
                                    if model.selectedDeviceID == device.id {
                                        Label(device.name, systemImage: "checkmark")
                                    } else {
                                        Text(device.name)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("设备管理…", action: onManageDevices)
                }
                .fixedSize().disabled(model.isBusy)
            }
            Divider().opacity(0.35)
            HStack(spacing: 12) {
                Image(systemName: "signature").foregroundStyle(.cyan).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("签名配置").font(.callout.weight(.medium))
                    Text(model.profileURL?.lastPathComponent ?? "首次安装前，请先选择描述文件")
                        .font(.caption).foregroundStyle(model.profileURL == nil ? Color.orange : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("签名设置", action: onSigningSettings)
            }
        }
    }

    private var appsSection: some View {
        AppCard(title: "选择应用", symbol: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("已选 \(model.selectedApps.count) 个应用", systemImage: "checkmark.circle")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if !model.selectedApps.isEmpty {
                        Button("清空选择") { model.clearAppSelection() }.disabled(model.isBusy)
                    }
                }
                if model.selectedDevice == nil {
                    Text("请先选择目标设备，再勾选应用。")
                        .font(.callout).foregroundStyle(.orange)
                }
                SourceLibraryView(library: sourceLibrary, model: model, searchText: $searchText, onManageSources: onManageSources)
                if !model.selectedApps.isEmpty {
                    Divider()
                    Text("本次操作的应用")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.selectedApps) { selection in
                        HStack {
                            Text(selection.app.name).font(.callout)
                            Text(sourceLibrary.sources.first { $0.id == selection.sourceURL }?.catalog.name ?? "源已移除")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { model.removeSelectedApp(selection.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("取消选择 " + selection.app.name)
                            .disabled(model.isBusy)
                        }
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                Text(model.detail).font(.callout)
                    .foregroundStyle(model.stage.isRunning ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedDevice.map { "目标：" + $0.name } ?? "尚未选择设备")
                        .font(.callout.weight(.semibold))
                    Text("已选 \(model.selectedApps.count) 个应用")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.perform(.refresh) } label: {
                    Label("续签所选应用", systemImage: "arrow.clockwise")
                        .frame(minWidth: 120).padding(.vertical, 4)
                }
                .buttonStyle(.bordered).disabled(!model.canRefreshApps)
                Button { model.perform(.install) } label: {
                    Label("安装所选应用", systemImage: "arrow.down.app.fill")
                        .frame(minWidth: 120).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(.cyan).disabled(!model.canInstall)
            }
            if model.selectedDevice != nil {
                Toggle("此设备仅更新描述文件，禁止覆盖安装", isOn: Binding(
                    get: { model.profileOnlyRefresh }, set: { model.setProfileOnlyRefresh($0) }))
                    .toggleStyle(.checkbox).disabled(model.isBusy)
                if model.profileOnlyRefresh {
                    Text("适用于此设备的手动、手机及后台续签；连接失败或签名不兼容时会停止，不会重装应用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.selectedApps.isEmpty && !model.stage.isRunning {
                if model.profileURL == nil && model.managedApps.isEmpty {
                    Text("首次安装前，请在签名设置中选择描述文件。")
                        .font(.caption).foregroundStyle(.orange)
                }
                let missing = model.selectedApps.filter { model.managedApps[$0.id] == nil }.count
                if missing > 0 {
                    Text("所选应用中有 \(missing) 个尚未在此设备安装；请先安装，或取消勾选这些应用后续签。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("安装会获取源中的最新版本；续签使用这台设备已保存的版本。每个应用独立处理，结果显示在下方。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.operationItems.isEmpty {
                Divider()
                ForEach(model.operationItems) { item in
                    HStack(alignment: .top, spacing: 10) {
                        if item.state == .running {
                            ProgressView().controlSize(.small).frame(width: 18)
                        } else {
                            Image(systemName: item.state == .completed ? "checkmark.circle.fill"
                                : item.state == .failed ? "exclamationmark.circle.fill" : "clock")
                                .foregroundStyle(item.state == .completed ? Color.green
                                    : item.state == .failed ? Color.orange : Color.secondary)
                                .frame(width: 18)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text(item.message).font(.caption).foregroundStyle(item.state == .failed ? .orange : .secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let expiration = item.expiration {
                                Text("签名到期：" + displayDate(expiration)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusIcon: String {
        switch model.stage {
        case .failed: "xmark.octagon.fill"
        case .finished: "checkmark.circle.fill"
        case .idle: "info.circle"
        default: "gearshape.2.fill"
        }
    }

    private var statusColor: Color {
        switch model.stage {
        case .failed: model.completedAppCount == 0 ? .red : .orange
        case .finished: .green
        default: .cyan
        }
    }

}
