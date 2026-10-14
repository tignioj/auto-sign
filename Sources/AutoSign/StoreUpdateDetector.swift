import Foundation

enum StoreUpdateDetector {
    /// A subscription URL pins an installed app to its publisher. Unlinked legacy installs
    /// are matched only when exactly one subscription contains their original identifier.
    @MainActor static func updates(records: [StoreRecord], sources: [SavedAppSource],
                        packageMetadata: @MainActor (URL) async -> AppSourceService.PackageMetadata? = { try? await AppSourceService.packageMetadata(at: $0) }) async -> [StoreAppUpdate] {
        var updates: [StoreAppUpdate] = []
        for record in records {
            let candidates = sources.filter { record.sourceURL == nil || $0.id == record.sourceURL }
            guard !candidates.isEmpty else { continue }
            let metadata = record.sourceBundleIdentifier == nil || record.app.buildVersion == nil
                ? await packageMetadata(URL(fileURLWithPath: record.ipaPath)) : nil
            let identifier = record.sourceBundleIdentifier ?? metadata?.bundleIdentifier ?? record.app.bundleIdentifier
            var installed = record.app
            if installed.buildVersion == nil { installed.buildVersion = metadata?.buildVersion }
            let matches = candidates.compactMap { source -> (SavedAppSource, SourceAppVersion)? in
                guard let release = source.catalog.apps.first(where: { $0.id == identifier })?.latestVersion else { return nil }
                return (source, release)
            }
            guard matches.count == 1, let (source, release) = matches.first,
                  isNewer(release, than: installed) else { continue }
            updates.append(StoreAppUpdate(id: record.app.id, deviceUDID: record.app.deviceUDID, name: record.app.name,
                installedVersion: record.app.version, version: release.version, buildVersion: release.buildVersion,
                sourceURL: source.id, bundleIdentifier: identifier, checkedAt: source.updatedAt,
                localizedDescription: release.localizedDescription, installedBuildVersion: installed.buildVersion))
        }
        return updates
    }

    static func isNewer(_ release: SourceAppVersion, than app: StoreApp) -> Bool {
        let order = compareVersions(release.version, app.version)
        if order != .orderedSame { return order == .orderedDescending }
        // Unknown installed builds must not cause the same release to be offered forever.
        guard let latest = release.buildVersion, let installed = app.buildVersion else { return false }
        return latest.compare(installed, options: .numeric) == .orderedDescending
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ value: String) -> ([UInt64], [String])? {
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") { value.removeFirst() }
            guard !value.isEmpty, !value.hasPrefix("+") else { return nil }
            let main = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let release = main.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let digits = release[0].split(separator: ".", omittingEmptySubsequences: false)
            let numbers = digits.compactMap { UInt64($0) }
            guard !numbers.isEmpty, numbers.count == digits.count else { return nil }
            return (numbers, release.count == 2 ? release[1].split(separator: ".").map(String.init) : [])
        }
        guard let a = parts(lhs), let b = parts(rhs) else { return lhs.compare(rhs, options: .numeric) }
        for i in 0..<max(a.0.count, b.0.count) {
            let x = i < a.0.count ? a.0[i] : 0
            let y = i < b.0.count ? b.0[i] : 0
            if x != y { return x > y ? .orderedDescending : .orderedAscending }
        }
        if a.1.isEmpty != b.1.isEmpty { return a.1.isEmpty ? .orderedDescending : .orderedAscending }
        for i in 0..<min(a.1.count, b.1.count) where a.1[i] != b.1[i] {
            if let x = UInt64(a.1[i]), let y = UInt64(b.1[i]) { return x > y ? .orderedDescending : .orderedAscending }
            if UInt64(a.1[i]) != nil { return .orderedAscending }
            if UInt64(b.1[i]) != nil { return .orderedDescending }
            return a.1[i].compare(b.1[i])
        }
        if a.1.count == b.1.count { return .orderedSame }
        return a.1.count > b.1.count ? .orderedDescending : .orderedAscending
    }
}
