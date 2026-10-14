import SwiftUI

struct SourceLibraryView: View {
    @ObservedObject var library: SourceLibraryModel
    @ObservedObject var model: AppModel
    @Binding var searchText: String
    let onManageSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if library.sources.isEmpty {
                ContentUnavailableView {
                    Label("还没有应用源", systemImage: "square.stack.3d.up")
                } description: {
                    Text("添加一个应用源，即可浏览并安装其中的应用。")
                } actions: {
                    Button("添加应用源", action: onManageSources)
                        .buttonStyle(.borderedProminent).tint(.cyan)
                }
            } else {
                HStack {
                    Picker("应用源", selection: $library.selectedSourceID) {
                        ForEach(library.sources) { source in
                            Text("\(source.catalog.name)（\(source.catalog.apps.count) 个应用）").tag(Optional(source.id))
                        }
                    }
                    Spacer()
                    Button("刷新源") { Task { await library.refreshSources() } }
                    Button("管理源", action: onManageSources)
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
            }
            if let error = library.errorMessage {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
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
