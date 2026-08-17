//
// Vol20v2App.swift — entry point of the Vol20 v2.0 menu-bar app.
//
// Phase 1: HIDListener + burst indicator.
// Phase 2: SpotifyClient (PKCE + Web API).
// Phase 3: VolumeController glues detents → debounced read-before-write.
// Phase 4: Menu UI — step-size stepper, persisted via @AppStorage.
// Phase 4b (this revision): switch MenuBarExtra from .menu to .window
//          style so the panel stays open during clicks. Bigger primary-
//          color text throughout, no more faded grey menu styling.
//          All diagnostics inline (no submenu hiding things), so you can
//          watch them update live without re-opening the menu.
//

import SwiftUI

import Combine

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    /// Re-broadcasts changes from nested ObservableObjects (LoginItem) so
    /// SwiftUI rebuilds the menu when their state changes.
    private var nestedCancellables = Set<AnyCancellable>()

    static let defaultStepSize = 3

    // --- Phase 1 fields ---
    @Published var hidStatus: String = "Starting…"
    @Published var detentCount: Int = 0

    /// Drives the menu-bar icon's "activity flash". Toggled on each detent
    /// so the icon flickers (inverted) while the knob is turning, then a
    /// short timer returns it to normal once motion stops. This replaced
    /// the old "R1 / L1" text label, which changed width and shoved the
    /// surrounding menu-bar items around.
    @Published var isFlashing: Bool = false

    private let listener = HIDListener()
    private var refreshTimer: Timer?
    private var flashOffTimer: Timer?

    // --- Phase 2 fields ---
    let spotify = SpotifyClient()
    @Published var spotifyStatus: String = "Not authenticated"
    @Published var lastKEFVolume: String = "—"
    @Published var isWorking: Bool = false
    private var currentDeviceName: String?

    // --- Phase 3 fields ---
    private(set) var volumeController: VolumeController!
    @Published var volumeStatus: String = "idle"
    @Published var lastWrittenDescription: String = "—"

    // --- Phase 5c fields ---
    let loginItem = LoginItem()

    init() {
        setvbuf(stdout, nil, _IOLBF, 0)

        // --- Phase 5a: system-volume independence ---
        // Suppress the VOL20's Volume Up/Down events at macOS's
        // IOHIDEventSystem layer so Mac speaker volume stays put while
        // our lower-level IOHIDManager listener still catches them.
        // Idempotent if already applied (e.g. from a previous launch).
        HIDRemap.suppressVolumeKeys()

        volumeController = VolumeController(spotify: spotify)
        volumeController.onUpdate = { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                self.volumeStatus = update.status
                if let desc = update.lastWrittenDescription {
                    self.lastWrittenDescription = desc
                }
            }
        }

        let saved = UserDefaults.standard.integer(forKey: "vol20.stepSize")
        if saved >= 1 && saved <= 10 {
            volumeController.setStepSize(saved)
        }

        listener.onDetent = { [weak self] direction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordDetent(direction)
                self.volumeController.recordDetent(direction)
            }
        }

        listener.start()
        hidStatus = listener.status

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                            repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hidStatus  = self.listener.status
                self.detentCount = self.listener.detentCount
            }
        }

        spotifyStatus = spotify.hasStoredCredentials
            ? "Signed in (token on disk)"
            : "Not authenticated"

        // Re-emit objectWillChange when LoginItem updates, so the
        // Toggle and the "Login item:" diagnostic line refresh.
        loginItem.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &nestedCancellables)

        if spotify.hasStoredCredentials {
            Task { @MainActor in
                await self.initialVolumeRead()
            }
        }
    }

    private func initialVolumeRead() async {
        do {
            if let state = try await spotify.getPlaybackState(),
               let v = state.device.volume_percent {
                currentDeviceName = state.device.name
                lastWrittenDescription = "\(state.device.name)  •  \(v)%"
                lastKEFVolume = "\(state.device.name): \(v)%"
            } else {
                let devices = try await spotify.listDevices()
                if let d = devices.first(where: { $0.name == SpotifyConfig.preferredDeviceName }) ?? devices.first {
                    let vol = d.volume_percent.map(String.init) ?? "n/a"
                    currentDeviceName = d.name
                    lastWrittenDescription = "\(d.name) (idle)  •  \(vol)%"
                    lastKEFVolume = "\(d.name) (idle): \(vol)%"
                }
            }
        } catch {
            lastKEFVolume = "Error: \(error.localizedDescription)"
        }
    }

    private func recordDetent(_ direction: HIDListener.Direction) {
        // Flip the flash on every detent. During a turn this flickers the
        // icon between normal and inverted (subtle activity feedback);
        // direction no longer matters for the indicator, so we ignore it.
        // The icon's bounds never change, so the menu bar doesn't shift.
        isFlashing.toggle()
        armFlashOffTimer()
    }

    private func armFlashOffTimer() {
        flashOffTimer?.invalidate()
        flashOffTimer = Timer.scheduledTimer(withTimeInterval: 0.25,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isFlashing = false
            }
        }
    }

    func authenticateWithSpotify() {
        guard !isWorking else { return }
        isWorking = true
        spotifyStatus = "Opening browser…"
        Task {
            do {
                try await spotify.authenticate()
                spotifyStatus = "Signed in. Token saved on disk."
                await initialVolumeRead()
            } catch {
                spotifyStatus = "Auth failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func readKEFVolume() {
        guard !isWorking else { return }
        isWorking = true
        lastKEFVolume = "…"
        Task {
            do {
                if let playback = try await spotify.getPlaybackState() {
                    currentDeviceName = playback.device.name
                    let vol = playback.device.volume_percent.map(String.init) ?? "n/a"
                    lastKEFVolume = "\(playback.device.name): \(vol)%"
                } else {
                    let devices = try await spotify.listDevices()
                    let preferred = devices.first {
                        $0.name == SpotifyConfig.preferredDeviceName
                    } ?? devices.first
                    if let d = preferred {
                        currentDeviceName = d.name
                        let vol = d.volume_percent.map(String.init) ?? "n/a"
                        lastKEFVolume = "\(d.name) (idle): \(vol)%"
                    } else {
                        lastKEFVolume = "No devices found"
                    }
                }
            } catch {
                lastKEFVolume = "Error: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func signOutOfSpotify() {
        spotify.logOut()
        spotifyStatus = "Signed out. Refresh token removed from disk."
        lastKEFVolume = "—"
        lastWrittenDescription = "—"
    }
}

// MARK: - MenuPanel (the .window-style panel that stays open)

private struct MenuPanel: View {

    @ObservedObject var state: AppState

    /// Persists per-detent step size across app launches.
    @AppStorage("vol20.stepSize") private var stepSize: Int = AppState.defaultStepSize

    /// UI simplification 2026-08-16 (TLM-directed): the everyday view is
    /// minimal; the full troubleshooting screen (the one used in the
    /// 2026-08-07/08-16 debugging sessions) is preserved VERBATIM below,
    /// one click away behind this toggle. Persisted so it stays put
    /// across launches.
    @AppStorage("vol20.showDiagnostics") private var showDiagnostics: Bool = false

    /// The target device is chosen in Spotify (Connect picker), so the
    /// everyday view shows just the volume percentage — no device name.
    /// Descriptions look like "Active device → 54%" or
    /// "LSX II-Office (idle)  •  52%"; keep only the part after the
    /// arrow/bullet.
    private var volumePercentOnly: String {
        let d = state.lastWrittenDescription
        guard d != "—" else { return "—" }
        let parts = d.components(separatedBy: CharacterSet(charactersIn: "→•"))
        return (parts.last ?? d).trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // --- Title row ---
            HStack {
                Image(systemName: "dial.medium")
                    .font(.title2)
                Text("Vol20 v2.5")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            Divider()

            // --- Volume — percent only; the device is Spotify's business ---
            // Transient status ("applying +3%…", "queued: +2", errors) sits
            // on the SAME line, right-aligned, so the pane never changes
            // shape while the knob turns (TLM-directed, 2026-08-16).
            if state.spotify.hasStoredCredentials {
                HStack(alignment: .firstTextBaseline) {
                    Text("Volume: \(volumePercentOnly)")
                        .font(.title3)
                        .fontWeight(.medium)
                        .monospacedDigit()
                    Spacer()
                    if state.volumeStatus != "idle",
                       !state.volumeStatus.hasPrefix("Active device"),
                       !state.volumeStatus.contains("→") {
                        // Transient/apply/error states only — successful
                        // writes are already reflected in the percent.
                        Text(state.volumeStatus)
                            .font(.body)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Not signed in to Spotify")
                    .font(.title3)
                    .fontWeight(.medium)
                Button("🔑 Authenticate with Spotify") {
                    state.authenticateWithSpotify()
                }
                .disabled(state.isWorking)
                .controlSize(.large)
            }

            Divider()

            // --- Step-size control ---
            Stepper(value: $stepSize, in: 1...10) {
                Text("Step size: \(stepSize)% per detent")
                    .font(.body)
            }
            .onChange(of: stepSize) { _, newValue in
                state.volumeController.setStepSize(newValue)
            }

            // --- Phase 5c: login item toggle ---
            // Binds directly to the OS's SMAppService state — no
            // UserDefaults intermediary needed. Toggle off when you're
            // testing other software and don't want Vol20 auto-starting.
            Toggle("Launch at login",
                   isOn: Binding(
                    get: { state.loginItem.isEnabled },
                    set: { state.loginItem.set($0) }
                   ))
                .font(.body)
            if let err = state.loginItem.lastError {
                Text("Login-item error: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button("Re-auth") { state.authenticateWithSpotify() }
                    .disabled(state.isWorking)
                if state.spotify.hasStoredCredentials {
                    Button("Sign out") { state.signOutOfSpotify() }
                        .disabled(state.isWorking)
                }
            }

            Divider()

            // --- Diagnostics: hidden by default (2026-08-16) --------------
            // This is the FULL troubleshooting screen from v2.0.x, kept
            // verbatim for future debugging (see TROUBLESHOOTING.md for the
            // sessions that relied on it). Toggle to reveal.
            Toggle("Show diagnostics", isOn: $showDiagnostics)
                .font(.body)

            if showDiagnostics {
                Text("Diagnostics")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    LabeledLine("HID",       state.hidStatus)
                    LabeledLine("Detents",   "\(state.detentCount)")
                    LabeledLine("Volume",    state.volumeStatus)
                    LabeledLine("Spotify",   state.spotifyStatus)
                    LabeledLine("KEF read",  state.lastKEFVolume)
                    LabeledLine("Login item", state.loginItem.rawStatusDescription)
                }

                Button("🔍 Read KEF") { state.readKEFVolume() }
                    .disabled(state.isWorking || !state.spotify.hasStoredCredentials)
            }

            Divider()

            Button("Quit Vol20 v2.5") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 380)
        .font(.body)                  // ensure default text isn't shrunk
        .foregroundStyle(.primary)    // and isn't dimmed to "menu grey"
    }
}

/// One labeled diagnostic line. Both the label and value are body-size
/// primary-color — readable without leaning in.
private struct LabeledLine: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .fontWeight(.medium)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .fontWeight(.regular)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.body)
        .foregroundStyle(.primary)
    }
}

// MARK: - AppDelegate
//
// Tiny NSApplicationDelegate whose only job is to catch the graceful
// quit notification so we can undo the hidutil remapping before exit.
// Without this, the remap persists for the rest of the login session
// — fine while Vol20v2 is installed, surprising if the user has
// uninstalled the app and now wonders why F11/F12 don't move volume.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        HIDRemap.restoreVolumeKeys()
    }
}

// MARK: - App

@main
struct Vol20v2App: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(state: state)
        } label: {
            // Single fixed-width icon that "lights up" on knob activity.
            //
            // NOTE: the menu bar renders this label as a TEMPLATE image —
            // it keeps only the glyph's alpha/shape and discards color and
            // background fills. So a black/white color invert won't show.
            // Instead we flash the glyph's SHAPE: the FILLED dial variant
            // on activity, the OUTLINE variant at rest. Same symbol, same
            // bounds (fill variants share their outline's metrics), so the
            // surrounding menu-bar items never shift.
            Image(systemName: state.isFlashing ? "dial.medium.fill"
                                               : "dial.medium")
        }
        // .window style → panel stays open during clicks. We control the
        // layout ourselves (padding, fonts, colors). Click outside or
        // re-click the menu-bar icon to dismiss.
        .menuBarExtraStyle(.window)
    }
}
