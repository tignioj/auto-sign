import SwiftUI

struct SourceManagementView: View {
    @ObservedObject var library: SourceLibraryModel
    @ObservedObject var model: AppModel
    let onBrowseApps: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            AppCard(title: "添加应用源", symbol: "plus.circle") {
                Text("支持 AltStore / SideStore 格式的 JSON 源。订阅地址和应用列表会保存在本机，并与手机 Store 共用。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("AltStore / SideStore 源地址（JSON）", text: $library.sourceURLInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addSource() }
                    Button("添加源") { addSource() }
                        .buttonStyle(.borderedProminent).tint(.cyan)
                        .disabled(library.sourceURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button("添加 AutoSign Store 源") {
                        Task { await library.addSource(AppSourceService.autoSignStoreSourceURL) }
                    }
                    Button("添加 Kazumi 源") {
                        Task { await library.addSource(AppSourceService.kazumiSourceURL) }
                    }
                    if library.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let error = library.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .disabled(library.isBusy || model.isBusy)

            AppCard(title: "已订阅的源", symbol: "square.stack.3d.up") {
                HStack {
                    Text("共 \(library.sources.count) 个源").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新全部") { Task { await library.refreshSources() } }
                        .disabled(library.sources.isEmpty || library.isBusy || model.isBusy)
                }
                if library.sources.isEmpty {
                    Text("暂无订阅，请在上方添加一个应用源。")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(library.sources) { source in
                    sourceRow(source)
                }
                if !library.sources.isEmpty {
                    Text("移除源会保留已安装应用及其续签资产。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sourceRow(_ source: SavedAppSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.catalog.name).font(.headline)
                    Text("\(source.catalog.apps.count) 个应用 · 更新于 \(displayDate(source.updatedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("浏览应用") {
                    library.selectedSourceID = source.id
                    onBrowseApps()
                }
                Button("移除", role: .destructive) {
                    let previousSelection = library.selectedSourceID
                    library.selectedSourceID = source.id
                    library.removeSelectedSource()
                    if let previousSelection, library.sources.contains(where: { $0.id == previousSelection }) {
                        library.selectedSourceID = previousSelection
                    }
                }
            }
            Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            if let error = library.sourceErrors[source.id] {
                Text("刷新失败，保留上次列表：" + error)
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .disabled(library.isBusy || model.isBusy)
    }

    private func addSource() {
        guard !library.isBusy, !model.isBusy else { return }
        let input = library.sourceURLInput
        Task { await library.addSource(input) }
    }
}
