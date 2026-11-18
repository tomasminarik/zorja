import SwiftUI

@main
struct ZorjaApp: App {
    init() {
        OutfitFont.register()
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .preferredColorScheme(.dark)
        }
    }
}
