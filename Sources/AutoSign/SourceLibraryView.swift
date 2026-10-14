import SwiftUI

struct SourceLibraryView: View {
    @ObservedObject var library: SourceLibraryModel
    let installationBusy: Bool
    let selectIPA: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("AltStore / SideStore 源地址（JSON）", text: $library.sourceURLInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSource() }
                Button("添加源") { addSource() }
                    .disabled(library.sourceURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(library.isBusy || installationBusy)

            HStack {
                Button("添加 AutoSign Store 源") {
                    Task { await library.addSource(AppSourceService.autoSignStoreSourceURL) }
                }
                .disabled(library.isBusy || installationBusy)
                Button("添加 Kazumi 源") {
                    Task { await library.addSource(AppSourceService.kazumiSourceURL) }
                }
                .disabled(library.isBusy || installationBusy)
                Text("兼容 AltStore / SideStore 的 IPA 源")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if library.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("正在刷新…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !library.sources.isEmpty {
                Divider()
                HStack {
                    Picker("应用源", selection: $library.selectedSourceID) {
                        ForEach(library.sources) { source in
                            Text("\(source.catalog.name)（\(source.catalog.apps.count) 个应用）").tag(Optional(source.id))
                        }
                    }
                    Spacer()
                    Button("刷新源") { Task { await library.refreshSources() } }
                    Button("移除源", role: .destructive) { library.removeSelectedSource() }
                }
                .disabled(library.isBusy || installationBusy)

                if let source = library.selectedSource {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.url.absoluteString).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                        Text("上次更新：\(source.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        if let error = library.sourceErrors[source.id] {
                            Text("刷新失败，当前显示上次缓存：\(error)").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    if source.catalog.apps.isEmpty {
                        Text("这个源暂时没有应用").foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(source.catalog.apps) { app in appRow(app) }
                            }
                        }
                        .frame(height: min(350, CGFloat(source.catalog.apps.count) * 170))
                    }
                }
            } else {
                Text("添加一个源，即可浏览应用并下载最新 IPA。源地址和应用列表会保存在本机。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }

            if let message = library.downloadMessage {
                HStack {
                    if library.isDownloading { ProgressView().controlSize(.small) }
                    Text(message).font(.callout).foregroundStyle(.cyan)
                    Spacer()
                    if library.isDownloading {
                        Button("取消下载") { library.cancelDownload() }
                    }
                }
            }
            if let error = library.errorMessage {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .task { await library.refreshSources() }
    }

    private func addSource() {
        guard !library.isBusy, !installationBusy else { return }
        let input = library.sourceURLInput
        Task { await library.addSource(input) }
    }

    private func appRow(_ app: SourceApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: app.iconURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "app.fill").font(.system(size: 32)).foregroundStyle(.cyan)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.headline)
                Text(app.developerName ?? app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                if let version = app.latestVersion {
                    Text(versionDescription(version)).font(.caption).foregroundStyle(.cyan)
                    if let notes = version.localizedDescription, !notes.isEmpty {
                        DisclosureGroup("版本说明") {
                            Text(notes).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                } else {
                    Text("暂无可下载版本").font(.caption).foregroundStyle(.secondary)
                }
                if let description = app.localizedDescription, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(library.downloadingAppID == app.id ? "正在下载…" : "下载最新 IPA") {
                Task {
                    if let url = await library.downloadLatest(app) { selectIPA(url) }
                }
            }
            .buttonStyle(.borderedProminent).tint(.indigo)
            .disabled(library.isBusy || installationBusy || app.latestVersion == nil)
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
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
