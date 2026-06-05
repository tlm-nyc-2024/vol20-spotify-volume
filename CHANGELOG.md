# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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
