import SwiftUI

@main
struct GlucoseApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "drop.fill") }
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
            AlertsView()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { await model.start() }
        .onChange(of: model.unit) { model.saveSettings() }
        .onChange(of: model.missingData) { model.saveSettings() }
        .onChange(of: model.demoSpeed) { model.startSimulation() }
    }
}
