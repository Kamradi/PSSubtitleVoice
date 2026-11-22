import SwiftUI

@main
struct PSSubtitleVoiceApp: App {
    init() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1120, height: 740)
    }
}
