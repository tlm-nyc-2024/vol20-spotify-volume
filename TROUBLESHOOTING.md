# Troubleshooting — Vol20 v2

Field-tested fixes, newest first. Diagnostic commands assume the USB identity
(`VendorID 0x0e55, ProductID 0x110e`); substitute `{"VendorID":0x07d7}` for
Bluetooth.

---

## Knob does nothing (app shows 0 detents) — 2026-08-07 incident

**Symptoms observed:** App running, Spotify auth fine ("KEF read" works in the
menu), but Detents stays at 0. Depending on sub-cause, the Mac *system* volume
may or may not move when the knob turns.

Two independent root causes were found the same day. Check both, in order.

### Cause 1: Karabiner-Elements is seizing the knob

Karabiner (installed on this Mac 2026-07-28) grabs **every keyboard-class HID
device** by default — and the VOL20's volume interface is keyboard-class
(usagePage 0x1, usage 0x6). When grabbed:

- The app's diagnostics show `IOHIDManagerOpen failed: 0xE00002C5`
  (kIOReturnExclusiveAccess).
- The Mac system volume DOES move (Karabiner re-posts the events through its
  virtual keyboard, which bypasses this app's per-device `hidutil`
  suppression).

**Check:**

```sh
grep -i fosi /var/log/karabiner/core_service.log | tail -5
# BAD:  "... hid queue value monitor is started (grabbed)."
# GOOD: only "caps lock is found on Fosi Audio VOL20" (no "grabbed" line)
```

**Fix (applied 2026-08-07, permanent):** `~/.config/karabiner/karabiner.json`
now carries `ignore: true` device entries for both knob identities
(USB vendor 3669/product 4366 = 0x0e55/0x110e, and BLE vendor 2007 = 0x07d7)
in the selected profile. Karabiner hot-reloads the file on save. Pre-change
backup: `~/.config/karabiner/karabiner.json.bak-2026-08-07`.

Do NOT remove those entries. They only exclude the knob; the Lenovo-keyboard
device entry and the ⇧⌘B Drafts-capture complex modification are untouched.

### Cause 2: stale Input Monitoring (TCC) grant

A macOS point update (15.7.3 → 15.7.7 between June and August) left the app's
Input Monitoring grant in a half-dead state: `IOHIDCheckAccess` returned
*granted*, `IOHIDDeviceOpen` returned success — but **no input values or
reports were ever delivered**. The same events flowed fine to a freshly
granted client, which is what isolated it.

- System volume does NOT move (the app's `hidutil` suppression is active) and
  the app sees nothing → looks completely dead.

**Fix:**

```sh
tccutil reset ListenEvent com.tlmattson.vol20v2
```

then relaunch the app, re-enable it in System Settings → Privacy & Security →
Input Monitoring, and relaunch once more.

**Corollary — every rebuild needs a re-grant.** The bundle is ad-hoc signed
(`codesign --sign -`), so each `build-app.sh` run produces a new signing
identity and macOS silently invalidates the existing grant (app logs
`Input Monitoring DENIED`). After any rebuild: `tccutil reset` as above,
relaunch, re-grant, relaunch. Toggling the old Settings entry is NOT enough —
reset it so the new binary re-registers.

### Diagnostic toolkit used

```sh
# Live app log:
log stream --predicate 'subsystem == "com.tlmattson.vol20v2"' --style compact

# Is the knob enumerated? (3 HID entries expected on USB)
hidutil list | grep -i fosi

# Is the per-device volume-key suppression mapping present?
hidutil property --matching '{"VendorID":0x0e55,"ProductID":0x110e}' --get UserKeyMapping

# Independent HID monitor (standalone IOHIDManager client; needs its own
# Input Monitoring grant — run from Terminal and approve the prompt).
# Source pattern: match both knob identities, manager-level
# IOHIDManagerRegisterInputValueCallback, open kIOHIDOptionsTypeNone.
# A healthy knob prints EVENT page=0xC usage=0xE9/0xEA value=1/0 per detent.
```

**Debugging order that worked:** confirm enumeration (`hidutil list`) →
check Karabiner grab (`core_service.log`) → confirm events reach macOS at all
(clear the suppression mapping; does system volume move?) → prove delivery to
an independent freshly-granted client → conclude stale TCC.

A false lead worth recording: the per-device
`IOHIDDeviceRegisterInputValueCallback` path was suspected broken by the OS
update (manager-level worked in the standalone monitor). Wrong — once TCC was
genuinely re-granted, the shipped per-device path worked unchanged. The v2.0.1
code needed no modification; an interim code change was reverted.

---

## Knob works but Mac system volume also moves

The `hidutil` suppression didn't land (wiped on reboot/re-pair, or applied
mid-churn). v2.0.1's verify-and-retry usually self-heals within seconds; if
not, unplug/replug the knob (the app re-applies on every device match).

## Bluetooth quirks after Mac sleep

Known macOS issue, not the app: after sleep the BLE pairing can wedge and need
a forget/re-pair. **Wired USB is the recommended transport** — it survives
sleep/wake seamlessly (see README).
