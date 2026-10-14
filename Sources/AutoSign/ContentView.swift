import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sourceLibrary: SourceLibraryModel

    init(model: AppModel) {
        self.model = model
        self.sourceLibrary = model.sourceLibrary
    }
    @AppStorage(RefreshVerificationOptions.launchPreferenceKey) private var verifyLaunchAfterRefresh = false

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
                    appsSection
                    signingSection
                    actionBar
                    renewalDashboard
                    StoreServerView()
                    provisioningGuide
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
                Toggle("刷新签名后验证应用启动", isOn: $verifyLaunchAfterRefresh)
                    .toggleStyle(.switch)
                Text("适用于手机发起的刷新和后台自动续签。关闭后不会自动启动应用，仍会校验描述文件和有效期；开启后会启动应用并检查进程。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(model.schedulerStatus).font(.callout)
                Text("下次后台检查：" + nextCheckText).font(.callout)
                Text("成功安装的应用会按设备分别纳入自动续签，每个应用在到期前 24 小时独立进入续签窗口。切换当前设备或应用选择不影响已有续签记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("时间为预计值；Mac 休眠、设备离线或 Apple 未发放新描述文件时会延后。到期时间以本工具确认的安装或续签记录为准。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.renewalLibraryError {
                    Text("无法读取应用续签记录：" + error).font(.caption).foregroundStyle(.orange)
                }
                Label("掉签后重新安装：请到设备的“设置 → 通用 → VPN 与设备管理”中重新信任开发者证书；若已信任，无需重复操作。", systemImage: "checkmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if model.renewalStatuses.isEmpty {
                    Text("暂无自动续签设备，请先安装应用").foregroundStyle(.secondary)
                }
                ForEach(model.renewalStatuses) { status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(status.name).font(.headline)
                            Spacer()
                            Text(status.state).foregroundStyle(status.failure == nil ? Color.cyan : Color.orange)
                        }
                        Text("最近记录：\(dateText(status.updatedAt))  ·  最近成功：\(dateText(status.lastSuccess))")
                        if let apps = model.appRenewalStatuses[status.id], !apps.isEmpty {
                            Text("\(apps.count) 个应用 · 最早到期：\(dateText(status.expiration))")
                            ForEach(apps) { appStatus in
                                appRenewalRow(appStatus)
                            }
                        } else if model.renewalLibraryError == nil {
                            Text("暂无应用记录。通过 AutoSign 安装后将自动纳入续签。").foregroundStyle(.secondary)
                        }
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

    private func appRenewalRow(_ item: AppRenewalStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.app.name).fontWeight(.medium)
                Spacer()
                Text(item.status.state).foregroundStyle(item.status.failure == nil ? Color.cyan : Color.orange)
            }
            Text(item.app.bundleIdentifier).foregroundStyle(.secondary).textSelection(.enabled)
            Text("签名到期：\(dateText(item.app.expiration)) · 续签窗口：\(dateText(item.status.nextEligible))起")
            Text("下次续签：" + item.status.nextAttempt(check: model.nextBackgroundCheck, enabled: model.autoRefreshEnabled))
            Text("最近成功：\(dateText(item.status.lastSuccess))").foregroundStyle(.secondary)
            if let failure = item.status.failure {
                Text("失败原因：" + RefreshStatusStore.failureSummary(failure)).foregroundStyle(.orange)
                DisclosureGroup("完整错误详情") {
                    Text(failure).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
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
                Text("选择一台设备，批量安装和续签源中的应用")
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
        case .failed: model.completedAppCount == 0 ? .red : .orange
        case .finished: .green
        default: .cyan
        }
    }

    private var deviceSection: some View {
        card(title: "1  选择一台目标设备", symbol: "cable.connector") {
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

    private var appsSection: some View {
        card(title: "2  选择源中的应用（可多选）", symbol: "square.stack.3d.up") {
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
                    Text("请先在上方选择一台设备，再勾选应用。")
                        .font(.callout).foregroundStyle(.orange)
                }
                SourceLibraryView(library: sourceLibrary, model: model)
                if !model.selectedApps.isEmpty {
                    Divider()
                    Text("本次操作的应用 · 可切换源继续添加")
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
                    Text(model.profileURL?.lastPathComponent ?? "首次安装请选择描述文件以确定签名团队")
                        .font(.callout).foregroundStyle(model.profileURL == nil ? .secondary : .primary).lineLimit(1)
                    Button("选择…") { model.chooseProfile() }
                }
                Divider().opacity(0.35)
                settingRow(title: "自动续签", symbol: "wifi") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Toggle("为已安装的应用自动续签", isOn: Binding(
                            get: { model.autoRefreshEnabled },
                            set: { model.setAutoRefreshEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        Text(model.lastBackgroundStatus)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text("首次安装使用所选描述文件的签名团队，为每个应用单独生成描述文件；续签使用各应用已保存的团队和证书。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.isBusy)
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
                    text: "AutoSign 会请 Xcode 为所选设备注册应用并生成匹配的描述文件。请保持 Xcode 账号登录、Mac 联网，且设备已解锁并信任此 Mac。免费签名通常有效 7 天。"
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
                                Text("签名到期：" + dateText(expiration)).font(.caption).foregroundStyle(.secondary)
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

}
