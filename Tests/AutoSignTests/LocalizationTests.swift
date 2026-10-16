import Foundation
import Testing
@testable import AutoSign
@testable import AutoSignLocalization

@Test func languageSelectionFollowsSupportedSystemLanguagesAndPersistsOverrides() throws {
    #expect(AppLanguage.resolve(nil, preferredLanguages: ["en-US", "zh-Hans"]) == .english)
    #expect(AppLanguage.resolve("system", preferredLanguages: ["fr-FR", "zh-CN", "en"]) == .simplifiedChinese)
    #expect(AppLanguage.resolve(nil, preferredLanguages: ["zh-Hant-TW"]) == .simplifiedChinese)
    #expect(AppLanguage.resolve("invalid", preferredLanguages: ["de-DE"]) == .english)
    let suite = "AutoSignTests.Language.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
    #expect(AppLanguage.resolve(preferences.string(forKey: AppLanguage.preferenceKey), preferredLanguages: ["zh-Hans"]) == .english)
    preferences.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
    #expect(AppLanguage.resolve(preferences.string(forKey: AppLanguage.preferenceKey), preferredLanguages: ["en"]) == .simplifiedChinese)
}

@Test func localizationCatalogsHaveMatchingKeysAndPlaceholders() throws {
    func catalog(_ language: AppLanguage) throws -> [String: String] {
        let url = try #require(L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings",
                                                     subdirectory: "\(language.rawValue).lproj"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
    let english = try catalog(.english)
    let chinese = try catalog(.simplifiedChinese)
    #expect(english.count >= 560)
    #expect(Set(english.keys) == Set(chinese.keys))
    let placeholders = try NSRegularExpression(pattern: #"\{\d+\}"#)
    func tokens(_ value: String) -> [String] {
        placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range, in: value)!])
        }.sorted()
    }
    for (key, value) in english {
        #expect(!value.isEmpty, "Missing English translation: \(key)")
        #expect(value.range(of: #"\p{Han}"#, options: .regularExpression) == nil, "Untranslated English text: \(key)")
        #expect(tokens(key) == tokens(value), "Interpolation mismatch: \(key)")
        #expect(chinese[key] == key)
    }
}

@Test func localizedInterpolationPreservesUserDataAndSupportsReordering() {
    let name = "Demo {1} 100% \"app\"\n第二行"
    #expect(L10n.tr("已为 \(name) 选择 \(3) 个应用", language: .english) == "Selected apps for \(name): 3")
    #expect(L10n.tr("已为 \(name) 选择 \(3) 个应用", language: .simplifiedChinese) == "已为 \(name) 选择 3 个应用")
    #expect(L10n.tr("正在为 \("iPhone") \("install") \(2) 个应用…", language: .english)
            == "Preparing to install on iPhone (apps: 2)…")
    #expect(L10n.render("{1} / {0}", arguments: ["{1}", "100% %@"]) == "100% %@ / {1}")
    #expect(L10n.tr("Unknown localization key", language: .english) == "Unknown localization key")
}

@Test func savedStatusAndHelperDiagnosticsUseTheSelectedLanguage() {
    #expect(L10n.stored("等待设备就绪", language: .english) == "Waiting for the device to be ready")
    #expect(L10n.stored("Waiting for the device to be ready", language: .simplifiedChinese) == "等待设备就绪")
    #expect(L10n.stored("局域网服务运行中 · 端口 8091", language: .english) == "Local network service running · Port 8091")
    #expect(L10n.stored("Selected apps for Demo {0} 100%: 3", language: .simplifiedChinese) == "已为 Demo {0} 100% 选择 3 个应用")
    #expect(L10n.stored("External diagnostic 0xe8008015", language: .english) == "External diagnostic 0xe8008015")
    #expect(L10n.helperMessage("当前系统不支持单独管理描述文件：AMDeviceConnect", language: .english)
            == "This system cannot manage provisioning profiles separately: AMDeviceConnect")
    #expect(L10n.helperMessage("设备描述文件服务超时，请解锁设备后重试。", language: .english)
            == "The device provisioning profile service timed out. Unlock the device and try again.")
}

@Test(arguments: [AppLanguage.english, .simplifiedChinese])
func translatedCoreDeviceFailuresStillRetry(language: AppLanguage) {
    for message in [
        L10n.tr("CoreDevice 连接失败：\("connection refused")", language: language),
        L10n.tr("CoreDevice 连接中断或读取超时，请重试。", language: language),
        L10n.tr("CoreDevice 连接中断或写入超时，请重试。", language: language),
        L10n.tr("CoreDevice 发现连接被重置，请重试。", language: language),
        L10n.tr("未找到此设备已配对的 CoreDevice 描述文件通道，请解锁设备后重试。", language: language)
    ] {
        #expect(DeviceConnectionRetry.isTransient(message))
    }
    #expect(!DeviceConnectionRetry.isTransient(L10n.tr("手机已锁定，无法确认描述文件连接是否可用，请解锁后重试。", language: language)))
}

@Test func displayedDatesUseTheAppLanguage() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(L10n.date(date, language: .english) == date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en"))))
    #expect(L10n.date(date, language: .simplifiedChinese) == date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "zh-Hans"))))
    #expect(L10n.date(date, language: .english) != L10n.date(date, language: .simplifiedChinese))
}
