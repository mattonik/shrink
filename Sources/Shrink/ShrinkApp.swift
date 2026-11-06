import AppKit
import SwiftUI

@main
struct ShrinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var updates = UpdateController()

    var body: some Scene {
        Window("Shrink", id: "main") {
            ContentView(model: appDelegate.model, updates: updates)
                .frame(minWidth: 520, minHeight: 440)
                .onAppear { updates.checkInBackgroundIfDue() }
        }
        .defaultSize(width: 620, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updates.check(userInitiated: true) } }
            }
            CommandGroup(after: .newItem) {
                Button("Add Files…") { appDelegate.model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Owns the conversion queue. Files dropped on the Dock icon or sent with
/// Finder's Open With can arrive before the window exists (a cold launch
/// delivers them first), and the queue is already here to take them.
///
/// It also keeps a conversion from being abandoned. ffmpeg and Ghostscript
/// are separate processes: if Shrink simply exits, they carry on with
/// nobody watching and the rest of the queue is lost.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// Asks whether to stop a conversion in order to quit. Tests answer for the user.
    var confirmQuit: @MainActor () -> Bool = AppDelegate.askToStopConverting
    var replyToTerminate: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls: urls)
    }

    /// A SwiftUI app whose only scene is a Window quits when that window
    /// closes. Mid-run, Shrink stays open and keeps converting instead, and the
    /// Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.isConverting
    }

    /// Quitting mid-run asks first, then stops the conversion before exiting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isConverting else { return .terminateNow }
        guard confirmQuit() else { return .terminateCancel }
        Task {
            await model.cancelAndWait()
            replyToTerminate(true)
        }
        return .terminateLater
    }

    private static func askToStopConverting() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop converting and quit?"
        alert.informativeText = "The file being converted is discarded. Files that are already finished are kept."
        alert.addButton(withTitle: "Keep Converting")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
