import Foundation
import Combine

@MainActor
final class SourceLibraryModel: ObservableObject {
    static let shared = SourceLibraryModel()
    @Published private(set) var sources: [SavedAppSource]
    @Published var selectedSourceID: String?
    @Published var sourceURLInput = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var downloadingAppID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var sourceErrors: [String: String] = [:]
    @Published private(set) var downloadMessage: String?

    private let preferences: UserDefaults
    private let service: AppSourceService
    private var downloadTask: Task<URL, Error>?

    var isDownloading: Bool { downloadingAppID != nil }
    var isBusy: Bool { isRefreshing || isDownloading }
    var selectedSource: SavedAppSource? { sources.first { $0.id == selectedSourceID } }

    init(preferences: UserDefaults = .standard, service: AppSourceService = AppSourceService()) {
        self.preferences = preferences
        self.service = service
        sources = AppSourceStore.load(from: preferences)
        selectedSourceID = sources.first?.id
    }

    /// Shared by the Mac UI and authenticated phone API.
    func fetchAndSaveSource(_ input: String) async throws -> SavedAppSource {
        guard !isBusy else { throw AppSourceError.invalid("正在更新源或下载，请稍后重试。") }
        isRefreshing = true
        defer { isRefreshing = false }
        let url = try AppSourceService.sourceURL(from: input)
        let catalog = try await service.fetchCatalog(at: url)
        try Task.checkCancellation()
        let source = SavedAppSource(url: url, catalog: catalog, updatedAt: Date())
        var updated = sources
        if let index = updated.firstIndex(where: { $0.id == source.id }) { updated[index] = source }
        else { updated.append(source) }
        try AppSourceStore.save(updated, to: preferences)
        sources = updated
        sourceErrors[source.id] = nil
        if selectedSourceID == nil { selectedSourceID = source.id }
        return source
    }

    func removeSource(_ input: String) throws {
        guard !isBusy else { throw AppSourceError.invalid("正在更新源或下载，请稍后重试。") }
        let id = try AppSourceService.sourceURL(from: input).absoluteString
        let updated = sources.filter { $0.id != id }
        try AppSourceStore.save(updated, to: preferences)
        sources = updated
        sourceErrors[id] = nil
        if selectedSourceID == id { selectedSourceID = sources.first?.id }
    }

    func addSource(_ input: String) async {
        guard !isBusy else { return }
        errorMessage = nil
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let url = try AppSourceService.sourceURL(from: input)
            if sources.contains(where: { $0.url == url }) {
                selectedSourceID = url.absoluteString
                throw AppSourceError.invalid("这个源已经添加，可以点击“刷新源”获取最新版本。")
            }
            let catalog = try await service.fetchCatalog(at: url)
            try Task.checkCancellation()
            let source = SavedAppSource(url: url, catalog: catalog, updatedAt: Date())
            let updated = sources + [source]
            try AppSourceStore.save(updated, to: preferences)
            sources = updated
            selectedSourceID = source.id
            sourceURLInput = ""
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshSources() async {
        guard !isBusy, !sources.isEmpty else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        for source in sources {
            do {
                let catalog = try await service.fetchCatalog(at: source.url)
                try Task.checkCancellation()
                if let index = sources.firstIndex(where: { $0.id == source.id }) {
                    var updated = sources
                    updated[index].catalog = catalog
                    updated[index].updatedAt = Date()
                    try AppSourceStore.save(updated, to: preferences)
                    sources = updated
                    sourceErrors[source.id] = nil
                }
            } catch {
                sourceErrors[source.id] = error.localizedDescription
                if Task.isCancelled { break }
            }
        }
    }

    func removeSelectedSource() {
        guard !isBusy, let id = selectedSourceID else { return }
        do {
            let updated = sources.filter { $0.id != id }
            try AppSourceStore.save(updated, to: preferences)
            sources = updated
            sourceErrors[id] = nil
            selectedSourceID = sources.first?.id
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func downloadLatest(_ app: SourceApp) async -> URL? {
        guard !isBusy, let source = selectedSource,
              source.catalog.apps.contains(where: { $0.id == app.id }) else { return nil }
        downloadingAppID = app.id
        errorMessage = nil
        downloadMessage = "正在检查 \(app.name) 的最新版本…"
        defer {
            downloadingAppID = nil
            downloadTask = nil
        }
        let task = Task<URL, Error> {
            // Refresh again before downloading so a cached catalog never silently supplies an old IPA.
            let catalog = try await service.fetchCatalog(at: source.url)
            try Task.checkCancellation()
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                var updated = sources
                updated[index].catalog = catalog
                updated[index].updatedAt = Date()
                try AppSourceStore.save(updated, to: preferences)
                sources = updated
                sourceErrors[source.id] = nil
            }
            guard let latest = catalog.apps.first(where: { $0.id == app.id })?.latestVersion else {
                throw AppSourceError.invalid("源中已没有这个应用的可下载版本，请刷新应用列表。")
            }
            downloadMessage = "正在下载 \(app.name) \(latest.displayVersion)…"
            let directory = try BackgroundRefreshManager.applicationSupportURL()
                .appendingPathComponent("Downloads", isDirectory: true)
            let url = try await service.download(latest, to: directory)
            downloadMessage = "已下载 \(app.name) \(latest.displayVersion)，可在下方签名并安装。"
            return url
        }
        downloadTask = task
        do { return try await task.value }
        catch {
            downloadMessage = nil
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                downloadMessage = "下载已取消"
            } else { errorMessage = error.localizedDescription }
            return nil
        }
    }

    func cancelDownload() { downloadTask?.cancel() }
}
