# Vol20 v2 — Fosi VOL20 knob → Spotify Connect volume

A small native **macOS menu-bar app** (Swift) that turns a **Fosi VOL20**
Bluetooth volume knob into a remote volume control for whatever **Spotify
Connect** device is currently playing (e.g. a KEF wireless speaker).

It's **event-driven**: it listens for the knob's HID volume events via IOKit
and calls the Spotify Web API only when you turn the knob, so it costs
~0% CPU while idle.

> **Scope:** this release (v2.0) is **volume only**. Play/pause and
> next-track from the knob's button are planned for a future version.

---

## How it works

- **HID listener** — an `IOHIDManager` matches the VOL20 and fires on each
  detent (turn of the knob). The knob is recognized on **either** transport:
  Bluetooth-LE *or* a wired USB connection (it presents a different
  vendor/product ID on each, and the app matches both).
- **Volume control** — on each turn it reads the target device's *actual*
  current volume from Spotify, applies the accumulated delta, and writes it
  back (read-before-write, so it never drifts). Turns are debounced so a fast
  spin results in one API call.
- **System-volume decoupling** — macOS normally routes the knob's volume keys
  to the Mac's own speaker volume. The app uses `hidutil` to remap those keys
  to "no action" for the VOL20 specifically, so turning the knob moves *only*
  the Spotify device — your Mac's system volume stays put. (Other devices'
  volume keys are unaffected.)
- **Menu bar** — a `MenuBarExtra` shows status, the active device, and a
  subtle icon "flash" on each detent so you get live feedback that events are
  being received. It can run at login.

---

## Requirements

- **macOS 14 (Sonoma) or newer.**
- **Spotify Premium** (the Web API only allows volume control on Premium).
- A **Spotify Developer app** (free) to get a client ID — see Setup.
- The **Input Monitoring** permission (granted once, on first run).
- Swift toolchain (Xcode or the Command Line Tools) to build.

---

## Setup

1. **Create a Spotify app** at the
   [Spotify Developer Dashboard](https://developer.spotify.com/dashboard):
   - Add the redirect URI `http://127.0.0.1:8888/callback`
     (Spotify rejects `localhost`; use the loopback IP).
   - This app uses **Authorization Code + PKCE**, so **no client secret** is
     needed.
   - Required scopes: `user-modify-playback-state`,
     `user-read-playback-state`.

2. **Add your client ID.** Put your app's client ID in
   `Sources/Vol20v2/SpotifyConfig.swift`. (A client ID is *not* a secret for
   PKCE public clients — it ships inside every distributed copy of an app —
   so it's safe to commit.)

3. **Build the app bundle:**
   ```sh
   ./Scripts/build-app.sh
   ```
   This runs `swift build` and wraps the binary in `Vol20v2.app`
   (ad-hoc signed, which is fine for personal use).

4. **Launch it** and grant **Input Monitoring** when prompted
   (System Settings → Privacy & Security → Input Monitoring). Then use the
   menu to sign in to Spotify; tokens are stored locally on your machine,
   outside this repo.

---

## Usage

- Turn the knob → the active Spotify Connect device's volume changes.
- The menu-bar dial icon flashes on each detent as activity feedback.
- Optionally pin a specific device by name, and enable **Launch at login**
  from the menu.
- **Wired tip:** if Bluetooth ever gets flaky, plug the knob in over USB —
  the app recognizes it on the wire too, with no reconnection headaches.

---

## Roadmap

- **v3** — play/pause and next-track from the knob's button (macOS routes
  those media keys to the system media app today; capturing them cleanly is
  a separate, messier problem, deliberately deferred).

---

## A note on Spotify's terms

This is a personal, non-commercial tool. Spotify's Developer Terms prohibit
commercial use of the Web API, so this project is and will remain free and
open source.

---

## License

[MIT](LICENSE) © 2026 Todd Mattson
