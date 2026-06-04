//
// TokenStorage.swift — where the refresh token lives on disk.
//
// We *originally* used the macOS Keychain (Security framework). That's the
// right answer for a production app signed with a real Apple Developer ID,
// because the Keychain's ACL keys off the developer's stable team ID.
//
// For ad-hoc-signed development builds, every rebuild changes the binary's
// code hash → macOS treats each build as "a different app" trying to read
// the existing Keychain item → prompts for the user's login password on
// every call, even after clicking "Always Allow" (which only persists
// until the next rebuild).
//
// So during development we use a plain file in Application Support:
//   ~/Library/Application Support/Vol20v2/spotify.refresh_token
// with POSIX mode 0600 (owner read/write only). No prompts. Same trust
// model as v1's plaintext-token-cache approach.
//
// When we eventually ship signed with a stable identity, swap the
// internals back to Security/Keychain — the public API is the same.
//

import Foundation
import os

enum TokenStorage {

    /// Named secrets. Filenames mirror these strings.
    enum Key: String {
        case refreshToken = "spotify.refresh_token"
    }

    enum StorageError: Error, LocalizedError {
        case encoding
        case ioError(Error)

        var errorDescription: String? {
            switch self {
            case .encoding:           return "Could not UTF-8-encode value"
            case .ioError(let e):     return "I/O error: \(e.localizedDescription)"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.tlmattson.vol20v2",
                                       category: "TokenStorage")

    /// `~/Library/Application Support/Vol20v2/`, created on first access.
    private static var directory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Vol20v2", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        return dir
    }

    private static func url(for key: Key) -> URL {
        directory.appendingPathComponent(key.rawValue)
    }

    /// Atomically writes the value to a per-key file, then locks it to 0600.
    static func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else { throw StorageError.encoding }
        let target = url(for: key)
        do {
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: target.path
            )
        } catch {
            throw StorageError.ioError(error)
        }
    }

    /// Returns the stored UTF-8 string, or nil if missing / unreadable.
    static func load(_ key: Key) -> String? {
        let target = url(for: key)
        guard let data = try? Data(contentsOf: target),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Returns true if a value was removed.
    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let target = url(for: key)
        return (try? FileManager.default.removeItem(at: target)) != nil
    }
}
