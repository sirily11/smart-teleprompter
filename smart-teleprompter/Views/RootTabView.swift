//
//  RootTabView.swift
//  smart-teleprompter
//

import SwiftUI
import SwiftData

/// Top-level navigation: the script library and settings live in separate tabs.
struct RootTabView: View {
    enum AppTab: Hashable { case scripts, settings }

    @State private var selection: AppTab = .scripts

    var body: some View {
        TabView(selection: $selection) {
            Tab("Scripts", systemImage: "text.alignleft", value: .scripts) {
                ScriptListView()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.tabBarOnly)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: selection)
        #endif
    }
}

#Preview {
    RootTabView()
        .environment(SonyCameraController())
        .modelContainer(for: Script.self, inMemory: true)
}
