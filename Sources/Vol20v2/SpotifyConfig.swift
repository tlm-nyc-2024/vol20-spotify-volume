//
// SpotifyConfig.swift — every OAuth and API constant in one place.
//
// We reuse v1's existing Spotify Developer app — the redirect URI
// `http://127.0.0.1:8888/callback` is already registered with Spotify,
// so we don't touch the developer dashboard. The client_secret that v1's
// config.json stored is intentionally NOT here: PKCE replaces it.
//

import Foundation

enum SpotifyConfig {

    /// Reused from v1's Spotify Developer application.
    static let clientID = "fddbf291ddd24d3f9117ae4e5d1f79a1"

    /// Must match exactly what's registered on the Spotify developer app.
    /// Spotify rejects `localhost`; HTTP is allowed only for loopback IPs.
    static let redirectURI = "http://127.0.0.1:8888/callback"

    /// What we ask Spotify for. The user sees this list when authorizing.
    static let scopes = [
        "user-modify-playback-state",
        "user-read-playback-state",
    ]

    // --- Endpoints ---
    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL     = URL(string: "https://accounts.spotify.com/api/token")!
    static let apiBaseURL   = URL(string: "https://api.spotify.com/v1")!

    // --- Local loopback server (catches the OAuth redirect) ---
    static let loopbackPort: UInt16 = 8888
    static let loopbackPath = "/callback"

    /// Preferred Connect device — when present, we target it explicitly so
    /// volume calls don't get re-routed to whatever became "active." Matches
    /// v1's config (`LSX II-Office`).
    static let preferredDeviceName = "LSX II-Office"
}
