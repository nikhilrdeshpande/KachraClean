import AppKit
import SwiftUI

@main
struct KachraCleanApp: App {
    @State private var model = AppModel()

    init() {
        // Launched as a bare executable (swift run) the process would stay in the background.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("KachraClean") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { NSApplication.shared.activate() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
            }
        }
    }
}
