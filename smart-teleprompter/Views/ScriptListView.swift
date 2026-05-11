//
//  ScriptListView.swift
//  smart-teleprompter
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

struct ScriptListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]
    @State private var newScript: Script?
    @State private var importingFile = false
    @State private var importError: String?

    /// `.txt` and `.md` (plus the `.markdown` long form), falling back to plain
    /// text if a UTI lookup ever fails.
    private var importableTypes: [UTType] {
        [.plainText, .text,
         UTType(filenameExtension: "md") ?? .plainText,
         UTType(filenameExtension: "markdown") ?? .plainText]
    }

    var body: some View {
        NavigationStack {
            Group {
                if scripts.isEmpty {
                    ContentUnavailableView {
                        Label("No Scripts", systemImage: "text.alignleft")
                    } description: {
                        Text("Tap + to write or import a script, then present it and let your speech scroll it.")
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
                    Menu {
                        Button {
                            let script = Script()
                            modelContext.insert(script)
                            newScript = script
                        } label: {
                            Label("New Script", systemImage: "square.and.pencil")
                        }
                        Button {
                            importingFile = true
                        } label: {
                            Label("Import from File…", systemImage: "doc.text")
                        }
                    } label: {
                        Label("Add Script", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(item: $newScript) { script in
                ScriptEditorView(script: script)
            }
            .fileImporter(isPresented: $importingFile,
                          allowedContentTypes: importableTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("Couldn’t Import File", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            Log.ui.error("File import cancelled/failed: \(error.localizedDescription, privacy: .public)")
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let raw = try readText(from: url)
                let ext = url.pathExtension.lowercased()
                let body = (ext == "md" || ext == "markdown")
                    ? MarkdownPreprocessor.plainText(fromMarkdown: raw)
                    : raw
                let title = url.deletingPathExtension().lastPathComponent
                let script = Script(title: title, body: body)
                modelContext.insert(script)
                newScript = script
            } catch {
                Log.ui.error("Failed to read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                importError = "Could not read “\(url.lastPathComponent)”."
            }
        }
    }

    private func readText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        throw CocoaError(.fileReadInapplicableStringEncoding)
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
