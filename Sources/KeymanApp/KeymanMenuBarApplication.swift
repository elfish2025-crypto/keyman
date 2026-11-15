import SwiftUI
import AppKit
import KeymanCore
import KeymanAppSupport

struct KeymanMenuBarApplication: App {
    @State private var model: AppModel = {
        let configurationStore = FileConfigurationStore()
        let credentialStore = KeychainCredentialStore(configurationStore: configurationStore)
        return AppModel(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            importer: LegacyImporter(),
            modelCaller: ModelCaller(
                configurationStore: configurationStore,
                credentialStore: credentialStore
            ),
            profileTester: ProfileTester(
                configurationStore: configurationStore,
                credentialStore: credentialStore
            )
        )
    }()

    var body: some Scene {
        Window("Keyman", id: "main") {
            KeymanRootView(model: model)
                .frame(minWidth: 620, minHeight: 520)
                .task {
                    do { try await model.reload() }
                    catch { model.presentedError = error.localizedDescription }
                }
        }
        .defaultSize(width: 760, height: 640)

        MenuBarExtra("Keyman", systemImage: "key.fill") {
            KeymanMenu()
        }
    }
}

private struct KeymanMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 Keyman") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("k")
        Divider()
        Button("退出 Keyman") { NSApplication.shared.terminate(nil) }
    }
}
