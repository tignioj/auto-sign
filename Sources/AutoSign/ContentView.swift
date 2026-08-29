import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.075, blue: 0.14), Color(red: 0.09, green: 0.07, blue: 0.19)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    deviceSection
                    ipaSection
                    signingSection
                    actionBar
                }
                .padding(30)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(LinearGradient(colors: [.cyan, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text("AutoSign")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("给自己的 iPhone 与 iPad 安全重签名并安装 IPA")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            if model.stage.isRunning { ProgressView().controlSize(.small) }
            else { Circle().fill(statusColor).frame(width: 8, height: 8) }
            Text(model.stage.title).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(.white.opacity(0.07), in: Capsule())
    }

    private var statusColor: Color {
        switch model.stage {
        case .failed: .red
        case .finished: .green
        default: .cyan
        }
    }

    private var deviceSection: some View {
        card(title: "1  选择目标设备", symbol: "cable.connector") {
            VStack(spacing: 16) {
                HStack {
                    Picker("设备类型", selection: Binding(get: { model.deviceKind }, set: { model.changeKind($0) })) {
                        ForEach(DeviceKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    Spacer()
                    Button { Task { await model.refresh() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)
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
                                        .disabled(model.pairingDeviceID != nil)
                                    } else if !device.developerModeEnabled {
                                        Label {
                                            Text("在设备上打开：设置 → 隐私与安全性 → 向下滑到“安全性”区域 → 开发者模式")
                                                .fixedSize(horizontal: false, vertical: true)
                                        } icon: {
                                            Image(systemName: "gearshape.fill")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .padding(10)
                                        .frame(maxWidth: 250, alignment: .leading)
                                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func deviceCard(_ device: AppleDevice) -> some View {
        let selected = model.selectedDeviceID == device.id
        return Button { model.selectedDeviceID = device.id } label: {
            HStack(spacing: 12) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 26)).foregroundStyle(selected ? .cyan : .secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.headline)
                    Text("\(device.marketingName) · \(device.osVersion)").font(.caption).foregroundStyle(.secondary)
                    Label(device.statusText, systemImage: device.isReadyForInstallation ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(device.isReadyForInstallation ? .green : .orange)
                }
            }
            .padding(14).frame(minWidth: 250, alignment: .leading)
            .background(selected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? Color.cyan.opacity(0.7) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var ipaSection: some View {
        card(title: "2  拖入 IPA 安装包", symbol: "shippingbox") {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(model.isDropTargeted ? Color.cyan.opacity(0.12) : Color.white.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                        .foregroundStyle(model.isDropTargeted ? Color.cyan : Color.white.opacity(0.18)))
                HStack(spacing: 18) {
                    Image(systemName: model.ipaURL == nil ? "square.and.arrow.down" : "app.dashed")
                        .font(.system(size: 34)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.ipaURL?.lastPathComponent ?? "把 .ipa 文件拖到这里")
                            .font(.headline).lineLimit(1)
                        Text(model.ipaURL == nil ? "也可以点击右侧按钮选择文件" : fileDescription(model.ipaURL!))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择 IPA") { model.chooseIPA() }.buttonStyle(.borderedProminent).tint(.indigo)
                }
                .padding(22)
            }
            .frame(height: 104)
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                model.acceptIPA(first); return true
            } isTargeted: { model.isDropTargeted = $0 }
        }
    }

    private var signingSection: some View {
        card(title: "3  签名设置", symbol: "signature") {
            VStack(spacing: 12) {
                settingRow(title: "签名证书", symbol: "person.text.rectangle") {
                    if model.identities.isEmpty {
                        Text("未找到证书；安装时将尝试通过 Xcode 自动创建").foregroundStyle(.orange).font(.callout)
                    } else {
                        Picker("", selection: Binding(get: { model.selectedIdentityID }, set: { model.rememberIdentity($0) })) {
                            ForEach(model.identities) { identity in Text(identity.name).tag(Optional(identity.id)) }
                        }.labelsHidden().frame(maxWidth: 440)
                    }
                }
                Divider().opacity(0.35)
                settingRow(title: "描述文件", symbol: "doc.badge.gearshape") {
                    Text(model.profileURL?.lastPathComponent ?? "请选择匹配应用与设备的描述文件")
                        .font(.callout).foregroundStyle(model.profileURL == nil ? .secondary : .primary).lineLimit(1)
                    Button("选择…") { model.chooseProfile() }
                }
                Divider().opacity(0.35)
                settingRow(title: "自动续签", symbol: "wifi") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Toggle("同一 Wi‑Fi 后台自动续签", isOn: Binding(
                            get: { model.autoRefreshEnabled },
                            set: { model.setAutoRefreshEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        Text(model.lastBackgroundStatus)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                Text(model.detail).font(.callout).foregroundStyle(model.stage.isRunning ? .primary : .secondary).lineLimit(2)
                Spacer()
                if case .finished = model.stage { Button("在访达中显示") { model.revealOutput() } }
                Button { model.install() } label: {
                    HStack(spacing: 9) {
                        if model.stage.isRunning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.down.app.fill") }
                        Text(model.stage.isRunning ? "处理中" : "一键签名并安装").fontWeight(.semibold)
                    }
                    .frame(minWidth: 150).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(.cyan).disabled(!model.canInstall)
            }
            Text("签名过期后再次点击即可自动续期并重装；需要 Xcode 账号保持登录且 Mac 可以联网。")
                .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
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

    private func card<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(20).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }

    private func settingRow<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.cyan).frame(width: 24)
            Text(title).font(.callout.weight(.medium)).frame(width: 80, alignment: .leading)
            Spacer()
            content()
        }.frame(minHeight: 32)
    }

    private func emptyRow(symbol: String, text: String) -> some View {
        HStack { Image(systemName: symbol); Text(text) }.foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(20).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    private func fileDescription(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
