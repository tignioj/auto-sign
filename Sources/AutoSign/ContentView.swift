import AutoSignLocalization
import SwiftUI

struct ContentView: View {
    @Environment(\.locale) private var locale
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue
    @ObservedObject var model: AppModel
    @ObservedObject private var sourceLibrary: SourceLibraryModel
    @State private var selectedPage: AppPage = .install
    @State private var appSearchText = ""
    @State private var didPrepareInterface = false
    @State private var isResumingNetworkFeatures = false
    @ObservedObject private var localNetwork = LocalNetworkAccess.shared

    init(model: AppModel) {
        self.model = model
        self.sourceLibrary = model.sourceLibrary
    }

    var body: some View {
        // Recompute String-based translations when the app language changes.
        let _ = locale
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.075, blue: 0.14), Color(red: 0.09, green: 0.07, blue: 0.19)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                VStack(spacing: 0) {
                    pageHeader
                    ScrollView {
                        VStack(spacing: 20) {
                            if localNetwork.state != .ready && selectedPage != .renewal { LocalNetworkAccessView() }
                            pageContent
                        }
                            .frame(maxWidth: 1040, alignment: .topLeading)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(24)
                    }
                    .id(selectedPage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .task { await sourceLibrary.refreshSources() }
        .task {
            if NSApplication.shared.isActive { await prepareInterface() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await prepareInterface() }
        }
        .onChange(of: localNetwork.state) { _, state in
            if state == .ready { Task { await resumeNetworkFeatures() } }
        }
        .onChange(of: language) { _, _ in
            Task { await model.refreshDashboard() }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshDashboard()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .onReceive(sourceLibrary.$sources) { _ in
            // Reconcile even when the application browser is not the visible page.
            Task {
                model.reconcileSelectedApps()
                await model.refreshAvailableUpdates()
            }
        }
    }

    private func prepareInterface() async {
        guard !didPrepareInterface else { return }
        didPrepareInterface = true
        if await localNetwork.check() { await resumeNetworkFeatures() }
        await model.refresh()
    }

    private func resumeNetworkFeatures() async {
        guard !isResumingNetworkFeatures else { return }
        isResumingNetworkFeatures = true
        defer { isResumingNetworkFeatures = false }
        if BackgroundRefreshManager.needsMigration {
            do { try await BackgroundRefreshManager.install() }
            catch { model.lastBackgroundStatus = L10n.tr("更新后台任务失败：\(error.localizedDescription)") }
        }
        StoreServer.shared.startIfEnabled()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(.cyan)
                Text("AutoSign").font(.system(size: 23, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 10).padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    navigationGroup(L10n.tr("应用与设备"), pages: [.install, .sources, .devices])
                    navigationGroup(L10n.tr("服务与设置"), pages: [.renewal, .connection, .signing])
                    navigationGroup(L10n.tr("帮助"), pages: [.help])
                }
            }
            Spacer(minLength: 0)
            Picker(L10n.tr("语言"), selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.callout)
            .help(L10n.tr("更改语言后立即生效，后台续签也会使用此语言。"))
            Button { selectedPage = .install } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        if model.stage.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                        }
                        Text(model.stage.title).font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption)
                    }
                    Text(L10n.stored(model.detail)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(12)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).help(L10n.tr("查看安装与续签操作"))
        }
        .padding(16).frame(width: AppLanguage.current == .english ? 236 : 208)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.12))
    }

    private func navigationGroup(_ title: String, pages: [AppPage]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 5)
            ForEach(pages) { page in
                Button { selectedPage = page } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol).frame(width: 20)
                        Text(page.title).font(.callout.weight(selectedPage == page ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if page == .install && !model.availableUpdates.isEmpty {
                            Text(L10n.tr("\(model.availableUpdates.count) 更新")).font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.12), in: Capsule())
                        } else if page == .install && !model.selectedApps.isEmpty {
                            Text("\(model.selectedApps.count)").font(.caption.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                    .foregroundStyle(selectedPage == page ? Color.cyan : .primary)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(selectedPage == page ? Color.cyan.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedPage.title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(selectedPage.subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
        .background(.white.opacity(0.018))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    @ViewBuilder private var pageContent: some View {
        switch selectedPage {
        case .install:
            InstallAppsView(model: model, sourceLibrary: sourceLibrary, searchText: $appSearchText,
                onManageDevices: { selectedPage = .devices },
                onManageSources: { selectedPage = .sources },
                onSigningSettings: { selectedPage = .signing })
        case .sources:
            SourceManagementView(library: sourceLibrary, model: model, onBrowseApps: {
                appSearchText = ""
                selectedPage = .install
            })
        case .devices:
            DevicesView(model: model, onInstall: { selectedPage = .install }, onHelp: { selectedPage = .help })
        case .renewal:
            RenewalDashboardView(model: model)
        case .connection:
            StoreServerView()
        case .signing:
            SigningSettingsView(model: model)
        case .help:
            SetupGuideView()
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
