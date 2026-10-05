import SwiftUI

@main
struct GlucoseApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.sensor)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.settings.onboardingDone {
                MainTabs()
            } else {
                OnboardingView()
            }
        }
        .overlay {
            if model.isLocked {
                LockView()
            }
        }
        .task { await model.start() }
        .onChange(of: model.settings) { model.settingsChanged() }
    }
}

/// Launch arguments used by CI to capture screenshots in the simulator:
/// `-screenshots` skips permission prompts, `-onboarding` shows first launch, `-tab N` opens a tab.
enum ScreenshotMode {
    static let arguments = ProcessInfo.processInfo.arguments
    static let isActive = arguments.contains("-screenshots")
    static let showsOnboarding = arguments.contains("-onboarding")

    static var tab: Int {
        guard let index = arguments.firstIndex(of: "-tab"), index + 1 < arguments.count else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }
}

struct MainTabs: View {
    @State private var selection = ScreenshotMode.tab

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "drop.fill") }
                .tag(0)
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
                .tag(1)
            LogbookView()
                .tabItem { Label("Logbook", systemImage: "book") }
                .tag(2)
            AlertsView()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                Text("Glucose is locked").font(.title2.bold())
                Button("Unlock") { Task { await model.unlock() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
