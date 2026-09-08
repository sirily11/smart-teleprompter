import Foundation
import Testing
@testable import smart_teleprompter

private final class NotionStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct NotionClientTests {
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> NotionClient {
        NotionStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotionStub.self]
        return NotionClient(token: "test-token", session: URLSession(configuration: configuration))
    }

    @Test func searchUsesPageFilterAndReturnsTitleAndCursor() async throws {
        let client = client { request in
            #expect(request.url?.path == "/v1/search")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2025-09-03")
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try #require(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    result.append(buffer, count: count)
                }
                data = result
            }
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["query"] as? String == "Talk")
            #expect(json["start_cursor"] as? String == "previous")
            #expect((json["filter"] as? [String: String])?["value"] == "page")
            return (200, #"{"results":[{"id":"page","properties":{"Name":{"title":[{"plain_text":"My "},{"plain_text":"Talk"}]}}}],"has_more":true,"next_cursor":"next"}"#)
        }
        let result = try await client.search(query: "Talk", cursor: "previous")
        #expect(result.results.first?.title == "My Talk")
        #expect(result.next_cursor == "next")
    }

    @Test func importsNestedBlocksAndPaginationInReadingOrder() async throws {
        let client = client { request in
            switch request.url!.path {
            case "/v1/blocks/page/children":
                if request.url!.query!.contains("start_cursor=next") {
                    return (200, #"{"results":[{"id":"end","type":"paragraph","has_children":false,"paragraph":{"rich_text":[{"plain_text":"The end."}]}}],"has_more":false,"next_cursor":null}"#)
                }
                return (200, #"{"results":[{"id":"heading","type":"heading_1","has_children":false,"heading_1":{"rich_text":[{"plain_text":"Hello 世界"}]}},{"id":"list","type":"bulleted_list_item","has_children":true,"bulleted_list_item":{"rich_text":[{"plain_text":"A link"}]}},{"id":"image","type":"image","has_children":false,"image":{"caption":[]}},{"id":"other","type":"child_page","has_children":true,"child_page":{"title":"Other page"}}],"has_more":true,"next_cursor":"next"}"#)
            case "/v1/blocks/list/children":
                return (200, #"{"results":[{"id":"row","type":"table_row","has_children":false,"table_row":{"cells":[[{"plain_text":"One"}],[{"plain_text":"Two"}]]}}],"has_more":false,"next_cursor":null}"#)
            default:
                Issue.record("Unexpected request: \(request.url!.path)")
                return (404, "{}")
            }
        }
        #expect(try await client.importBody(pageID: "page") == "Hello 世界\n\nA link\n\nOne — Two\n\nThe end.")
    }

    @Test func rejectsEmptyPages() async throws {
        let client = client { _ in (200, #"{"results":[],"has_more":false,"next_cursor":null}"#) }
        await #expect(throws: NotionImportError.self) { try await client.importBody(pageID: "empty") }
    }

    @Test(arguments: [401, 403, 404, 500]) func reportsRequestFailures(status: Int) async throws {
        let client = client { _ in (status, "{}") }
        do {
            _ = try await client.importBody(pageID: "page")
            Issue.record("Expected request to fail")
        } catch NotionImportError.http(let actual) { #expect(actual == status) }
    }

    @Test func failsWholeImportWhenNestedContentFails() async throws {
        let client = client { request in
            if request.url!.path == "/v1/blocks/page/children" {
                return (200, #"{"results":[{"id":"nested","type":"toggle","has_children":true,"toggle":{"rich_text":[{"plain_text":"Partial text"}]}}],"has_more":false,"next_cursor":null}"#)
            }
            return (403, "{}")
        }
        await #expect(throws: NotionImportError.self) { try await client.importBody(pageID: "page") }
    }

    @Test func rejectsMissingPaginationCursor() async throws {
        let client = client { _ in (200, #"{"results":[],"has_more":true,"next_cursor":null}"#) }
        await #expect(throws: NotionImportError.self) { try await client.importBody(pageID: "page") }
    }

    @Test func cancellationDoesNotReturnPartialScript() async throws {
        let client = client { _ in (200, #"{"results":[],"has_more":false,"next_cursor":null}"#) }
        let task = Task { try await client.importBody(pageID: "page") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
