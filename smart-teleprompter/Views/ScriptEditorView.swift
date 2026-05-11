//
//  ScriptEditorView.swift
//  smart-teleprompter
//

import SwiftUI
import SwiftData

struct ScriptEditorView: View {
    @Bindable var script: Script
    @State private var presenting = false
    @FocusState private var bodyFocused: Bool

    /// Counts the same units the teleprompter tracks — words for spaced
    /// languages, individual characters for CJK — so it matches what speech sync
    /// will follow (a plain whitespace split badly under-counts Chinese).
    private var wordCount: Int {
        ScriptTokenizer.normalizedWords(of: script.body).count
    }

    var body: some View {
        Form {
            Section("Title") {
                TextField("Optional title", text: $script.title)
            }
            Section {
                TextEditor(text: $script.body)
                    .frame(minHeight: 280)
                    .focused($bodyFocused)
                    .font(.body)
            } header: {
                Text("Script")
            } footer: {
                Text("\(wordCount) words")
            }
        }
        .navigationTitle(script.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: script.title) { _, _ in script.updatedAt = Date() }
        .onChange(of: script.body) { _, _ in script.updatedAt = Date() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    bodyFocused = false
                    presenting = true
                } label: {
                    Label("Present", systemImage: "play.fill")
                }
                .disabled(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        #if os(macOS)
        .sheet(isPresented: $presenting) {
            PresentView(script: script)
                .frame(minWidth: 700, minHeight: 500)
        }
        #else
        .fullScreenCover(isPresented: $presenting) {
            PresentView(script: script)
        }
        #endif
    }
}
