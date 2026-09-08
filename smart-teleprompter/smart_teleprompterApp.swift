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
        #if DEBUG
        let screenshotMode = ProcessInfo.processInfo.arguments.contains("--marketing-screenshots")
        #else
        let screenshotMode = false
        #endif
        var modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: screenshotMode)
        #if DEBUG
        // Each UI test owns a separate on-disk store, including across relaunches.
        let testStoreID = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            ? ProcessInfo.processInfo.environment["UITEST_STORE_ID"].flatMap(UUID.init(uuidString:)) : nil
        if let testStoreID {
            let url = URL.temporaryDirectory.appendingPathComponent("ui-test-\(testStoreID).store")
            modelConfiguration = ModelConfiguration(schema: schema, url: url)
        }
        #endif

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            #if DEBUG
            if testStoreID != nil, try container.mainContext.fetchCount(FetchDescriptor<Script>()) == 0 {
                for (index, title) in ["Newest", "Middle", "Oldest"].enumerated() {
                    let script = Script(title: title, body: "Every great idea starts with a simple story. Today I want to share something that changed the way I work. A small shift. A clearer purpose.")
                    script.createdAt = Date(timeIntervalSince1970: Double(3000 - index * 1000))
                    script.updatedAt = Date(timeIntervalSince1970: Double(1000 + index * 1000))
                    container.mainContext.insert(script)
                }
                try container.mainContext.save()
            }
            if screenshotMode {
                let examples = [
                    ("Make your next idea matter", "Every great idea starts with a simple story.\n\nToday, I want to share something that changed the way I work. A small shift. A clearer purpose. And the confidence to take the next step.\n\nWhen we slow down and focus on what matters, our words have room to land. We connect. We inspire. We make an idea feel possible.\n\nSo take a breath. Find your rhythm. And let your next idea make a difference."),
                    ("A welcome worth remembering", "Welcome, everyone. It is wonderful to have you here.\n\nToday is about new ideas, shared experiences, and the people who make them possible. Thank you for being part of this story."),
                    ("Behind the scenes", "Here is a little look at how it all comes together.\n\nFrom the first sketch to the final detail, every step is a chance to make something better."),
                    ("Your weekly update", "This week, we made real progress.\n\nLet us look at what we learned, celebrate the small wins, and set a clear direction for the week ahead.")
                ]
                for (index, example) in examples.enumerated() {
                    let script = Script(title: example.0, body: example.1)
                    script.updatedAt = Date().addingTimeInterval(Double(-index * 3600))
                    script.createdAt = script.updatedAt
                    container.mainContext.insert(script)
                }
            }
            #endif
            return container
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
