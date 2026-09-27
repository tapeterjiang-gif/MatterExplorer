import SwiftUI

@main
struct MatterExplorerApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task {
                    await MatterManager.shared.bootstrap()
                }
        }
    }
}
