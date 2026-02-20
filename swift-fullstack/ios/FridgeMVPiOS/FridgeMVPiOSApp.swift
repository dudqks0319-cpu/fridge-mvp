import SwiftUI

@main
struct FridgeMVPiOSApp: App {
    @StateObject private var viewModel = PantryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.refreshAll()
                }
        }
    }
}
