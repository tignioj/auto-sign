import AutoSignLocalization
import SwiftUI

struct SourceLibraryView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var library: SourceLibraryModel
    @ObservedObject var model: AppModel
    @Binding var searchText: String
    let onManageSources: () -> Void

    var body: some View {
        // Recompute String-based translations when the app language changes.
        let _ = locale
        VStack(alignment: .leading, spacing: 14) {
            if library.sources.isEmpty {
                ContentUnavailableView {
                    Label(L10n.tr("还没有应用源"), systemImage: "square.stack.3d.up")
                } description: {
                    Text(L10n.tr("添加一个应用源，即可浏览并安装其中的应用。"))
                } actions: {
                    Button(L10n.tr("添加应用源"), action: onManageSources)
                        .buttonStyle(.borderedProminent).tint(.cyan)
                }
            } else {
                if !model.availableUpdates.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(L10n.tr("此设备有 \(model.availableUpdates.count) 个应用可更新"), systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        Text(L10n.tr("勾选标记为“可更新”的应用，点击“安装所选应用”升级到最新版本。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Text(L10n.tr("\(library.sources.count) 个源 · 共 \(library.sources.reduce(0) { $0 + $1.catalog.apps.count }) 个应用"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("刷新源")) { Task { await library.refreshSources() } }
                    Button(L10n.tr("管理源"), action: onManageSources)
                    if library.isRefreshing { ProgressView().controlSize(.small) }
                }
                .disabled(library.isBusy || model.isBusy)

                HStack {
                    TextField(L10n.tr("搜索应用名称或 Bundle ID"), text: $searchText).textFieldStyle(.roundedBorder)
                    Button(L10n.tr("全选当前列表"), action: selectVisibleApps)
                        .disabled(library.isBusy || model.isBusy || model.selectedDevice == nil
                                  || !library.sources.contains { !filteredApps(in: $0).isEmpty })
                }
                if visibleSources.isEmpty {
                    Text(L10n.tr("没有匹配的应用")).foregroundStyle(.secondary).padding(.vertical, 12)
                } else {
                    ForEach(visibleSources) { source in
                        sourceSection(source)
                    }
                }
            }
            if let error = library.errorMessage {
                Text(L10n.stored(error)).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private var visibleSources: [SavedAppSource] {
        library.sources.filter { searchText.isEmpty || !filteredApps(in: $0).isEmpty }
    }

    private func filteredApps(in source: SavedAppSource) -> [SourceApp] {
        source.catalog.apps.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func sourceSection(_ source: SavedAppSource) -> some View {
        let apps = filteredApps(in: source)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(source.catalog.name).font(.callout.weight(.semibold))
                Text(L10n.tr("\(apps.count) 个应用")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if let error = library.sourceErrors[source.id] {
                Text(L10n.tr("刷新失败，当前显示上次缓存：\(error)")).font(.caption).foregroundStyle(.orange)
            }
            if apps.isEmpty {
                Text(L10n.tr("这个源暂时没有应用")).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ForEach(apps) { app in appRow(app, in: source) }
            }
            Text(L10n.tr("上次更新：\(L10n.date(source.updatedAt))"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func selectVisibleApps() {
        var selectedIDs = Set(model.selectedApps.map(\.id))
        for source in library.sources {
            for app in filteredApps(in: source)
                where app.latestVersion != nil || model.managedApps[app.id] != nil {
                if selectedIDs.insert(app.id).inserted {
                    model.toggleApp(app, in: source)
                }
            }
        }
    }

    private func appRow(_ app: SourceApp, in source: SavedAppSource) -> some View {
        let selected = model.isAppSelected(app, in: source)
        let installed = model.managedApps[app.id]?.app
        let update = model.availableUpdates.first { $0.bundleIdentifier == app.id && $0.sourceURL == source.id }
        return HStack(alignment: .top, spacing: 12) {
            Toggle(app.name, isOn: Binding(get: { model.isAppSelected(app, in: source) }, set: { _ in
                model.toggleApp(app, in: source)
            }))
            .toggleStyle(.checkbox).labelsHidden()
            .accessibilityLabel(L10n.tr("选择 ") + app.name)
            .disabled(library.isBusy || model.isBusy || model.selectedDevice == nil
                      || (app.latestVersion == nil && installed == nil))
            .padding(.top, 14)
            AsyncImage(url: app.iconURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "app.fill").font(.system(size: 32)).foregroundStyle(.cyan)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(app.name).font(.headline)
                    Spacer()
                    if model.selectedDevice != nil {
                        Text(update != nil ? L10n.tr("可更新") : (installed == nil ? L10n.tr("未安装") : L10n.tr("已安装"))).font(.caption)
                            .foregroundStyle(update != nil ? Color.orange : (installed == nil ? Color.secondary : Color.green))
                    }
                }
                Text(app.developerName ?? app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                if let installed {
                    Text(L10n.tr("此设备：\(installed.version) · 签名到期：\(L10n.date(installed.expiration))"))
                        .font(.caption).foregroundStyle(.green)
                }
                if let update {
                    Text(L10n.tr("可更新：\(update.installedVersion) → \(update.displayVersion)"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                if let version = app.latestVersion {
                    Text(versionDescription(version)).font(.caption).foregroundStyle(.cyan)
                    if let notes = version.localizedDescription, !notes.isEmpty {
                        DisclosureGroup(L10n.tr("版本说明")) {
                            Text(notes).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption)
                    }
                } else {
                    Text(L10n.tr("暂无可下载版本")).font(.caption).foregroundStyle(.secondary)
                }
                if let description = app.localizedDescription, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(selected ? Color.cyan.opacity(0.08) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.cyan.opacity(0.5) : .clear))
    }

    private func versionDescription(_ version: SourceAppVersion) -> String {
        var parts = [L10n.tr("最新版本 \(version.displayVersion)")]
        if let size = version.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let minimum = version.minOSVersion { parts.append(L10n.tr("iOS \(minimum) 起")) }
        if let maximum = version.maxOSVersion { parts.append(L10n.tr("最高 iOS \(maximum)")) }
        return parts.joined(separator: " · ")
    }
}
