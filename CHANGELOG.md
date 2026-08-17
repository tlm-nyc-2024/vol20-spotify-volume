# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [2.5.0] — 2026-08-16

### Changed
- **The knob now follows the ACTIVE Spotify Connect device** instead of
  pinning "LSX II-Office" (TLM-directed). `VolumeController.resolveDeviceID()`
  returns nil, so volume PUTs omit `device_id` and Spotify targets whatever
  is playing — Mac speakers, AirPlay, the KEF, anything. Trade-off: with
  nothing actively playing anywhere, writes fail (shown as an error status)
  instead of silently adjusting an idle speaker. Old pinning code preserved
  in git history (v2.0.1).
- **Simplified everyday menu panel** (TLM-directed): Volume percent only
  (no device name — the Spotify Connect picker owns targeting), step size,
  Launch at login, Re-auth/Sign out, Quit. Transient status ("applying
  +3%…", errors) renders right-aligned ON the Volume line so the panel
  never changes shape while the knob turns. The full v2.0.x diagnostics
  screen (HID status, Detents, KEF read, Read KEF button, etc.) is
  preserved verbatim behind a persisted **"Show diagnostics"** toggle.
  Menu-bar icon per-detent flash unchanged.
- Version strings bumped to 2.5 (Info.plist + UI).

### Docs
- **TROUBLESHOOTING.md added** after a 2026-08-07 field incident (knob dead,
  0 detents). Two independent environmental causes: Karabiner-Elements
  seizing the knob's keyboard-class HID interface (fixed with permanent
  `ignore` entries in the Karabiner config), and a stale Input Monitoring
  (TCC) grant after a macOS 15.7.x point update — plus the corollary that
  every ad-hoc rebuild invalidates the existing grant. No code changes;
  the v2.0.1 code was and remains correct.

### Known issue (hardware/macOS, not the app)
- **Bluetooth bond does not survive USB use.** Observed 2026-08-16: after
  the knob has been used over USB, unplugging it does NOT auto-reconnect
  over BT; the Mac must Forget the device and re-pair from scratch each
  time (the knob appears to drop its side of the stored bond). Workaround:
  leave it wired (USB always takes priority when plugged). TLM researching
  separately.

## [2.0.1] — 2026-06-04

### Fixed
- **System-volume decoupling now self-heals after a reconnect.** Previously,
  after a wake-from-sleep + Bluetooth re-pair, the knob could end up
  controlling *both* the Spotify device and the Mac's system volume in sync.
  Cause: `hidutil --set` reports success even when no live device received
  the suppression mapping, so a one-shot apply during the re-pair churn could
  land on a device instance that was already gone. The app now reads the
  mapping back to verify it actually took, and re-applies (on a short retry
  cadence) until it's confirmed active.

### Docs
- README now documents how the knob really behaves day-to-day: **wired (USB)
  is the recommended setup** — it survives Mac sleep/wake seamlessly — while
  Bluetooth works but can need a forget/re-pair after the Mac sleeps (a macOS
  Bluetooth quirk, not the app).

## [2.0.0] — 2026-06-04

First public release. Volume control only.

### Added
- Native macOS menu-bar app (SwiftUI `MenuBarExtra`) that maps the Fosi
  VOL20 knob to the active **Spotify Connect** device's volume.
- Event-driven HID listener (`IOHIDManager`) — ~0% CPU while idle.
- Works on **both** transports: Bluetooth-LE and wired USB (the knob
  presents a different vendor/product ID on each; the app matches both).
- Read-before-write volume control with debounce, so fast spins make a
  single Spotify Web API call and the volume never drifts.
- System-volume decoupling via `hidutil` — turning the knob moves only the
  Spotify device, not the Mac's own speaker volume. Re-armed automatically
  on every (re)connect so it survives reboots, sleep, and re-pairing.
- OAuth **Authorization Code + PKCE** (no client secret); tokens stored
  locally outside the repo.
- Optional device pinning by name, and **Launch at login** via
  `SMAppService`.
- Subtle menu-bar icon flash on each detent as live activity feedback.

### Notes
- Requires macOS 14+ and Spotify Premium.
- This release is **volume only**; play/pause and next-track from the knob's
  button are planned for v3.

[2.0.1]: https://github.com/tlm-nyc-2024/vol20-spotify-volume/releases/tag/v2.0.1
[2.0.0]: https://github.com/tlm-nyc-2024/vol20-spotify-volume/releases/tag/v2.0.0
