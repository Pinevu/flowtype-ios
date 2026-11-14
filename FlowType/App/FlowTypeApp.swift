import SwiftUI

@main
struct FlowTypeApp: App {
    @StateObject private var coordinator = HostVoiceCoordinator()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(coordinator)
                .preferredColorScheme(resolvedColorScheme(coordinator.config.appearance))
                .onOpenURL { url in
                    coordinator.handleDeepLink(url)
                }
        }
    }

    private func resolvedColorScheme(_ pref: AppearancePreference) -> ColorScheme? {
        switch pref {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            HomeView()
                .tabItem {
                    Label("主页", systemImage: "waveform.circle.fill")
                }
                .tag(0)

            HistoryView()
                .tabItem {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                }
                .tag(1)

            DictionaryView()
                .tabItem {
                    Label("词典", systemImage: "character.book.closed.fill")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                .tag(3)
        }
    }
}
