import SwiftUI

@main
struct ImageCapApp: App {
    var body: some Scene {
        WindowGroup("ImageCap") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
