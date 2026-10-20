import AutoSignLocalization
import Darwin
import SwiftUI

@main
struct AutoSignApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue
    private let launchMode: LaunchMode
    @StateObject private var model: AppModel

    init() {
        let mode = LaunchMode(arguments: ProcessInfo.processInfo.arguments)
        if mode != .interface { NSApplication.shared.setActivationPolicy(.accessory) }
        do {
            guard try ApplicationInstance.shared.start(mode: mode) else { exit(EXIT_SUCCESS) }
        } catch {
            if mode == .interface {
                let alert = NSAlert()
                alert.messageText = L10n.tr("无法启动 AutoSign")
                alert.informativeText = L10n.tr("无法检查正在运行的实例：\(error.localizedDescription)")
                alert.runModal()
            } else {
                fputs("AutoSign instance check failed: \(error.localizedDescription)\n", stderr)
            }
            exit(EXIT_FAILURE)
        }
        launchMode = mode
        _model = StateObject(wrappedValue: AppModel(performInitialRefresh: false))
    }

    var body: some Scene {
        WindowGroup("AutoSign", id: "main") {
            if launchMode == .interface {
                ContentView(model: model)
                    .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? L10n.locale)
                    .frame(minWidth: 860, minHeight: 680)
            } else {
                BackgroundTaskView(mode: launchMode)
                    .frame(width: 1, height: 1)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct BackgroundTaskView: View {
    let mode: LaunchMode

    var body: some View {
        Color.clear
            .task {
                NSApplication.shared.windows.forEach { $0.orderOut(nil) }
                switch mode {
                case .verifyIndependentAccount:
                    await IndependentAccountDiagnostics.run()
                case .backgroundRefresh:
                    if LocalNetworkPreparation.isPrepared() {
                        await BackgroundRefreshCoordinator.run()
                    } else {
                        let message = L10n.tr("此版本尚未在前台完成本地网络检查。请打开 AutoSign，允许本地网络访问并完成检查后再使用后台续签。")
                        BackgroundRefreshManager.record(message)
                        await BackgroundRefreshManager.notify(title: L10n.tr("AutoSign 需要完成首次设置"), body: message)
                    }
                case .installBackgroundRefresh:
                    try? await BackgroundRefreshManager.install()
                case .interface:
                    break
                }
                NSApplication.shared.terminate(nil)
            }
    }
}
