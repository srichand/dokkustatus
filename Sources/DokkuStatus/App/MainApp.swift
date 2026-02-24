import AppKit
import SwiftUI

@main
struct DokkuStatusApp: App {
    @StateObject private var store: StatusStore

    init() {
        let configStore = HostConfigStore()
        let initialStore = StatusStore(configStore: configStore)
        _store = StateObject(wrappedValue: initialStore)

        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(
                store: store,
                onQuit: quitApplication
            )
        } label: {
            MenuBarStatusLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }

    @MainActor
    private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var store: StatusStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let metrics = store.menuStatusMetrics

        HStack(spacing: 4) {
            Image(systemName: MenuBarController.symbolName(for: store.aggregateState))
                .symbolRenderingMode(.multicolor)

            Text(MenuBarController.menuBarCountText(metrics: metrics))
                .font(.caption)
                .monospacedDigit()
        }
        .accessibilityLabel("Dokku status: \(store.aggregateState.title), \(MenuBarController.menuBarCountText(metrics: metrics))")
            .onAppear {
                store.handleLaunch(showSettings: {
                    openSettings()
                })
            }
    }
}
