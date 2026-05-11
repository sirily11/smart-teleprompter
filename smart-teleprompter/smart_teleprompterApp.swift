//
//  smart_teleprompterApp.swift
//  smart-teleprompter
//
//  Created by Qiwei Li on 5/11/26.
//

import SwiftUI
import SwiftData

@main
struct smart_teleprompterApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Script.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ScriptListView()
        }
        .modelContainer(sharedModelContainer)
    }
}
