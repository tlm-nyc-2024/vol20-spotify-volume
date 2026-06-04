//
// VolumeController.swift — the glue between knob detents and Spotify.
//
// Lifecycle of one knob spin (5 detents to the right, say):
//
//   detent  →  recordDetent(.up)   pending = +1, arm 300ms timer
//   detent  →  recordDetent(.up)   pending = +2, RE-arm timer
//   detent  →  recordDetent(.up)   pending = +3, RE-arm timer
//   detent  →  recordDetent(.up)   pending = +4, RE-arm timer
//   detent  →  recordDetent(.up)   pending = +5, RE-arm timer
//   (user stops turning)
//   …300 ms later…
//   timer fires → applyAccumulated()
//      • resolve preferred device (cached after first lookup)
//      • read current volume (either fresh GET, or last-write cache
//        if we just wrote within the past 2 seconds)
//      • compute target = current + (pending × stepSize), clamp to 0…100
//      • PUT new volume
//      • remember (target, now()) in the last-write cache
//      • reset pending = 0
//
// Why this shape:
//   * Debounce keeps us under Spotify's rate limit even on fast spins.
//   * Read-before-write keeps us self-healing against external changes
//     (someone uses the KEF's own remote, Spotify Connect drifts, etc.).
//   * The last-write cache patches the documented eventual-consistency
//     window where GET-immediately-after-PUT can return the pre-PUT
//     value — only used as a baseline for ~2 seconds after our own
//     write, so external changes still get picked up afterward.
//   * Device pinning makes us robust to "active device" flicker (e.g.
//     when Spotify is also open on a phone).
//

import Foundation
import os

@MainActor
final class VolumeController {

    // MARK: - Configuration (will be settings-driven in Phase 4)

    /// Percent change per detent. v1 used 3.
    var stepSize: Int = 3

    /// Milliseconds of "no detent" before we fire the API call.
    var debounceMilliseconds: Int = 300

    /// How long to trust our own most recent write as the read-before-
    /// write baseline (Spotify Connect's eventual-consistency window).
    var lastWriteTrustSeconds: TimeInterval = 2.0

    // MARK: - Dependencies / collaborators

    private let spotify: SpotifyClient
    private static let logger = Logger(subsystem: "com.tlmattson.vol20v2",
                                       category: "Volume")

    /// UI-facing status callback. Fired on the main actor.
    var onUpdate: ((Update) -> Void)?
    struct Update {
        /// Signed detent count waiting to be applied (positive = louder).
        let pending: Int
        /// Most recent successful write, e.g. "LSX II-Office → 67%".
        /// nil before the first write.
        let lastWrittenDescription: String?
        /// A short status line: "idle", "queued: +3", "applying…",
        /// "LSX II-Office → 67%", "error: …".
        let status: String
    }

    // MARK: - State

    /// Signed detent accumulator. Cleared at the start of applyAccumulated.
    private var pending: Int = 0

    /// Resolved once we successfully match preferred device by name.
    private var pinnedDeviceID: String?
    private var pinnedDeviceName: String?

    /// What we last wrote, and when. Used as the read baseline during
    /// Spotify's eventual-consistency window.
    private var lastWrittenVolume: Int?
    private var lastWriteTime: Date?

    /// Most recent "Name → N%" string, for the UI.
    private var lastWrittenDescription: String?

    private var debounceTimer: Timer?
    private var inFlight: Bool = false

    // MARK: - Init

    init(spotify: SpotifyClient) {
        self.spotify = spotify
    }

    // MARK: - Public API

    /// Called once per HID detent (from AppState's HIDListener.onDetent
    /// closure). Synchronously updates pending count + debounce timer;
    /// the actual API call happens later when the timer fires.
    func recordDetent(_ direction: HIDListener.Direction) {
        let delta: Int
        switch direction {
        case .up:    delta = +1
        case .down:  delta = -1
        case .other: return        // unrecognized usage; ignore
        }
        pending += delta
        publishUpdate(status: pendingStatusLine())
        armDebounceTimer()
    }

    /// Phase 4 will call this from a slider.
    func setStepSize(_ newValue: Int) {
        stepSize = max(1, min(20, newValue))
    }

    // MARK: - Debounce

    private func armDebounceTimer() {
        debounceTimer?.invalidate()
        let interval = TimeInterval(debounceMilliseconds) / 1000.0
        debounceTimer = Timer.scheduledTimer(withTimeInterval: interval,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.applyAccumulated()
            }
        }
    }

    // MARK: - The main routine

    private func applyAccumulated() async {
        // Snapshot and clear immediately so new detents arriving during
        // the async work below start a fresh batch.
        let delta = pending
        pending = 0
        guard delta != 0 else { return }

        // Prevent overlapping API calls if a previous one's still in
        // flight; just put the work back and re-arm.
        guard !inFlight else {
            pending += delta
            armDebounceTimer()
            return
        }
        inFlight = true
        defer { inFlight = false }

        let signedPct = delta * stepSize
        publishUpdate(status: "applying \(signedPct > 0 ? "+" : "")\(signedPct)%…")

        do {
            // 1. Resolve which device to target.
            let deviceID = try await resolveDeviceID()

            // 2. Read current volume — either from our recent-write
            //    cache (if fresh) or from a live GET.
            let currentVolume = try await readCurrentVolume(deviceID: deviceID)

            // 3. Compute new target.
            let target = max(0, min(100, currentVolume + signedPct))

            // 4. Write.
            try await spotify.setVolume(target, deviceID: deviceID)

            // 5. Update the last-write cache for the next batch.
            lastWrittenVolume = target
            lastWriteTime = Date()
            let name = pinnedDeviceName ?? "Active device"
            let desc = "\(name) → \(target)%"
            lastWrittenDescription = desc
            Self.logger.notice("Wrote \(desc, privacy: .public)  (delta \(signedPct))")
            publishUpdate(status: desc)

        } catch {
            Self.logger.error("Volume apply failed: \(error.localizedDescription, privacy: .public)")
            publishUpdate(status: "error: \(error.localizedDescription)")
        }
    }

    // MARK: - Device & volume resolution

    /// First call: list devices, find by preferred name, cache id.
    /// Subsequent calls: return cached id.
    private func resolveDeviceID() async throws -> String? {
        if let id = pinnedDeviceID { return id }

        let devices = try await spotify.listDevices()
        if let match = devices.first(where: { $0.name == SpotifyConfig.preferredDeviceName }) {
            pinnedDeviceID = match.id
            pinnedDeviceName = match.name
            Self.logger.notice("Pinned preferred device: \(match.name, privacy: .public)")
            return match.id
        }

        // Preferred device not in the list right now — fall back to
        // "active device" (nil device_id), which Spotify will resolve.
        Self.logger.notice("Preferred device '\(SpotifyConfig.preferredDeviceName, privacy: .public)' not found; falling back to active device")
        return nil
    }

    /// Returns the volume we should base the next delta on. Prefers our
    /// own recent write (within the trust window); else does a fresh GET.
    private func readCurrentVolume(deviceID: String?) async throws -> Int {
        if let cached = lastWrittenVolume,
           let t = lastWriteTime,
           Date().timeIntervalSince(t) < lastWriteTrustSeconds {
            return cached
        }

        if let state = try await spotify.getPlaybackState(),
           let v = state.device.volume_percent {
            return v
        }

        // No active playback — peek at the device list directly.
        let devices = try await spotify.listDevices()
        if let id = deviceID,
           let d = devices.first(where: { $0.id == id }),
           let v = d.volume_percent {
            return v
        }
        if let d = devices.first(where: { $0.volume_percent != nil }),
           let v = d.volume_percent {
            return v
        }

        // Truly nothing — return a neutral midpoint so we don't NaN.
        return 50
    }

    // MARK: - UI helpers

    private func pendingStatusLine() -> String {
        if pending == 0 { return "idle" }
        let sign = pending > 0 ? "+" : ""
        return "queued: \(sign)\(pending) detents (\(sign)\(pending * stepSize)%)"
    }

    private func publishUpdate(status: String) {
        onUpdate?(Update(pending: pending,
                         lastWrittenDescription: lastWrittenDescription,
                         status: status))
    }
}
