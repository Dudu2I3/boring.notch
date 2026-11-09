//
//  SpotifyWebAPI.swift
//  boringNotch
//
//  OAuth (Authorization Code + PKCE) and the small slice of the Spotify Web API
//  needed to like / unlike the current track. The desktop Spotify app has no
//  AppleScript property for "liked", so this is the only reliable way.
//

import AppKit
import AuthenticationServices
import CryptoKit
import Defaults
import Foundation
import Security

// MARK: - Errors

enum SpotifyWebAPIError: LocalizedError {
    case notConnected
    case missingClientID
    case authorizationFailed(String)
    case http(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Spotify is not connected."
        case .missingClientID:
            return "Enter your Spotify Client ID first."
        case .authorizationFailed(let message):
            return "Spotify authorization failed: \(message)"
        case .http(let status, let message):
            return "Spotify error \(status): \(message)"
        case .invalidResponse:
            return "Unexpected response from Spotify."
        }
    }
}

// MARK: - Tokens + Keychain

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// Stores the OAuth tokens as one generic-password item in the Keychain.
private enum SpotifyKeychain {
    private static let service = "com.boringnotch.spotify"
    private static let account = "oauth-tokens"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> SpotifyTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    static func save(_ tokens: SpotifyTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Auth manager

/// Handles the Spotify login (PKCE) and keeps the access token fresh.
/// The Client ID is supplied by the user in Settings > Media (Defaults[.spotifyClientID]).
final class SpotifyAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyAuthManager()

    /// Must be added to "Redirect URIs" of the app in the Spotify Developer Dashboard.
    static let redirectURI = "boringnotch://spotify-callback"
    private static let callbackScheme = "boringnotch"
    private static let scopes = "user-library-read user-library-modify"

    /// For the UI. Always mutated on the main thread.
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isAuthorizing: Bool = false
    @Published private(set) var lastError: String?

    private let lock = NSLock()
    private var tokens: SpotifyTokens?
    private var refreshTask: Task<String, Error>?
    private var authSession: ASWebAuthenticationSession?

    /// Thread-safe check used by the media controller.
    var hasCredentials: Bool {
        lock.withLock { tokens != nil }
    }

    private override init() {
        let stored = SpotifyKeychain.load()
        self.tokens = stored
        self.isConnected = stored != nil
        super.init()
    }

    // MARK: Connect / disconnect

    @MainActor
    func connect() async {
        let clientID = Defaults[.spotifyClientID].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            lastError = SpotifyWebAPIError.missingClientID.localizedDescription
            return
        }
        guard !isAuthorizing else { return }

        isAuthorizing = true
        lastError = nil
        defer { isAuthorizing = false }

        do {
            let verifier = Self.randomString(length: 64)
            let state = Self.randomString(length: 16)

            var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
                URLQueryItem(name: "scope", value: Self.scopes),
                URLQueryItem(name: "state", value: state),
            ]

            let callbackURL = try await runWebAuthentication(url: components.url!)
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

            if let error = items.first(where: { $0.name == "error" })?.value {
                throw SpotifyWebAPIError.authorizationFailed(error)
            }
            guard items.first(where: { $0.name == "state" })?.value == state else {
                throw SpotifyWebAPIError.authorizationFailed("state mismatch")
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                throw SpotifyWebAPIError.authorizationFailed("no code returned")
            }

            let response = try await requestTokens([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID,
                "code_verifier": verifier,
            ])
            guard let refreshToken = response.refresh_token else {
                throw SpotifyWebAPIError.invalidResponse
            }
            store(
                SpotifyTokens(
                    accessToken: response.access_token,
                    refreshToken: refreshToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in))
                )
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User closed the login window, not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        lock.withLock {
            tokens = nil
            refreshTask?.cancel()
            refreshTask = nil
        }
        SpotifyKeychain.delete()
        publishConnected(false)
    }

    func reportError(_ message: String?) {
        DispatchQueue.main.async { self.lastError = message }
    }

    // MARK: Access token

    /// Returns a valid access token, refreshing it when it is about to expire.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = lock.withLock({ tokens }) else {
            throw SpotifyWebAPIError.notConnected
        }
        if !forceRefresh, current.expiresAt > Date().addingTimeInterval(60) {
            return current.accessToken
        }

        // Share one refresh between concurrent callers.
        let task: Task<String, Error> = lock.withLock {
            if let existing = refreshTask { return existing }
            let created = Task { try await self.performRefresh(refreshToken: current.refreshToken) }
            refreshTask = created
            return created
        }

        do {
            let token = try await task.value
            lock.withLock { refreshTask = nil }
            return token
        } catch {
            lock.withLock { refreshTask = nil }
            throw error
        }
    }

    private func performRefresh(refreshToken: String) async throws -> String {
        let clientID = Defaults[.spotifyClientID].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw SpotifyWebAPIError.missingClientID }

        do {
            let response = try await requestTokens([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ])
            // Spotify may or may not rotate the refresh token.
            store(
                SpotifyTokens(
                    accessToken: response.access_token,
                    refreshToken: response.refresh_token ?? refreshToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in))
                )
            )
            return response.access_token
        } catch SpotifyWebAPIError.http(let status, let message)
            where status == 400 && message.hasPrefix("invalid_grant")
        {
            // Refresh token revoked or Client ID changed: ask the user to log in again.
            disconnect()
            reportError("Spotify session expired. Please connect again.")
            throw SpotifyWebAPIError.notConnected
        }
    }

    private func store(_ newTokens: SpotifyTokens) {
        lock.withLock { tokens = newTokens }
        SpotifyKeychain.save(newTokens)
        publishConnected(true)
    }

    private func publishConnected(_ value: Bool) {
        DispatchQueue.main.async {
            if self.isConnected != value { self.isConnected = value }
        }
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private struct TokenErrorResponse: Decodable {
        let error: String?
        let error_description: String?
    }

    private func requestTokens(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyWebAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            let message = [decoded?.error, decoded?.error_description]
                .compactMap { $0 }
                .joined(separator: ": ")
            throw SpotifyWebAPIError.http(
                status: http.statusCode,
                message: message.isEmpty ? "token request failed" : message
            )
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Web authentication session

    @MainActor
    private func runWebAuthentication(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] callbackURL, error in
                self?.authSession = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(
                        throwing: error ?? SpotifyWebAPIError.authorizationFailed("cancelled")
                    )
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            if !session.start() {
                authSession = nil
                continuation.resume(
                    throwing: SpotifyWebAPIError.authorizationFailed("could not open the login window")
                )
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    // MARK: PKCE helpers

    private static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let body = params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - Library API (likes)

/// Like / unlike / check a track in the user's Spotify library.
///
/// Primary endpoints are the long-standing `/me/tracks` ones. If Spotify answers
/// 404/410 (endpoint retired in favour of the generic `/me/library`), the `/me/library`
/// variants with `spotify:track:` URIs are tried instead.
enum SpotifyLibraryAPI {
    private static let base = "https://api.spotify.com/v1"

    static func isSaved(trackID: String) async throws -> Bool {
        var (data, status) = try await send("GET", "/me/tracks/contains", [idQuery(trackID)])
        if status == 404 || status == 410 {
            (data, status) = try await send("GET", "/me/library/contains", [uriQuery(trackID)])
        }
        try check(status, data)
        guard let flags = try? JSONDecoder().decode([Bool].self, from: data),
            let first = flags.first
        else { throw SpotifyWebAPIError.invalidResponse }
        return first
    }

    static func setSaved(_ saved: Bool, trackID: String) async throws {
        let method = saved ? "PUT" : "DELETE"
        var (data, status) = try await send(method, "/me/tracks", [idQuery(trackID)])
        if status == 404 || status == 410 {
            (data, status) = try await send(method, "/me/library", [uriQuery(trackID)])
        }
        try check(status, data)
    }

    // MARK: Internals

    private static func idQuery(_ trackID: String) -> URLQueryItem {
        URLQueryItem(name: "ids", value: trackID)
    }

    private static func uriQuery(_ trackID: String) -> URLQueryItem {
        URLQueryItem(name: "uris", value: "spotify:track:\(trackID)")
    }

    private struct APIErrorEnvelope: Decodable {
        struct Inner: Decodable { let message: String? }
        let error: Inner?
    }

    private static func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        var message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error?.message
            ?? "request failed"
        if status == 403 {
            message += " (is your Spotify account added under User Management of your app in the Developer Dashboard?)"
        }
        throw SpotifyWebAPIError.http(status: status, message: message)
    }

    /// Sends an authorized request, refreshing the token once on 401.
    private static func send(
        _ method: String,
        _ path: String,
        _ query: [URLQueryItem]
    ) async throws -> (Data, Int) {
        var forceRefresh = false
        for attempt in 0..<2 {
            let token = try await SpotifyAuthManager.shared.validAccessToken(forceRefresh: forceRefresh)

            var components = URLComponents(string: base + path)!
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            if method == "PUT" { request.httpBody = Data() }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SpotifyWebAPIError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 {
                forceRefresh = true
                continue
            }
            return (data, http.statusCode)
        }
        throw SpotifyWebAPIError.invalidResponse
    }
}
