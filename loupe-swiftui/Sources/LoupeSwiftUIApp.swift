import SwiftUI

@main
struct LoupeSwiftUIApp: App {
    init() {
        FontRegistrar.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
