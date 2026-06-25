import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct CodexManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = InstanceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Instance") {
                Button("New Instance") {
                    store.createInstance()
                }
                .keyboardShortcut("n", modifiers: [.command])

                if let selected = store.selectedInstance {
                    Button("Launch Instance") {
                        Task { await store.launch(selected) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }
}
