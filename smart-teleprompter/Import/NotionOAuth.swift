import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Public application settings, filled once by the app developer, never by users.
/// The Notion client secret belongs only on the OAuth service.
struct NotionOAuthConfiguration {
    static let production = NotionOAuthConfiguration(
        clientID: "3d5d872b-594c-815c-a78f-0037616491bc",
        redirectURI: "https://teleprompter.rxlab.app/api/notion/callback",
        serviceURL: "https://teleprompter.rxlab.app/api/notion"
    )

    let clientID: String
    let redirectURI: String
    let serviceURL: String
    static let callbackScheme = "rxlab-smart-teleprompter"

    func endpoint(_ path: String) throws -> URL {
        guard !clientID.isEmpty,
              let redirect = URL(string: redirectURI), redirect.scheme == "https", redirect.host != nil,
              let service = URL(string: serviceURL), service.scheme == "https", service.host != nil
        else {
            throw NotionOAuthError.notConfigured
        }
        return service.appendingPathComponent(path)
    }
}

enum NotionOAuthError: LocalizedError {
    case notConfigured, invalidCallback, failed, denied

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Notion sign-in is not configured in this version of the app."
        case .invalidCallback: return "Notion sign-in couldn’t be verified. Please connect again."
        case .failed: return "Couldn’t connect to Notion. Please try again."
        case .denied: return "Notion access wasn’t granted. Connect again and select the pages you want to import."
        }
    }
}

@MainActor
final class NotionOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private let configuration: NotionOAuthConfiguration
    private let session: URLSession

    init(configuration: NotionOAuthConfiguration = .production,
         session: URLSession = URLSession(configuration: .ephemeral))
    {
        self.configuration = configuration
        self.session = session
    }

    func connect() async throws -> String {
        // Bind the service's one-time ticket to this app session. Neither the
        // Notion access token nor the verifier travels in a browser URL.
        let verifier = try Self.randomValue()
        let state = try Self.randomValue()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        struct Start: Decodable { let authorization_url: URL }
        let start: Start = try await post("start", body: [
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI,
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256"
        ])
        try Self.validateAuthorizationURL(start.authorization_url, configuration: configuration, state: state)
        let callback = try await authenticate(start.authorization_url)
        try Task.checkCancellation()
        let ticket = try Self.ticket(from: callback, state: state)
        struct Token: Decodable { let access_token: String }
        let token: Token = try await post("exchange", body: ["ticket": ticket, "code_verifier": verifier])
        guard !token.access_token.isEmpty else { throw NotionOAuthError.failed }
        return token.access_token
    }

    func cancel() {
        webSession?.cancel()
        finish(.failure(CancellationError()))
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let web = ASWebAuthenticationSession(url: url,
                                                     callbackURLScheme: NotionOAuthConfiguration.callbackScheme)
                { [weak self] callback, error in
                    Task { @MainActor in
                        if let callback { self?.finish(.success(callback)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self?.finish(.failure(CancellationError()))
                        } else { self?.finish(.failure(NotionOAuthError.failed)) }
                    }
                }
                web.presentationContextProvider = self
                webSession = web
                if !web.start() { finish(.failure(NotionOAuthError.failed)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        webSession = nil
        pending?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #endif
    }

    static func validateAuthorizationURL(_ url: URL, configuration: NotionOAuthConfiguration, state: String) throws {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        func matches(_ name: String, _ value: String) -> Bool {
            let items = query.filter { $0.name == name }
            return items.count == 1 && items.first?.value == value
        }
        guard url.scheme == "https", url.host == "api.notion.com", url.port == nil,
              url.user == nil, url.password == nil, url.path == "/v1/oauth/authorize",
              matches("client_id", configuration.clientID), matches("redirect_uri", configuration.redirectURI),
              matches("state", state), matches("response_type", "code"), matches("owner", "user")
        else {
            throw NotionOAuthError.invalidCallback
        }
    }

    static func ticket(from url: URL, state: String) throws -> String {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = query.filter { $0.name == "state" }
        guard url.scheme == NotionOAuthConfiguration.callbackScheme, url.host == "notion",
              url.path == "/callback", states.count == 1, states.first?.value == state
        else {
            throw NotionOAuthError.invalidCallback
        }
        if query.contains(where: { $0.name == "error" }) { throw NotionOAuthError.denied }
        let tickets = query.filter { $0.name == "ticket" }
        guard tickets.count == 1, let ticket = tickets.first?.value, !ticket.isEmpty else {
            throw NotionOAuthError.invalidCallback
        }
        return ticket
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NotionOAuthError.failed
        }
        return Data(bytes).base64URLEncoded
    }

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var request = try URLRequest(url: configuration.endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
            throw NotionOAuthError.failed
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
