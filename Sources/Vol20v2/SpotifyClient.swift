//
// SpotifyClient.swift — the only thing in the app that talks to Spotify.
//
// Public API (all async):
//   authenticate()                          — runs the PKCE browser flow once
//   ensureValidAccessToken() -> String      — refreshes if near expiry
//   getPlaybackState() -> PlaybackState?    — nil if no active device (HTTP 204)
//   setVolume(_, deviceID:) -> Void
//   listDevices() -> [Device]
//   logOut()                                — wipes the refresh token
//
// Threading: the client itself is a plain class (no actor). All long-running
// work happens via URLSession's async API, which is safe to call from
// anywhere. Only the @MainActor UI layer reads its state.
//
// Token model:
//   accessToken (in-memory, ~1 hour TTL)
//   refreshToken (Keychain, effectively until revoked)
// On first use after launch we refresh the access token using the stored
// refresh token; from then on we re-refresh when within 60 seconds of expiry.
//

import Foundation
import AppKit
import os

final class SpotifyClient {

    private static let logger = Logger(subsystem: "com.tlmattson.vol20v2",
                                       category: "Spotify")

    /// Access token — kept only in memory. nil until first refresh/exchange.
    private var accessToken: String?
    /// Wall-clock time the access token expires.
    private var accessTokenExpiry: Date?

    /// True iff a refresh token is stored — i.e. user has previously authenticated.
    var hasStoredCredentials: Bool {
        TokenStorage.load(.refreshToken) != nil
    }

    // ===================================================================
    // MARK: - Authentication (PKCE flow)
    // ===================================================================

    /// Runs the full OAuth 2.0 Authorization Code + PKCE flow.
    /// Opens the user's default browser, waits for the loopback redirect,
    /// exchanges the code for tokens, and stores the refresh token in Keychain.
    func authenticate() async throws {
        let verifier  = PKCE.generateVerifier()
        let challenge = PKCE.challenge(forVerifier: verifier)
        let state     = UUID().uuidString

        // 1. Build the /authorize URL.
        var components = URLComponents(url: SpotifyConfig.authorizeURL,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: SpotifyConfig.clientID),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "redirect_uri",          value: SpotifyConfig.redirectURI),
            URLQueryItem(name: "scope",                 value: SpotifyConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "state",                 value: state),
        ]

        // 2. Start the loopback server BEFORE opening the browser — otherwise
        //    Spotify's redirect could race the listener startup.
        let server = try LoopbackServer(port: SpotifyConfig.loopbackPort)
        async let callbackURL = server.awaitCallback()

        // 3. Open the user's default browser at the /authorize URL.
        guard let url = components.url else { throw SpotifyError.unknown }
        Self.logger.notice("Opening browser for Spotify authentication…")
        NSWorkspace.shared.open(url)

        // 4. Wait for the redirect back to 127.0.0.1:8888/callback.
        let cb = try await callbackURL
        Self.logger.notice("Received OAuth callback")

        // 5. Validate the callback URL.
        guard let cbComponents = URLComponents(url: cb, resolvingAgainstBaseURL: false),
              let items = cbComponents.queryItems else {
            throw SpotifyError.noCode
        }
        if let errorParam = items.first(where: { $0.name == "error" })?.value {
            throw SpotifyError.authError(errorParam)
        }
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            throw SpotifyError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.noCode
        }

        // 6. Exchange the code (+verifier) for tokens.
        let tokens = try await exchangeAuthorizationCode(code: code, verifier: verifier)
        applyTokens(tokens)
        Self.logger.notice("Authentication complete; refresh token stored on disk")
    }

    /// Discard the refresh token and clear in-memory access token.
    /// Next API call will throw `.notAuthenticated`.
    func logOut() {
        TokenStorage.delete(.refreshToken)
        accessToken = nil
        accessTokenExpiry = nil
    }

    // ===================================================================
    // MARK: - Token housekeeping
    // ===================================================================

    /// Returns a usable access token, refreshing if needed.
    /// Throws `.notAuthenticated` if we have no refresh token at all.
    @discardableResult
    func ensureValidAccessToken() async throws -> String {
        if let token = accessToken,
           let expiry = accessTokenExpiry,
           expiry > Date().addingTimeInterval(60) {
            return token
        }
        try await refreshAccessToken()
        guard let token = accessToken else { throw SpotifyError.notAuthenticated }
        return token
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = TokenStorage.load(.refreshToken) else {
            throw SpotifyError.notAuthenticated
        }
        let body: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     SpotifyConfig.clientID,
        ]
        let tokens = try await postTokenForm(body)
        applyTokens(tokens)
    }

    private func exchangeAuthorizationCode(code: String, verifier: String) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type":    "authorization_code",
            "code":          code,
            "redirect_uri":  SpotifyConfig.redirectURI,
            "client_id":     SpotifyConfig.clientID,
            "code_verifier": verifier,
        ]
        return try await postTokenForm(body)
    }

    private func postTokenForm(_ body: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: SpotifyConfig.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = formURLEncoded(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.unknown }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? "<no body>"
            Self.logger.error("Token endpoint \(http.statusCode, privacy: .public): \(snippet, privacy: .public)")
            throw SpotifyError.tokenExchangeFailed(http.statusCode)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func applyTokens(_ tokens: TokenResponse) {
        accessToken = tokens.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
        // Spotify may or may not include a new refresh token on refresh; if
        // absent, keep using the existing one (per spec).
        if let rt = tokens.refresh_token, !rt.isEmpty {
            try? TokenStorage.save(rt, for: .refreshToken)
        }
    }

    // ===================================================================
    // MARK: - Web API calls
    // ===================================================================

    /// `GET /me/player` — current playback. Returns nil for HTTP 204
    /// ("no active device"), which is a valid normal state.
    func getPlaybackState() async throws -> PlaybackState? {
        let (data, http) = try await apiGET(path: "me/player")
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyError.apiError(http.statusCode)
        }
        return try JSONDecoder().decode(PlaybackState.self, from: data)
    }

    /// `GET /me/player/devices` — every device Spotify Connect knows about.
    func listDevices() async throws -> [Device] {
        let (data, http) = try await apiGET(path: "me/player/devices")
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyError.apiError(http.statusCode)
        }
        return try JSONDecoder().decode(DeviceListResponse.self, from: data).devices
    }

    /// `PUT /me/player/volume?volume_percent={0-100}` — set the active
    /// (or `deviceID`-pinned) device's volume.
    func setVolume(_ percent: Int, deviceID: String? = nil) async throws {
        let clamped = max(0, min(100, percent))
        var components = URLComponents(
            url: SpotifyConfig.apiBaseURL.appendingPathComponent("me/player/volume"),
            resolvingAgainstBaseURL: false
        )!
        var items = [URLQueryItem(name: "volume_percent", value: "\(clamped)")]
        if let deviceID { items.append(URLQueryItem(name: "device_id", value: deviceID)) }
        components.queryItems = items

        let token = try await ensureValidAccessToken()
        var req = URLRequest(url: components.url!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.unknown }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyError.apiError(http.statusCode)
        }
    }

    // ===================================================================
    // MARK: - Helpers
    // ===================================================================

    private func apiGET(path: String) async throws -> (Data, HTTPURLResponse) {
        let token = try await ensureValidAccessToken()
        var req = URLRequest(url: SpotifyConfig.apiBaseURL.appendingPathComponent(path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.unknown }
        return (data, http)
    }

    /// application/x-www-form-urlencoded — Spotify's token endpoint expects this.
    private func formURLEncoded(_ pairs: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        let joined = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return joined.data(using: .utf8) ?? Data()
    }

    // ===================================================================
    // MARK: - Models
    // ===================================================================

    struct TokenResponse: Codable {
        let access_token: String
        let token_type: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }

    struct PlaybackState: Codable {
        struct DeviceInfo: Codable {
            let id: String?
            let name: String
            let volume_percent: Int?
            let supports_volume: Bool?
            let is_restricted: Bool?
        }
        let device: DeviceInfo
        let is_playing: Bool
    }

    struct Device: Codable, Identifiable {
        let id: String?
        let name: String
        let is_active: Bool
        let volume_percent: Int?
        let supports_volume: Bool?
    }

    struct DeviceListResponse: Codable {
        let devices: [Device]
    }

    enum SpotifyError: Error, LocalizedError {
        case stateMismatch
        case noCode
        case authError(String)
        case tokenExchangeFailed(Int)
        case notAuthenticated
        case apiError(Int)
        case unknown

        var errorDescription: String? {
            switch self {
            case .stateMismatch:        return "OAuth state mismatch (possible CSRF)"
            case .noCode:               return "No authorization code in callback"
            case .authError(let e):     return "Spotify returned error=\(e)"
            case .tokenExchangeFailed(let code):
                return "Spotify token endpoint returned HTTP \(code)"
            case .notAuthenticated:     return "Not authenticated (no refresh token)"
            case .apiError(let code):   return "Spotify API returned HTTP \(code)"
            case .unknown:              return "Unknown Spotify client error"
            }
        }
    }
}
