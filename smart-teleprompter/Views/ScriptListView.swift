//
//  ScriptListView.swift
//  smart-teleprompter
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os
#if os(iOS)
import UIKit
#endif

struct ScriptListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Script.updatedAt, order: .reverse) private var scripts: [Script]
    @State private var selectedScript: Script?
    @State private var phonePath: [Script] = []
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var importingFile = false
    // Enable after the Notion OAuth service is configured.
    private let notionImportEnabled = false
    @State private var importingNotion = false
    @State private var importError: String?

    /// `.txt` and `.md` (plus the `.markdown` long form), falling back to plain
    /// text if a UTI lookup ever fails.
    private var importableTypes: [UTType] {
        [.plainText, .text,
         UTType(filenameExtension: "md") ?? .plainText,
         UTType(filenameExtension: "markdown") ?? .plainText]
    }

    private var usesSplitNavigation: Bool {
        #if os(macOS)
        true
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        true
        #endif
    }

    var body: some View {
        Group {
            if usesSplitNavigation {
                NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
                    library
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
                } detail: {
                    if let selectedScript {
                        ScriptEditorView(script: selectedScript)
                            .id(selectedScript.persistentModelID)
                    } else {
                        ContentUnavailableView("Select a Script", systemImage: "doc.text",
                            description: Text("Choose a script from the sidebar, or use + to create or import one."))
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $phonePath) {
                    library
                        .navigationDestination(for: Script.self) { script in
                            ScriptEditorView(script: script)
                        }
                }
            }
        }
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: importableTypes,
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(isPresented: $importingNotion) {
            NotionImportView { title, body in
                let script = Script(title: title, body: body)
                modelContext.insert(script)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.delete(script)
                    throw error
                }
                openScript(script)
            }
        }
        .alert("Couldn’t Import File", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: scripts.map(\.persistentModelID)) { _, ids in
            // A script may also be deleted from another window.
            if let selectedScript, !ids.contains(selectedScript.persistentModelID) {
                self.selectedScript = nil
                preferredCompactColumn = .sidebar
            }
            phonePath.removeAll { !ids.contains($0.persistentModelID) }
        }
    }

    private var library: some View {
        Group {
            if scripts.isEmpty {
                ContentUnavailableView {
                    Label("No Scripts", systemImage: "text.alignleft")
                } description: {
                    Text("Tap + to write or import a script, then present it and let your speech scroll it.")
                }
            } else if usesSplitNavigation {
                List(selection: $selectedScript) {
                    scriptRows
                }
                .listStyle(.sidebar)
            } else {
                List { scriptRows }
            }
        }
        .navigationTitle("Scripts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        let script = Script()
                        modelContext.insert(script)
                        openScript(script)
                    } label: {
                        Label("New Script", systemImage: "square.and.pencil")
                    }
                    Button {
                        importingFile = true
                    } label: {
                        Label("Import from File…", systemImage: "doc.text")
                    }
                    if notionImportEnabled {
                        Button {
                            importingNotion = true
                        } label: {
                            Label("Import from Notion…", systemImage: "square.and.arrow.down")
                        }
                    }
                } label: {
                    Label("Add Script", systemImage: "plus")
                }
            }
        }
    }

    private var scriptRows: some View {
        ForEach(scripts) { script in
            NavigationLink(value: script) {
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

    private func openScript(_ script: Script) {
        if usesSplitNavigation {
            selectedScript = script
            preferredCompactColumn = .detail
        } else {
            phonePath.append(script)
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
                openScript(script)
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
            for index in offsets {
                let script = scripts[index]
                if selectedScript == script {
                    selectedScript = nil
                    preferredCompactColumn = .sidebar
                }
                phonePath.removeAll { $0 == script }
                modelContext.delete(script)
            }
        }
    }
}

#Preview {
    ScriptListView()
        .modelContainer(for: Script.self, inMemory: true)
}
