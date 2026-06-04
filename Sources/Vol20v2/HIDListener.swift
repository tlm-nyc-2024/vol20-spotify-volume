//
// HIDListener.swift — event-driven listener for the Fosi VOL20 knob.
//
// Phase 1 goal: when you turn the knob, print one line per detent showing
// the raw HID page/usage/value, so we can both (a) confirm we're seeing
// events at ~0% idle CPU and (b) capture the EXACT usage codes the VOL20
// emits.
//
// Why this file is written in a "1990s-C-flavored Swift" style:
//   IOKit is a C framework. Most of its API names (IOHIDManager*) and
//   constants (kIOHIDVendorIDKey) come straight from C. Swift can call them,
//   but the registration callback in particular has to be a C function
//   pointer — it cannot capture Swift variables. The standard idiom is to
//   pass `self` as a `void*` "context" pointer, then inside the callback
//   turn that pointer back into a Swift object. Comments below mark that.
//

import Foundation
import IOKit
import IOKit.hid
import os

// MARK: - Public API

/// Listens for input events from the VOL20 and reports each detent.
/// Owns one IOHIDManager for the lifetime of the app.
final class HIDListener {

    /// The VOL20 presents two different identities depending on bus:
    ///   - Bluetooth-LE: VendorID 0x07d7 (ProductID not meaningful).
    ///   - Wired USB:    VendorID 0x0e55 (Speed Dragon HID chip) +
    ///                   ProductID 0x110e. We pin the product ID because
    ///                   0x0e55 is a generic vendor shared by many cheap
    ///                   peripherals — vendor-only would over-match.
    /// We match BOTH so the same knob works wired or over Bluetooth.
    private static let bleVendorID  = 0x07d7
    private static let usbVendorID  = 0x0e55
    private static let usbProductID = 0x110e

    /// Set after start() succeeds; otherwise nil (e.g. permission denied).
    private var manager: IOHIDManager?

    /// Buffer that IOKit fills with raw report bytes on each event.
    /// Allocated once, reused for every callback. Must outlive the
    /// registration; we keep it as a long-lived class property.
    private let reportBufferCapacity: Int = 64
    private lazy var reportBuffer: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferCapacity)
        p.initialize(repeating: 0, count: reportBufferCapacity)
        return p
    }()

    /// Total detents seen since start. Exposed for the menu UI's "events seen"
    /// counter so you can sanity-check the listener is firing.
    private(set) var detentCount: Int = 0

    /// Most recent status string, suitable for showing in the menu.
    private(set) var status: String = "Not started"

    /// Direction labels passed to UI for the burst indicator.
    enum Direction { case up, down, other(String) }

    /// Called once per recognized detent on the main thread. The UI uses
    /// this to drive a live "R3 / L1" indicator next to the menu icon.
    /// Set this before calling start() (or any time after — it's just a
    /// closure property).
    var onDetent: ((Direction) -> Void)?

    // -------------------------------------------------------------------
    // start()
    //
    // 1) Check / request Input Monitoring permission.
    // 2) Create the IOHIDManager and tell it which device to match.
    // 3) Register the C callback that fires per input event.
    // 4) Schedule on the main run loop, then Open the manager.
    //
    // Returns silently if the permission isn't granted yet — the user has
    // to enable it in System Settings and relaunch. `status` will explain.
    // -------------------------------------------------------------------
    func start() {

        // --- 1. Permission gate ---------------------------------------
        // IOHIDCheckAccess returns one of:
        //   kIOHIDAccessTypeGranted  — already allowed; proceed.
        //   kIOHIDAccessTypeDenied   — user said no; nothing we can do.
        //   kIOHIDAccessTypeUnknown  — never asked yet; we should request.
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            log("Input Monitoring: granted")

        case kIOHIDAccessTypeDenied:
            status = "Input Monitoring DENIED. Enable Vol20v2 in System Settings → Privacy & Security → Input Monitoring, then quit and relaunch."
            log(status)
            return

        case kIOHIDAccessTypeUnknown:
            log("Input Monitoring: not yet decided — requesting…")
            // This may show a system prompt and may return false on first
            // call regardless of the user's eventual choice. After the
            // user grants it, they'll need to relaunch the app.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            status = "Permission requested. Grant it in System Settings → Privacy & Security → Input Monitoring, then quit and relaunch."
            log(status)
            return

        default:
            log("Input Monitoring: unexpected access state \(access.rawValue) — trying anyway")
        }

        // --- 2. Create the manager ------------------------------------
        let m = IOHIDManagerCreate(kCFAllocatorDefault,
                                   IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m

        // --- 2b. Matching dictionaries --------------------------------
        // Match the VOL20 on EITHER bus: its Bluetooth identity
        // (vendor 0x07d7) or its wired-USB identity (vendor 0x0e55 +
        // product 0x110e). SetDeviceMatchingMultiple takes an array of
        // dicts and matches a device if it satisfies ANY of them.
        // Matching wider (e.g. nil to catch everything) causes
        // IOHIDManagerOpen to return kIOReturnUnsupported because some
        // Apple-internal SPI/SPMI/SPU transports refuse user-space open,
        // so we stay specific.
        let matchBLE: [String: Any] = [
            kIOHIDVendorIDKey: NSNumber(value: Int32(Self.bleVendorID))
        ]
        let matchUSB: [String: Any] = [
            kIOHIDVendorIDKey:  NSNumber(value: Int32(Self.usbVendorID)),
            kIOHIDProductIDKey: NSNumber(value: Int32(Self.usbProductID))
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, [matchBLE, matchUSB] as CFArray)

        // --- 2c. Device-match / device-removal diagnostic callbacks ---
        // These fire when a device matching our dictionary appears or
        // disappears. We log it so we can SEE whether matching itself is
        // working (separate from whether input events flow). Same C-
        // pointer trick as the input callback below.
        let selfPtrDM = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            guard let ctx = ctx else { return }
            let listener = Unmanaged<HIDListener>.fromOpaque(ctx).takeUnretainedValue()
            listener.deviceMatched(dev)
        }, selfPtrDM)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            guard let ctx = ctx else { return }
            let listener = Unmanaged<HIDListener>.fromOpaque(ctx).takeUnretainedValue()
            listener.deviceRemoved(dev)
        }, selfPtrDM)

        // --- 3. (Removed) Manager-level input-value callback ----------
        // We previously registered IOHIDManagerRegisterInputValueCallback
        // here AND a per-device value callback inside deviceMatched().
        // For this BLE consumer device, BOTH fire for every detent,
        // which made each physical click count as two. We keep only the
        // per-device callback (set up in deviceMatched).

        // --- 4. Schedule on the run loop ------------------------------
        // The callback can only fire when something is pumping the run
        // loop. Our SwiftUI app naturally runs the main loop forever, so
        // attaching there is the simplest correct choice.
        IOHIDManagerScheduleWithRunLoop(m,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)

        // --- 5. Open the manager (no seize this round) ----------------
        // Earlier experiment with kIOHIDOptionsTypeSeizeDevice confirmed
        // the system stopped getting events (system volume didn't move)
        // but ALSO no events reached our callbacks. Events vanished.
        // So this round we open non-exclusive — system volume may move
        // again, but the report callback should fire on the same events.
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            status = String(format: "IOHIDManagerOpen failed: 0x%08X", result)
            log(status)
            return
        }

        status = "Listening for ALL HID devices (filter: name contains VOL20)"
        log(status)
        log("Turn the knob now — each detent should print one line.")
    }

    // -------------------------------------------------------------------
    // deviceMatched / deviceRemoved — diagnostic callbacks.
    //
    // The IOHIDDeviceGetProperty calls pull human-readable info out of
    // the kernel object. We dump vendor, product, name, usage page, and
    // top-level usage so we can confirm we're looking at the VOL20.
    // -------------------------------------------------------------------
    private func deviceMatched(_ device: IOHIDDevice) {
        let name      = stringProperty(device, kIOHIDProductKey)        ?? "?"
        let vendor    = intProperty(device, kIOHIDVendorIDKey)          ?? -1
        let product   = intProperty(device, kIOHIDProductIDKey)         ?? -1
        let usagePage = intProperty(device, kIOHIDPrimaryUsagePageKey)  ?? -1
        let usage     = intProperty(device, kIOHIDPrimaryUsageKey)      ?? -1
        let transport = stringProperty(device, kIOHIDTransportKey)      ?? "?"
        log(String(format: "[HID] Matched device: %@  vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X transport=%@",
                   name, vendor, product, usagePage, usage, transport))

        // --- (Re-)arm system-volume suppression ------------------------
        // macOS wipes all hidutil remaps on logout/reboot, and a
        // forget-and-re-pair gives the knob a fresh RegistryID with no
        // mapping attached. The app's launch-time suppressVolumeKeys()
        // call is therefore a no-op whenever the knob isn't already
        // present at launch — exactly the reboot case. Re-applying it
        // here, on every match, guarantees the remap is bound to the
        // device that just appeared. It's idempotent, so firing it on
        // each reconnect is safe. suppressVolumeKeys() covers both the
        // BLE and USB identities, so it doesn't matter which bus this
        // match arrived on.
        HIDRemap.suppressVolumeKeys()
        log("[HID] Re-applied volume-key suppression for \(name)")

        // --- Open the device explicitly --------------------------------
        // Manager-level open should propagate to matched devices, but in
        // practice for BLE consumer HID we've observed that values never
        // arrive unless we open the specific device too.
        //
        // We do NOT seize: seize was tested in Phase 5a and turned out
        // not to suppress system volume anyway (macOS's volume handler
        // reads from IOHIDEventSystem, a layer above raw IOHIDDevice).
        // The suppression is done via hidutil/HIDRemap instead.
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        log(String(format: "[HID] IOHIDDeviceOpen → 0x%08X", openResult))

        // --- Per-device input value callback (authoritative path) -----
        // This is the ONE path that reports direction. The raw-report
        // callback below is purely diagnostic — it must NOT call
        // onDetent, or we'd double-count and confuse the UI.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            let listener = Unmanaged<HIDListener>
                .fromOpaque(ctx)
                .takeUnretainedValue()
            listener.handle(value: value)
        }, selfPtr)
        IOHIDDeviceScheduleWithRunLoop(device,
                                       CFRunLoopGetMain(),
                                       CFRunLoopMode.commonModes.rawValue)
        log("[HID] Per-device input-value callback registered for \(name)")

        // --- Input REPORT callback (raw bytes, lowest level) -----------
        // This is the bypass for the BLE Consumer-Control delivery
        // problem: even when value callbacks never fire, the raw report
        // callback often still does. We get the unparsed bytes the
        // device sent — typically [usage code low, usage code high] or
        // a bitfield — and figure out the meaning from observation.
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            CFIndex(reportBufferCapacity),
            { ctx, _, _, _, reportID, report, reportLength in
                guard let ctx = ctx else { return }
                let listener = Unmanaged<HIDListener>
                    .fromOpaque(ctx)
                    .takeUnretainedValue()
                listener.handleReport(reportID: reportID,
                                      bytes: report,
                                      length: reportLength)
            },
            selfPtr
        )
        log("[HID] Per-device input-REPORT callback registered for \(name)")
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let name = stringProperty(device, kIOHIDProductKey) ?? "?"
        log("[HID] Device removed: \(name)")
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    // -------------------------------------------------------------------
    // handleReport — raw input report (PURELY DIAGNOSTIC now).
    //
    // The input-value callback is the authoritative path for direction
    // and UI updates. This method only logs raw bytes when something
    // *non-idle* arrives, so we can see the VOL20's wire-level encoding
    // without spamming the log with all-zero "release" reports (which
    // the device sends roughly every 200 ms while idle).
    //
    // Importantly: this method does NOT increment detentCount or call
    // onDetent. Doing so would double-count vs. the value callback.
    // -------------------------------------------------------------------
    private func handleReport(reportID: UInt32,
                              bytes: UnsafeMutablePointer<UInt8>?,
                              length: CFIndex) {
        guard let bytes else { return }

        // Skip the constant background "all zero" idle reports entirely.
        let isRelease = (0..<Int(length)).allSatisfy { bytes[$0] == 0 }
        guard !isRelease else { return }

        var hex = ""
        for i in 0..<Int(length) {
            hex += String(format: "%02X ", bytes[i])
        }
        hex = hex.trimmingCharacters(in: .whitespaces)

        log(String(format: "[REPORT] id=%u len=%ld bytes=[%@]",
                   reportID, length, hex))
    }

    // -------------------------------------------------------------------
    // handle(value:)
    //
    // Fired once per HID input report. We pull out:
    //   - usage page (which category of control fired)
    //   - usage code (which specific control)
    //   - integer value (1 = pressed/activated, 0 = released)
    // and print a single human-readable line per "press" event.
    // -------------------------------------------------------------------
    private func handle(value: IOHIDValue) {
        let element  = IOHIDValueGetElement(value)
        let page     = IOHIDElementGetUsagePage(element)
        let usage    = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        // The VOL20 emits a press (value=1) and a release (value=0) per
        // detent. Logging only the press gives us one line per detent.
        guard intValue != 0 else { return }

        // Map the usage to a friendly name when we recognize it.
        // (These are the "expected" Consumer-page codes from the HID
        // Usage Tables; Phase 1's whole point is to confirm them live.)
        let label: String
        switch (page, usage) {
        case (0x0C, 0xE9): label = "Volume ↑"
        case (0x0C, 0xEA): label = "Volume ↓"
        case (0x0C, 0xCD): label = "Play / Pause"
        case (0x0C, 0xB5): label = "Next Track"
        case (0x0C, 0xB6): label = "Previous Track"
        case (0x0C, 0xE2): label = "Mute"
        default:           label = "Unknown"
        }

        detentCount += 1
        let line = String(format: "[HID] page=0x%02X  usage=0x%02X  value=%d  →  %@   (#%d)",
                          page, usage, intValue, label, detentCount)
        log(line)

        // Notify the UI. The callback fires on whichever thread IOKit
        // delivered the event on — that's the main run loop because of
        // IOHIDManagerScheduleWithRunLoop(CFRunLoopGetMain(), ...).
        let direction: Direction
        switch (page, usage) {
        case (0x0C, 0xE9): direction = .up
        case (0x0C, 0xEA): direction = .down
        default:           direction = .other(String(format: "0x%X", usage))
        }
        onDetent?(direction)
    }

    // -------------------------------------------------------------------
    // Internal logging — sends every line to two destinations:
    //
    //   1. Apple's unified logger (os.Logger). These messages appear in
    //      Console.app and can be streamed live from any other shell
    //      with `log stream --predicate 'subsystem == "com.tlmattson.vol20v2"'`.
    //      This is what we use in Phase 1 because the app is launched
    //      via `open Vol20v2.app` (no attached terminal).
    //
    //   2. stdout via print(), for the case where you launch the binary
    //      directly from a terminal — the same messages show up there.
    //
    // The os.Logger subsystem string matches our bundle identifier so
    // the predicate filter is trivial to remember.
    // -------------------------------------------------------------------
    private static let logger = Logger(subsystem: "com.tlmattson.vol20v2",
                                       category: "HID")

    private func log(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        print(message)
    }
}
