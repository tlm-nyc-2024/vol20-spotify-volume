# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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

[2.0.0]: https://github.com/tlm-nyc-2024/vol20-spotify-volume/releases/tag/v2.0.0
