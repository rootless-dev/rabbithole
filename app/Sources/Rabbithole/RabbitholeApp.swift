import SwiftUI

/// Minimal entry point so the application target links; the real menu bar UI
/// lands in a later task.
@main
struct RabbitholeApp: App {
    var body: some Scene {
        MenuBarExtra("Rabbithole", systemImage: "arrow.up.circle") {
            Text("Rabbithole")
        }
    }
}
