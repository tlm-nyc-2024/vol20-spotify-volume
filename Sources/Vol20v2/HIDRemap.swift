//
// HIDRemap.swift — system-volume independence via macOS's `hidutil`.
//
// The Fosi VOL20 emits standard HID Consumer-page Volume Up (0x0C/0xE9)
// and Volume Down (0x0C/0xEA) events on every detent. Out of the box,
// macOS routes these to its system-volume handler, which means turning
// the knob also moves the Mac speaker volume — coupled to Spotify
// Connect's volume in a way we don't want.
//
// macOS's volume handler reads from IOHIDEventSystem (a layer above raw
// IOHIDDevice). Seizing the device at the IOHIDDevice layer DOES NOT
// suppress this — verified live in Phase 5a. The fix is to remap the
// volume usages to "no action" at the IOHIDEventSystem layer using
// macOS's built-in `hidutil` command. Our IOHIDManager listener, which
// operates at a lower layer, still receives the original events.
//
// `hidutil` UserKeyMapping format:
//   - Src: (usage_page << 32) | usage
//   - Dst: same shape; we map to Keyboard-page (0x07) usage 0x00,
//     which is the "NoEvent" sentinel — macOS handlers ignore it.
//   - Matching: { "VendorID": 0x07d7 } scopes the remap to the VOL20
//     specifically; other devices' volume keys (e.g. Apple keyboard's
//     F11/F12) still work normally.
//
// Lifecycle:
//   - Apply on app launch (idempotent — calling twice replaces the
//     same mapping with itself).
//   - Clear on graceful quit so the Mac's volume buttons work normally
//     again if the user has uninstalled Vol20v2.
//   - macOS resets all hidutil property changes on logout/reboot, so
//     a crash leaves at most one session of "extra" remap that will
//     auto-clear at the next logout.
//

import Foundation
import os

enum HIDRemap {

    private static let logger = Logger(subsystem: "com.tlmattson.vol20v2",
                                       category: "HIDRemap")

    /// The HID Usage Tables format (usage_page << 32) | usage,
    /// expressed as the literal hex strings hidutil's JSON parser
    /// accepts. Consumer page 0x0C, Volume Up 0xE9 / Volume Down 0xEA.
    private static let volumeUpSrc   = "0xC000000E9"
    private static let volumeDownSrc = "0xC000000EA"

    /// "NoEvent" sentinel — Keyboard page 0x07, usage 0x00. Handlers
    /// silently ignore this.
    private static let noActionDst   = "0x0700000000"

    /// The VOL20 presents TWO different hardware identities depending on
    /// how it's connected, and macOS treats them as separate devices:
    ///   - Bluetooth-LE: VendorID 0x07d7 (no meaningful ProductID).
    ///   - Wired USB:    VendorID 0x0e55 (Speed Dragon HID chip),
    ///                   ProductID 0x110e.
    /// We must suppress volume keys on BOTH so system volume stays
    /// decoupled on whichever bus is live. For USB we pin VendorID AND
    /// ProductID, because 0x0e55 is a generic HID-chip vendor shared by
    /// many unrelated peripherals — vendor-only would over-match.
    private static let matchings = [
        "{\"VendorID\":0x07d7}",                       // Bluetooth-LE
        "{\"VendorID\":0x0e55,\"ProductID\":0x110e}",  // wired USB
    ]

    /// Apply the suppression — VOL20's Volume Up / Down events become
    /// "no action" for macOS's system handlers, while still flowing to
    /// our lower-level IOHIDManager listener. Applied to every known
    /// identity (BLE + USB) so it works on whichever bus is connected.
    static func suppressVolumeKeys() {
        let mapping = """
        {"UserKeyMapping":[\
        {"HIDKeyboardModifierMappingSrc":\(volumeUpSrc),\
        "HIDKeyboardModifierMappingDst":\(noActionDst)},\
        {"HIDKeyboardModifierMappingSrc":\(volumeDownSrc),\
        "HIDKeyboardModifierMappingDst":\(noActionDst)}\
        ]}
        """
        for matching in matchings {
            run(arguments: ["property", "--matching", matching, "--set", mapping],
                action: "apply")
        }
    }

    /// True if our volume-key suppression is currently active on at least
    /// one of the VOL20's identities.
    ///
    /// This exists because `hidutil … --set` returns SUCCESS even when no
    /// matching device was present to receive the mapping — so "apply OK"
    /// is NOT proof the suppression landed. During a forget/re-pair or a
    /// wake-from-sleep the knob re-enumerates several times, and an apply
    /// that runs mid-churn can land on an instance that's already gone.
    /// We read the mapping back to know whether it really took.
    static func suppressionActive() -> Bool {
        for matching in matchings {
            let out = capture(arguments: ["property", "--matching", matching,
                                          "--get", "UserKeyMapping"]) ?? ""
            if out.contains("HIDKeyboardModifierMappingSrc") { return true }
        }
        return false
    }

    /// Clear the remap on both identities — Mac's system volume keys for
    /// the knob work normally again. Called on graceful quit.
    static func restoreVolumeKeys() {
        let mapping = "{\"UserKeyMapping\":[]}"
        for matching in matchings {
            run(arguments: ["property", "--matching", matching, "--set", mapping],
                action: "restore")
        }
    }

    // ---------------------------------------------------------------
    // run(arguments:action:)
    //
    // Spawns `/usr/bin/hidutil` as a child process. Captures stdout +
    // stderr so any failure ends up in our unified log instead of
    // disappearing into the void.
    // ---------------------------------------------------------------
    // ---------------------------------------------------------------
    // capture(arguments:)
    //
    // Like run(), but RETURNS hidutil's combined stdout/stderr text (or
    // nil on launch failure) instead of just logging it. Used by
    // suppressionActive() to read the current UserKeyMapping back.
    // ---------------------------------------------------------------
    private static func capture(arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            logger.error("hidutil capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func run(arguments: [String], action: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.terminationStatus == 0 {
                logger.notice("hidutil \(action, privacy: .public): OK")
                if !output.isEmpty {
                    logger.debug("hidutil output: \(output, privacy: .public)")
                }
            } else {
                logger.error("hidutil \(action, privacy: .public) failed (exit \(task.terminationStatus)): \(output, privacy: .public)")
            }
        } catch {
            logger.error("Could not run hidutil: \(error.localizedDescription, privacy: .public)")
        }
    }
}
