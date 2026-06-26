import AppKit
import Sparkle
import SwiftUI

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct CodexPoolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = InstanceStore()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            CommandMenu("Instance") {
                Button("New Instance") {
                    store.showTemplatePicker()
                }
                .keyboardShortcut("n", modifiers: [.command])

                if let selected = store.selectedInstance {
                    Button("Launch Instance") {
                        Task { await store.launch(selected) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(selected.isOriginal)

                    Button("Quit Instance") {
                        store.quit(selected)
                    }
                    .disabled(selected.isOriginal || !store.isRunning(selected))

                    Button("Restart Instance") {
                        Task { await store.restart(selected) }
                    }
                    .disabled(selected.isOriginal || !store.isRunning(selected))
                }
            }

            CommandMenu("Configuration") {
                Button("Import Configuration") {
                    store.selectConfigurationForImport()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export Configuration") {
                    store.exportInstances()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.instances.isEmpty)
            }
        }
    }
}
