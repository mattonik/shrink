import SwiftUI

@main
struct ShrinkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Shrink", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 440)
        }
        .defaultSize(width: 620, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Videos…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}
