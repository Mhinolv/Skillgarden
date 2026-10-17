import SwiftUI
import SkillgardenCore

@main
struct SkillgardenApp: App {
    var body: some Scene {
        WindowGroup("Skillgarden") {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ContentUnavailableView("No courses yet", systemImage: "books.vertical",
                               description: Text("Publish a course with the skillgarden CLI."))
            .frame(minWidth: 900, minHeight: 600)
    }
}
