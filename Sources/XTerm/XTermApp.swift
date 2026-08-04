import SwiftUI

@main
struct XTermApp: App {
    @NSApplicationDelegateAdaptor(XTermAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { appModel.addSession() }
                    .keyboardShortcut("n")
            }
            CommandMenu("串口") {
                Button(appModel.isConnected ? "断开" : "连接") {
                    appModel.toggleConnection()
                }
                .keyboardShortcut("k")
                Button("清空接收区") { appModel.clearLog() }
                    .keyboardShortcut("l")
            }
        }
        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
        Window("关于 XTerm", id: "about-xterm") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .commands {
            AboutCommands()
        }
    }
}

final class XTermAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 XTerm") { openWindow(id: "about-xterm") }
        }
    }
}
