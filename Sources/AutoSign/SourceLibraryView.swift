import SwiftUI

struct SourceLibraryView: View {
    @ObservedObject var library: SourceLibraryModel
    @ObservedObject var model: AppModel
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if library.sources.isEmpty {
                sourceManagement
                Text("添加一个源，即可为所选设备选择多个应用。源地址和应用列表会保存在本机。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                HStack {
                    Picker("应用源", selection: $library.selectedSourceID) {
                        ForEach(library.sources) { source in
                            Text("\(source.catalog.name)（\(source.catalog.apps.count) 个应用）").tag(Optional(source.id))
                        }
                    }
                    Spacer()
                    Button("刷新源") { Task { await library.refreshSources() } }
                    if library.isRefreshing { ProgressView().controlSize(.small) }
                }
                .disabled(library.isBusy || model.isBusy)

                if let source = library.selectedSource {
                    let apps = source.catalog.apps.filter {
                        searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                            || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
                    }
                    HStack {
                        TextField("搜索应用名称或 Bundle ID", text: $searchText).textFieldStyle(.roundedBorder)
                        Button("全选当前列表") {
                            for app in apps where !model.isAppSelected(app, in: source)
                                && (app.latestVersion != nil || model.managedApps[app.id] != nil) {
                                model.toggleApp(app, in: source)
                            }
                        }
                        .disabled(library.isBusy || model.isBusy || model.selectedDevice == nil || apps.isEmpty)
                    }
                    if let error = library.sourceErrors[source.id] {
                        Text("刷新失败，当前显示上次缓存：\(error)").font(.caption).foregroundStyle(.orange)
                    }
                    if apps.isEmpty {
                        Text(searchText.isEmpty ? "这个源暂时没有应用" : "没有匹配的应用")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(apps) { app in appRow(app, in: source) }
                            }
                        }
                        .frame(height: min(380, CGFloat(apps.count) * 155))
                    }
                    Text("上次更新：\(source.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("管理应用源") { sourceManagement.padding(.top, 10) }
                    .font(.callout)
            }
            if let error = library.errorMessage {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .task { await library.refreshSources() }
        .onReceive(library.$sources) { _ in
            // Reconcile after @Published has applied the new source list.
            Task { model.reconcileSelectedApps() }
        }
    }

    private var sourceManagement: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("AltStore / SideStore 源地址（JSON）", text: $library.sourceURLInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSource() }
                Button("添加源") { addSource() }
                    .disabled(library.sourceURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("添加 AutoSign Store 源") {
                    Task { await library.addSource(AppSourceService.autoSignStoreSourceURL) }
                }
                Button("添加 Kazumi 源") {
                    Task { await library.addSource(AppSourceService.kazumiSourceURL) }
                }
                Spacer()
                if !library.sources.isEmpty {
                    Button("移除当前源", role: .destructive) { library.removeSelectedSource() }
                }
            }
            if let source = library.selectedSource {
                Text(source.url.absoluteString).textSelection(.enabled)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
        .disabled(library.isBusy || model.isBusy)
    }

    private func addSource() {
        guard !library.isBusy, !model.isBusy else { return }
        let input = library.sourceURLInput
        Task { await library.addSource(input) }
    }

    private func appRow(_ app: SourceApp, in source: SavedAppSource) -> some View {
        let selected = model.isAppSelected(app, in: source)
        let installed = model.managedApps[app.id]?.app
        return HStack(alignment: .top, spacing: 12) {
            Toggle(app.name, isOn: Binding(get: { model.isAppSelected(app, in: source) }, set: { _ in
                model.toggleApp(app, in: source)
            }))
            .toggleStyle(.checkbox).labelsHidden()
            .accessibilityLabel("选择 " + app.name)
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
                        Text(installed == nil ? "未安装" : "已安装").font(.caption)
                            .foregroundStyle(installed == nil ? Color.secondary : Color.green)
                    }
                }
                Text(app.developerName ?? app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                if let installed {
                    Text("此设备：\(installed.version) · 签名到期：\(installed.expiration.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.green)
                }
                if let version = app.latestVersion {
                    Text(versionDescription(version)).font(.caption).foregroundStyle(.cyan)
                    if let notes = version.localizedDescription, !notes.isEmpty {
                        DisclosureGroup("版本说明") {
                            Text(notes).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption)
                    }
                } else {
                    Text("暂无可下载版本").font(.caption).foregroundStyle(.secondary)
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
        var parts = ["最新版本 \(version.displayVersion)"]
        if let size = version.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let minimum = version.minOSVersion { parts.append("iOS \(minimum) 起") }
        if let maximum = version.maxOSVersion { parts.append("最高 iOS \(maximum)") }
        return parts.joined(separator: " · ")
    }
}
