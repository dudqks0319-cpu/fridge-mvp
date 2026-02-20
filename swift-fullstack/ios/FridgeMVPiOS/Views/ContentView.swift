import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("홈", systemImage: "house")
                }

            FridgeView()
                .tabItem {
                    Label("냉장고", systemImage: "snowflake")
                }

            RecommendView()
                .tabItem {
                    Label("추천", systemImage: "sparkles")
                }

            ShoppingView()
                .tabItem {
                    Label("장보기", systemImage: "cart")
                }

            SettingsView()
                .tabItem {
                    Label("설정", systemImage: "gearshape")
                }
        }
    }
}
