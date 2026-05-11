//
//  ScriptListView.swift
//  smart-teleprompter
//

import SwiftUI
import SwiftData

struct ScriptListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]
    @State private var newScript: Script?

    var body: some View {
        NavigationStack {
            Group {
                if scripts.isEmpty {
                    ContentUnavailableView {
                        Label("No Scripts", systemImage: "text.alignleft")
                    } description: {
                        Text("Tap + to write a script, then present it and let your speech scroll it.")
                    }
                } else {
                    List {
                        ForEach(scripts) { script in
                            NavigationLink {
                                ScriptEditorView(script: script)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(script.displayTitle)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(script.updatedAt, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteScripts)
                    }
                }
            }
            .navigationTitle("Scripts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let script = Script()
                        modelContext.insert(script)
                        newScript = script
                    } label: {
                        Label("New Script", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(item: $newScript) { script in
                ScriptEditorView(script: script)
            }
        }
    }

    private func deleteScripts(_ offsets: IndexSet) {
        withAnimation {
            for index in offsets { modelContext.delete(scripts[index]) }
        }
    }
}

#Preview {
    ScriptListView()
        .modelContainer(for: Script.self, inMemory: true)
}
