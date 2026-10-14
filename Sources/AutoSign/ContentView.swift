import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var sourceLibrary = SourceLibraryModel.shared
    @State private var useSource = false

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
                    renewalDashboard
                    StoreServerView()
                    deviceSection
                    ipaSection
                    signingSection
                    provisioningGuide
                    actionBar
                }
                .padding(30)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                await model.refreshDashboard()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }

    private var renewalDashboard: some View {
        card(title: "账号与自动续签", symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.accountStatus.title, systemImage: "person.crop.circle")
                        .font(.headline)
                    Spacer()
                    Button("刷新状态") { Task { await model.refreshDashboard() } }
                }
                Text(model.accountStatus.detail).font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(model.schedulerStatus).font(.callout)
                Text("下次后台检查：" + nextCheckText).font(.callout)
                if let expiration = model.profileExpiration {
                    Text("当前描述文件到期：\(dateText(expiration)) · 续签窗口：\(dateText(expiration.addingTimeInterval(-86_400)))起")
                        .font(.caption).foregroundStyle(expiration < Date() ? .orange : .secondary)
                }
                Text("时间为预计值；Mac 休眠、设备离线或 Apple 未发放新描述文件时会延后。设备到期时间仅在本工具确认安装成功后记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Label("掉签后重新安装：请到设备的“设置 → 通用 → VPN 与设备管理”中重新信任开发者证书；若已信任，无需重复操作。", systemImage: "checkmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if model.renewalStatuses.isEmpty {
                    Text("尚未选择自动续签设备").foregroundStyle(.secondary)
                }
                ForEach(model.renewalStatuses) { status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(status.name).font(.headline)
                            Spacer()
                            Text(status.state).foregroundStyle(status.failure == nil ? Color.cyan : Color.orange)
                        }
                        Text("最近记录：\(dateText(status.updatedAt))  ·  最近成功：\(dateText(status.lastSuccess))")
                        Text("设备签名到期：\(dateText(status.expiration))")
                        Text("下次续签：" + status.nextAttempt(check: model.nextBackgroundCheck, enabled: model.autoRefreshEnabled))
                        if let failure = status.failure {
                            Text("失败原因：" + RefreshStatusStore.failureSummary(failure)).foregroundStyle(.orange)
                            DisclosureGroup("完整错误详情") {
                                Text(failure).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                DisclosureGroup("最近后台检查详情（含旧版本记录）") {
                    Text(model.lastBackgroundStatus).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var nextCheckText: String {
        guard model.autoRefreshEnabled else { return "已关闭" }
        guard let date = model.nextBackgroundCheck else { return "等待首次后台检查" }
        return date < Date() ? "计划时间已到，等待后台运行" : "预计 " + dateText(date)
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "暂无记录"
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
        case .failed: model.completedOutputURLs.isEmpty ? .red : .orange
        case .finished: .green
        default: .cyan
        }
    }

    private var deviceSection: some View {
        card(title: "1  选择目标设备（可多选）", symbol: "cable.connector") {
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
                    Text("已选 \(model.selectedDevices.count) 台")
                        .font(.caption)
                        .foregroundStyle(model.selectedDevices.isEmpty ? .orange : .secondary)
                    Button(model.areAllReadyFilteredDevicesSelected ? "取消全选" : "全选可用设备") {
                        model.toggleAllReadyFilteredDevices()
                    }
                    .disabled(!model.filteredDevices.contains(where: \.isReadyForInstallation))
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
        let selected = model.selectedDeviceIDs.contains(device.id)
        return Button { model.toggleDeviceSelection(device) } label: {
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
    }

    private var ipaSection: some View {
        card(title: "2  选择安装包", symbol: "shippingbox") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("安装方式", selection: $useSource) {
                    Text("本地 IPA").tag(false)
                    Text("从源获取").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
                .disabled(model.stage.isRunning || sourceLibrary.isDownloading)

                if useSource {
                    SourceLibraryView(library: sourceLibrary, installationBusy: model.stage.isRunning, selectIPA: model.acceptIPA)
                    if let url = model.ipaURL {
                        Label("当前安装包：\(url.lastPathComponent) · \(fileDescription(url))", systemImage: "shippingbox.fill")
                            .font(.caption).foregroundStyle(.cyan).lineLimit(2)
                    }
                } else {
                    localIPAInput
                }
            }
        }
    }

    private var localIPAInput: some View {
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
            guard !model.stage.isRunning, !sourceLibrary.isDownloading else { return false }
            guard let first = urls.first else { return false }
            model.acceptIPA(first); return true
        } isTargeted: { model.isDropTargeted = $0 }
        .disabled(model.stage.isRunning || sourceLibrary.isDownloading)
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
                        Toggle("为已选设备后台自动续签", isOn: Binding(
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

    private var provisioningGuide: some View {
        card(title: "设备注册与描述文件", symbol: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 12) {
                guideRow(
                    symbol: "iphone.and.arrow.forward",
                    title: "开发者模式 ≠ 设备注册",
                    text: "开发者模式只允许设备运行开发 App，不会自动把 UDID 写入描述文件。"
                )
                guideRow(
                    symbol: "checkmark.shield.fill",
                    title: "首次安装或掉签后：信任开发者证书",
                    text: "首次安装或掉签后重新签名安装完成，请在 iPhone 或 iPad 上前往“设置 → 通用 → VPN 与设备管理”，在“开发者 App”下选择本次签名使用的开发者，按提示重新信任证书，再打开应用。若已显示信任，则无需重复操作。"
                )
                guideRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: "免费 Apple ID / Personal Team",
                    text: "若描述文件未包含某台已选设备，AutoSign 会请 Xcode 逐台注册并重建。请保持 Xcode 账号登录、Mac 联网，且所有设备均已解锁并信任此 Mac。免费签名通常有效 7 天。"
                )
                guideRow(
                    symbol: "person.2.badge.gearshape",
                    title: "付费开发者账号",
                    text: "如果自动注册失败，在 Apple Developer 的 Devices 中添加设备 UDID，然后重新生成并选择 Development 或 Ad Hoc 描述文件。"
                )
                HStack(spacing: 16) {
                    Link("查看 Apple 设备注册说明", destination: URL(string: "https://developer.apple.com/help/account/devices/register-a-single-device")!)
                    Link("查看描述文件更新说明", destination: URL(string: "https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles")!)
                }
                .font(.caption)
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                Text(model.detail).font(.callout).foregroundStyle(model.stage.isRunning ? .primary : .secondary).lineLimit(2)
                Spacer()
                if !model.completedOutputURLs.isEmpty {
                    Button("在访达中显示") { model.revealOutputs() }
                }
                Button { model.install() } label: {
                    HStack(spacing: 9) {
                        if model.stage.isRunning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.down.app.fill") }
                        Text(actionButtonTitle).fontWeight(.semibold)
                    }
                    .frame(minWidth: 170).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(.cyan).disabled(!model.canInstall || sourceLibrary.isDownloading)
            }
            Text("将使用同一份覆盖所有已选设备的描述文件逐台安装；后台续签也会保留这组设备。")
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

    private var actionButtonTitle: String {
        if model.stage.isRunning { return "处理中" }
        let count = model.selectedDevices.count
        return count > 1 ? "签名并安装到 \(count) 台" : "一键签名并安装"
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

    private func fileDescription(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
