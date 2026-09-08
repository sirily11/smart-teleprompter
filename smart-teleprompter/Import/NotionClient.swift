import Foundation

struct NotionPage: Identifiable, Decodable {
    let id: String
    let properties: [String: Property]

    struct Property: Decodable {
        let title: [NotionRichText]?
    }

    var title: String {
        let text = properties.values.compactMap(\.title).first?
            .map(\.plain_text).joined() ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : text
    }
}

struct NotionRichText: Decodable {
    let plain_text: String
}

struct NotionList<Item: Decodable>: Decodable {
    let results: [Item]
    let has_more: Bool
    let next_cursor: String?
}

struct NotionBlock: Decodable {
    let id: String
    let type: String
    let has_children: Bool
    let content: Content?

    struct Content: Decodable {
        let rich_text: [NotionRichText]?
        let cells: [[NotionRichText]]?
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        id = try values.decode(String.self, forKey: Key("id"))
        type = try values.decode(String.self, forKey: Key("type"))
        has_children = try values.decode(Bool.self, forKey: Key("has_children"))
        content = try values.decodeIfPresent(Content.self, forKey: Key(type))
    }

    var text: String {
        if let cells = content?.cells {
            return cells.map { $0.map(\.plain_text).joined() }.joined(separator: " — ")
        }
        return content?.rich_text?.map(\.plain_text).joined() ?? ""
    }

    // Child pages and databases are separate documents, not part of this script.
    var includesChildren: Bool {
        has_children && type != "child_page" && type != "child_database"
    }
}

enum NotionImportError: LocalizedError {
    case http(Int), invalidResponse, emptyPage, tooDeep

    var errorDescription: String? {
        switch self {
        case .http(401): return "Your Notion connection has expired. Reconnect to Notion and try again."
        case .http(403), .http(404): return "Notion couldn’t access this page. Reconnect to Notion and select the page to grant access."
        case .http(429): return "Notion is receiving too many requests. Wait a moment and try again."
        case .http: return "Notion couldn’t complete the request. Please try again."
        case .invalidResponse: return "Notion returned an unexpected response. Please try again."
        case .emptyPage: return "This page has no readable text. Choose a page containing text rather than only media or subpages."
        case .tooDeep: return "This page has too many nested blocks to import. Try a smaller page."
        }
    }
}

struct NotionClient {
    let token: String
    var session: URLSession = URLSession(configuration: .ephemeral)

    func search(query: String, cursor: String? = nil) async throws -> NotionList<NotionPage> {
        var body: [String: Any] = [
            "filter": ["property": "object", "value": "page"],
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            "page_size": 100
        ]
        if !query.isEmpty { body["query"] = query }
        if let cursor { body["start_cursor"] = cursor }
        return try await request(path: "search", body: body)
    }

    func importBody(pageID: String) async throws -> String {
        let lines = try await children(id: pageID, depth: 0)
        let text = lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NotionImportError.emptyPage }
        return text
    }

    private func children(id: String, depth: Int) async throws -> [String] {
        guard depth < 50 else { throw NotionImportError.tooDeep }
        var lines: [String] = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            let page: NotionList<NotionBlock> = try await request(path: "blocks/\(id)/children", query: query)
            for block in page.results {
                if !block.text.isEmpty { lines.append(block.text) }
                if block.includesChildren {
                    lines += try await children(id: block.id, depth: depth + 1)
                }
            }
            guard !page.has_more || (page.next_cursor != nil && page.next_cursor != cursor) else {
                throw NotionImportError.invalidResponse
            }
            cursor = page.has_more ? page.next_cursor : nil
        } while cursor != nil
        return lines
    }

    private func request<T: Decodable>(path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        var url = URLComponents(string: "https://api.notion.com/v1/\(path)")!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw NotionImportError.invalidResponse }
            if response.statusCode == 429, attempt < 2 {
                let delay = min(max(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1, 1), 30)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw NotionImportError.http(response.statusCode) }
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw NotionImportError.http(429)
    }
}
