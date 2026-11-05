import AppKit
import SwiftUI

@main
struct ShrinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Shrink", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 440)
                .onAppear { appDelegate.deliverOpenedFiles(to: model.add(urls:)) }
        }
        .defaultSize(width: 620, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Receives files dropped on the Dock icon or sent with Finder's Open With.
/// They can arrive before the window exists — a cold launch delivers them
/// first — so they wait here until the model is ready to take them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [URL] = []
    private var deliver: (([URL]) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        if let deliver { deliver(urls) } else { pending.append(contentsOf: urls) }
    }

    func deliverOpenedFiles(to deliver: @escaping ([URL]) -> Void) {
        self.deliver = deliver
        if !pending.isEmpty {
            deliver(pending)
            pending.removeAll()
        }
    }
}
