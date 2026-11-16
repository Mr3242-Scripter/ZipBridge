import SwiftUI

@main
struct ZipBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color(uiColor: .systemBlue))
                .preferredColorScheme(nil) // Follow system (light/dark)
        }
    }
}
