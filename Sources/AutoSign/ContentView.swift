import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sourceLibrary: SourceLibraryModel
    @State private var selectedPage: AppPage = .install
    @State private var appSearchText = ""

    init(model: AppModel) {
        self.model = model
        self.sourceLibrary = model.sourceLibrary
    }

    var body: some View {
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
                        pageContent
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
            while !Task.isCancelled {
                await model.refreshDashboard()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .onReceive(sourceLibrary.$sources) { _ in
            // Reconcile even when the application browser is not the visible page.
            Task { model.reconcileSelectedApps() }
        }
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
                    navigationGroup("应用与设备", pages: [.install, .sources, .devices])
                    navigationGroup("服务与设置", pages: [.renewal, .connection, .signing])
                    navigationGroup("帮助", pages: [.help])
                }
            }
            Spacer(minLength: 0)
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
                    Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(12)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).help("查看安装与续签操作")
        }
        .padding(16).frame(width: 208)
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
                        if page == .install && !model.selectedApps.isEmpty {
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
