import Foundation

struct RemovedDevice: Codable, Equatable, Identifiable, Sendable {
    let udid: String
    let name: String
    let wasAutomaticRefreshTarget: Bool
    var id: String { udid }
}

enum DeviceRemovalStore {
    static let preferenceKey = "removedDevices"

    static func load(from preferences: UserDefaults = .standard) -> [RemovedDevice] {
        guard let data = preferences.data(forKey: preferenceKey),
              let devices = try? JSONDecoder().decode([RemovedDevice].self, from: data) else { return [] }
        var seen = Set<String>()
        return devices.filter { !$0.udid.isEmpty && seen.insert($0.udid).inserted }
    }

    static func removedUDIDs(from preferences: UserDefaults = .standard) -> Set<String> {
        Set(load(from: preferences).map(\.udid))
    }

    static func remove(udid: String, name: String, preferences: UserDefaults) throws {
        guard !udid.isEmpty else { return }
        var devices = load(from: preferences)
        let targets = DeviceSelectionStore.load(from: preferences)
        if !devices.contains(where: { $0.udid == udid }) {
            devices.append(RemovedDevice(udid: udid, name: name, wasAutomaticRefreshTarget: targets.contains(udid)))
            try save(devices, to: preferences)
        }
        DeviceSelectionStore.save(targets.filter { $0 != udid }, to: preferences)
    }

    static func restore(_ udid: String, preferences: UserDefaults) throws {
        let devices = load(from: preferences)
        guard let device = devices.first(where: { $0.udid == udid }) else { return }
        try save(devices.filter { $0.udid != udid }, to: preferences)
        if device.wasAutomaticRefreshTarget {
            var targets = DeviceSelectionStore.load(from: preferences)
            if !targets.contains(udid) { targets.append(udid) }
            DeviceSelectionStore.save(targets, to: preferences)
        }
    }

    private static func save(_ devices: [RemovedDevice], to preferences: UserDefaults) throws {
        if devices.isEmpty { preferences.removeObject(forKey: preferenceKey) }
        else { preferences.set(try JSONEncoder().encode(devices), forKey: preferenceKey) }
    }
}
