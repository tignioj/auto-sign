import SwiftUI

@main
struct AutoSignApp: App {
    private let launchMode: LaunchMode
    @StateObject private var model: AppModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let mode: LaunchMode
        if arguments.contains("--background-refresh") {
            mode = .backgroundRefresh
        } else if arguments.contains("--install-background-refresh") {
            mode = .installBackgroundRefresh
        } else {
            mode = .interface
        }
        launchMode = mode
        _model = StateObject(wrappedValue: AppModel(performInitialRefresh: false))
        if mode != .interface { NSApplication.shared.setActivationPolicy(.accessory) }
    }

    var body: some Scene {
        WindowGroup {
            if launchMode == .interface {
                ContentView(model: model)
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

private enum LaunchMode: Equatable {
    case interface
    case backgroundRefresh
    case installBackgroundRefresh
}

private struct BackgroundTaskView: View {
    let mode: LaunchMode

    var body: some View {
        Color.clear
            .task {
                NSApplication.shared.windows.forEach { $0.orderOut(nil) }
                switch mode {
                case .backgroundRefresh:
                    if LocalNetworkPreparation.isPrepared() {
                        await BackgroundRefreshCoordinator.run()
                    } else {
                        let message = "此版本尚未在前台完成本地网络检查。请打开 AutoSign，允许本地网络访问并完成检查后再使用后台续签。"
                        BackgroundRefreshManager.record(message)
                        await BackgroundRefreshManager.notify(title: "AutoSign 需要完成首次设置", body: message)
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
