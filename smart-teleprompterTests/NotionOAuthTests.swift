import Foundation
import Testing
@testable import smart_teleprompter

@MainActor
struct NotionOAuthTests {
    private let configuration = NotionOAuthConfiguration(
        clientID: "app-id", redirectURI: "https://example.com/notion/callback",
        serviceURL: "https://example.com/notion")

    @Test func acceptsBoundTicket() throws {
        let url = URL(string: "rxlab-smart-teleprompter://notion/callback?ticket=one-use&state=expected")!
        #expect(try NotionOAuth.ticket(from: url, state: "expected") == "one-use")
    }

    @Test(arguments: [
        "rxlab-smart-teleprompter://notion/callback?ticket=t&state=wrong",
        "rxlab-smart-teleprompter://notion/callback?ticket=t&state=expected&state=other",
        "rxlab-smart-teleprompter://notion/callback?ticket=t&ticket=other&state=expected",
        "https://notion/callback?ticket=t&state=expected",
        "rxlab-smart-teleprompter://other/callback?ticket=t&state=expected",
        "rxlab-smart-teleprompter://notion/callback?state=expected"
    ]) func rejectsUnboundCallbacks(raw: String) throws {
        #expect(throws: NotionOAuthError.self) {
            try NotionOAuth.ticket(from: URL(string: raw)!, state: "expected")
        }
    }

    @Test func handlesDenial() throws {
        #expect(throws: NotionOAuthError.self) {
            try NotionOAuth.ticket(from: URL(string: "rxlab-smart-teleprompter://notion/callback?error=access_denied&state=expected")!, state: "expected")
        }
    }

    @Test func validatesNotionAuthorizationDestination() throws {
        var url = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: "app-id"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "state", value: "expected"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "owner", value: "user")
        ]
        try NotionOAuth.validateAuthorizationURL(url.url!, configuration: configuration, state: "expected")
        #expect(throws: NotionOAuthError.self) {
            try NotionOAuth.validateAuthorizationURL(url.url!, configuration: configuration, state: "wrong")
        }
        url.host = "untrusted.example"
        #expect(throws: NotionOAuthError.self) {
            try NotionOAuth.validateAuthorizationURL(url.url!, configuration: configuration, state: "expected")
        }
    }

    @Test func missingDeveloperConfigurationFailsBeforeNetwork() throws {
        #expect(throws: NotionOAuthError.self) {
            try NotionOAuthConfiguration(clientID: "", redirectURI: "", serviceURL: "").endpoint("start")
        }
    }
}
