import SwiftUI

struct NotionImportView: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: (String, String) throws -> Void
    @State private var token = ""
    @State private var oauth = NotionOAuth()
    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var pages: [NotionPage] = []
    @State private var cursor: String?
    @State private var hasSearched = false
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    private let credentials = NotionCredentialStore()

    var body: some View {
        NavigationStack {
            Form {
                if token.isEmpty {
                    Section {
                        Button("Connect to Notion") { connect() }
                            .disabled(busy)
                    } footer: {
                        Text("Sign in to Notion and select the pages you want to import.")
                    }
                }
                if !token.isEmpty {
                    Section {
                        TextField("Search page titles", text: $query)
                            .disabled(busy)
                            .onSubmit { search() }
                        Button("Search Pages") { search() }
                            .disabled(busy)
                    }
                }
                if busy {
                    Section { ProgressView(status) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if hasSearched && pages.isEmpty && !busy {
                    Section {
                        Text("No pages found. Try another title, or reconnect to select more pages. Newly shared pages may take a moment to appear.")
                    }
                }
                if !pages.isEmpty {
                    Section {
                        ForEach(pages) { page in
                            Button { importPage(page) } label: {
                                Label(page.title, systemImage: "doc.text")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .disabled(busy)
                        }
                        if cursor != nil {
                            Button("Load More Pages") { search(loadMore: true) }
                                .disabled(busy)
                        }
                    } header: {
                        Text("Choose a page to import")
                    } footer: {
                        Text("Imports a copy as an editable script. Includes nested text and tables; images, files, databases, and child pages are omitted. Changes in Notion won’t sync automatically.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import from Notion")
            .toolbar {
                if !token.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Reconnect to Notion") { connect() }
                            Button("Disconnect Notion", role: .destructive) { disconnect() }
                        } label: {
                            Label("Notion connection", systemImage: "ellipsis.circle")
                        }
                        .disabled(busy)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        operation?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            do {
                token = try credentials.load() ?? ""
                if !token.isEmpty { search() }
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear {
            operation?.cancel()
            oauth.cancel()
            token = ""
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 580)
        #endif
    }

    private var cleanToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func connect() {
        guard !busy else { return }
        run(status: "Connecting to Notion…") {
            let accessToken = try await oauth.connect()
            try Task.checkCancellation()
            try credentials.save(accessToken)
            token = accessToken
            pages = []
            cursor = nil
            hasSearched = false
            searchedQuery = ""
            query = ""
            let result = try await NotionClient(token: accessToken).search(query: "")
            try Task.checkCancellation()
            pages = result.results
            cursor = result.has_more ? result.next_cursor : nil
            hasSearched = true
        }
    }

    private func disconnect() {
        do {
            try credentials.delete()
            token = ""
            pages = []
            cursor = nil
            hasSearched = false
            query = ""
            searchedQuery = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func search(loadMore: Bool = false) {
        guard !busy, !cleanToken.isEmpty else { return }
        if !loadMore {
            pages = []
            cursor = nil
            searchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let client = NotionClient(token: cleanToken)
        run(status: "Searching Notion…") {
            let result = try await client.search(query: searchedQuery, cursor: loadMore ? cursor : nil)
            try Task.checkCancellation()
            guard !result.has_more || (result.next_cursor != nil && result.next_cursor != cursor) else {
                throw NotionImportError.invalidResponse
            }
            var seen = Set(pages.map(\.id))
            pages += result.results.filter { seen.insert($0.id).inserted }
            cursor = result.has_more ? result.next_cursor : nil
            hasSearched = true
        }
    }

    private func importPage(_ page: NotionPage) {
        guard !busy else { return }
        let client = NotionClient(token: cleanToken)
        run(status: "Importing \(page.title)…") {
            let body = try await client.importBody(pageID: page.id)
            try Task.checkCancellation()
            try onImport(page.title, body)
            dismiss()
        }
    }

    private func run(status: String, action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        self.status = status
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                try await action()
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    if case NotionImportError.http(401) = error {
                        disconnect()
                    }
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
