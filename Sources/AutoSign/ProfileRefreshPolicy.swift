import Foundation

enum ProfileRefreshPolicy {
    static func profileOnly(on udid: String, preferences: UserDefaults = .standard) -> Bool {
        preferences.bool(forKey: "profileOnlyRefresh.\(udid)")
    }

    static func setProfileOnly(_ enabled: Bool, on udid: String, preferences: UserDefaults = .standard) {
        preferences.set(enabled, forKey: "profileOnlyRefresh.\(udid)")
    }
}
