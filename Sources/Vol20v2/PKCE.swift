//
// PKCE.swift — Proof Key for Code Exchange helpers.
//
// PKCE is the OAuth 2.0 extension that lets a "public client" (any app
// that can't keep a secret, including this native macOS app) prove that
// it's the same client that initiated the login. Instead of a baked-in
// secret, every login generates a fresh per-session secret on the fly.
//
// The flow uses two values:
//
//   verifier  — a long random string we keep ONLY in memory during login.
//   challenge — SHA256(verifier), base64url-encoded.
//
// Round trip:
//   1. We send `challenge` to Spotify when redirecting the user to log in.
//   2. After login, Spotify gives us a `code`.
//   3. We POST the code back AND the original `verifier`.
//   4. Spotify hashes the verifier, compares to the challenge it remembered,
//      and only issues the token if they match.
//
// "base64url" = standard base64 but: + → -, / → _, no trailing = padding.
// Spotify (and the spec) require that variant.
//

import Foundation
import CryptoKit
import Security

enum PKCE {

    /// Generates a 32-byte cryptographically-random code verifier,
    /// base64url-encoded. The result is ~43 characters, well within
    /// Spotify's 43–128 character requirement.
    static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }

    /// Returns SHA256(verifier) as a base64url string — the value we send
    /// to Spotify as `code_challenge`.
    static func challenge(forVerifier verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }
}

private extension Data {
    /// base64url-encoding (RFC 4648 §5): + → -, / → _, no padding.
    func base64URLEncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
