// XliteBattery: menu bar battery level and settings of the Pulsar Xlite v4 Wireless behind
// its 1K dongle (3710:5402); other mice are out of scope. The icon is shown only while the
// dongle is plugged in and the mouse answers (it sleeps after its idle timer).
//
// Protocol: Fusion2/Sonix 64-byte feature reports (no report ID) on the dongle's vendor
// interface, as in github.com/packerlschupfer/pulsar-mouse-linux
// (drivers/xlite_v4_wireless.py, x2a.py) and github.com/D3m0nZOnFire/mousectl
// (drivers/pulsar_x3.py); both agree on every register used here.
// Never send other vendors' frames to it: the X2 V2 17-byte protocol wedged the dongle
// until it was replugged (2026-11-17).
//
// CLI for checks: --once (battery), --settings (dump), --set key=value (write + verify).

import Cocoa
import IOKit.hid

// MARK: - Language

/// UI language: Russian or English. The "language" default holds "system", "ru" or "en";
/// "system" means Russian when the system's first preferred language is Russian, else English.
enum Lang: String { case ru, en }

var lang: Lang = resolveLang()

func resolveLang() -> Lang {
    switch UserDefaults.standard.string(forKey: "language") ?? "system" {
    case "ru": return .ru
    case "en": return .en
    default: return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? .ru : .en
    }
}

/// Inline translation: the Russian and English text side by side at each use.
func L(_ ru: String, _ en: String) -> String { lang == .ru ? ru : en }

let dongleVID = 0x3710
let donglePID = 0x5402
let mouseNames: [Int: String] = [0x3401: "Pulsar Xlite v4", 0x3409: "Pulsar X3", 0x3410: "Pulsar X3"]

enum HIDError: Error {
    case noDongle, writeFailed, asleep, noAnswer, verifyFailed, badValue

    var text: String {
        switch self {
        case .noDongle: return L("Донгл не найден", "Dongle not found")
        case .writeFailed: return L("Ошибка записи в донгл", "Write to the dongle failed")
        case .asleep: return L("Мышь спит", "Mouse is asleep")
        case .noAnswer: return L("Мышь не ответила", "Mouse did not answer")
        case .verifyFailed: return L("Мышь не приняла значение", "Mouse rejected the value")
        case .badValue: return L("Недопустимое значение", "Invalid value")
        }
    }
}

// MARK: - Dongle protocol

final class Dongle {
    let device: IOHIDDevice
    private var lastWrite: Date?

    init(_ device: IOHIDDevice) { self.device = device }

    /// [0] 0 on requests, [1] category, [2] register (bit 7 = read), [3] sub/length,
    /// [6] profile (0 = global), [7...] payload, [62..63] u16le sum of bytes 0..61.
    static func frame(_ cat: UInt8, _ reg: UInt8, _ sub: UInt8, profile: UInt8 = 0, payload: [UInt8] = []) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 64)
        f[1] = cat; f[2] = reg; f[3] = sub; f[6] = profile
        for (i, b) in payload.enumerated() { f[7 + i] = b }
        let sum = f[0..<62].reduce(0) { $0 + Int($1) } & 0xFFFF
        f[62] = UInt8(sum & 0xFF); f[63] = UInt8(sum >> 8)
        return f
    }

    private func send(_ f: [UInt8]) -> Bool {
        var f = f
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &f, f.count) == kIOReturnSuccess
    }

    private func get() -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 64)
        var len: CFIndex = 64
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &buf, &len) == kIOReturnSuccess,
              len >= 8 else { return nil }
        return Array(buf[0..<len])
    }

    /// One request, then poll the shared reply register until our own answer.
    /// Status byte: 0x02 waiting for the mouse, 0x05 no radio link, 0x01 answer.
    /// A second request while one is pending gets dropped, so resend only when the
    /// register shows another request's finished answer (the dongle lost ours).
    func transact(_ req: [UInt8], timeout: TimeInterval = 3) -> Result<[UInt8], HIDError> {
        // A request right after a write's answer waits for the dongle's next slot
        // (~230 ms); 30 ms of gap avoids that (upstream _WRITE_GAP).
        if let lw = lastWrite {
            let wait = 0.03 - Date().timeIntervalSince(lw)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            lastWrite = nil
        }
        var sent = false
        for _ in 0..<5 {  // macOS SetReport fails transiently (0xE0005000)
            if send(req) { sent = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard sent else { return .failure(.writeFailed) }
        let deadline = Date().addingTimeInterval(timeout)
        var stale = 0, resends = 0
        while Date() < deadline {
            if let r = get() {
                if r[1] == req[1] && r[2] == req[2] && (req[6] == 0 || r[6] == req[6]) {
                    stale = 0
                    if r[0] == 0x01 {
                        if req[2] & 0x80 == 0 { lastWrite = Date() }
                        return .success(r)
                    }
                    if r[0] == 0x05 { return .failure(.asleep) }
                } else if r[0] == 0x01 {
                    stale += 1
                    if stale >= 10 && resends < 5 {
                        _ = send(req)
                        resends += 1
                        stale = 0
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.015)
        }
        return .failure(.noAnswer)
    }

    func read(_ cat: UInt8, _ reg: UInt8, _ sub: UInt8, profile: UInt8 = 0, payload: [UInt8] = [],
              timeout: TimeInterval = 3) -> Result<[UInt8], HIDError> {
        transact(Dongle.frame(cat, reg | 0x80, sub, profile: profile, payload: payload), timeout: timeout)
    }

    func write(_ cat: UInt8, _ reg: UInt8, _ sub: UInt8, profile: UInt8 = 0, _ payload: [UInt8]) -> Result<[UInt8], HIDError> {
        transact(Dongle.frame(cat, reg, sub, profile: profile, payload: payload))
    }
}

/// USB interface number of a HID device (bInterfaceNumber of its IOUSBHostInterface parent).
func interfaceNumber(_ dev: IOHIDDevice) -> Int? {
    let service = IOHIDDeviceGetService(dev)
    let v = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    return (v as? NSNumber)?.intValue
}

/// Opens the dongle afresh (a fresh open gets past most dropped requests) and runs `body`
/// on the vendor interface instance that accepts requests.
func withDongle<T>(_ body: (Dongle, String) -> Result<T, HIDError>) -> Result<T, HIDError> {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [
        kIOHIDVendorIDKey: dongleVID,
        kIOHIDProductIDKey: donglePID,
        kIOHIDPrimaryUsagePageKey: 0xFFFF,
    ]
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
        return .failure(.noDongle)
    }
    var lastError = HIDError.noAnswer  // dongle present but no instance answered: retryable
    // Interfaces 2 and 3 carry identical vendor descriptors; only 3 takes requests
    // (Fusion talks to it too). Requests to 2 fail and made reads on 3 flaky (2026-11-17).
    let config = devices.filter { interfaceNumber($0) == 3 }
    for dev in (config.isEmpty ? Array(devices) : Array(config)) {
        let d = Dongle(dev)
        // Paired mouse ID, answered by the dongle itself (no radio round trip).
        guard case .success(let info) = d.read(0x01, 0x04, 0x04, timeout: 0.5) else { continue }
        let pid = Int(info[8]) | Int(info[9]) << 8
        let name = mouseNames[pid] ?? String(format: "Pulsar 3710:%04x", pid)
        let result = body(d, name)
        if case .failure(let e) = result { lastError = e; continue }
        return result
    }
    return .failure(lastError)
}

func retrying<T>(_ attempts: Int, _ op: () -> Result<T, HIDError>) -> Result<T, HIDError> {
    var result = op()
    for _ in 1..<max(attempts, 2) where attempts > 1 {
        switch result {
        case .success, .failure(.noDongle), .failure(.badValue), .failure(.verifyFailed): return result
        default: break
        }
        Thread.sleep(forTimeInterval: 0.5)
        result = op()
    }
    return result
}

// MARK: - Mouse state

struct Battery {
    var name: String
    var percent: Int
    var charging: Bool
}

func readBattery(_ d: Dongle, _ name: String) -> Result<Battery, HIDError> {
    switch d.read(0x08, 0x01, 0x01) {
    case .failure(let e): return .failure(e)
    case .success(let r):
        var charging = false
        if case .success(let c) = d.read(0x08, 0x03, 0x01) { charging = c[6] != 0 }
        return .success(Battery(name: name, percent: min(Int(r[6]), 100), charging: charging))
    }
}

struct Settings {
    var profile: UInt8 = 1
    var dpi: [UInt8] = []        // [active stage, stage count, (index, x lo, x hi, y lo, y hi) × 6]
    var lodTenths: UInt8 = 0     // mode 02 + tenths of a mm
    var polling: UInt8 = 0       // 01 = 125 Hz … 08 = 1000 Hz
    var angleSnap = false
    var ripple = false
    var motionSync = false
    var debounce: UInt8 = 0      // ms
    var sleepSeconds = 0
    var lowPower: UInt8 = 0      // %
    var ledEffect: UInt8 = 0     // 0 off, 1 steady, 2 breathe (side LED, per profile)
    var ledBrightness: UInt8 = 0 // 0-255
    var ledSpeed: UInt8 = 0      // breathe speed 0-100
    var stageColor: [UInt8] = [255, 255, 255]  // LED colour of DPI stage 1 (RGB)

    var activeStage: Int { Int(dpi[0]) }
    var stageCount: Int { Int(dpi[1]) }
    var activeDPI: Int {
        let o = 2 + (activeStage - 1) * 5
        return Int(dpi[o + 1]) | Int(dpi[o + 2]) << 8
    }
}

let pollingRates: [(hz: Int, code: UInt8)] = [(125, 0x01), (250, 0x02), (500, 0x04), (1000, 0x08)]

func readSettings(_ d: Dongle) -> Result<Settings, HIDError> {
    var s = Settings()
    func r(_ cat: UInt8, _ reg: UInt8, _ sub: UInt8, _ profile: UInt8 = 0, _ payload: [UInt8] = []) throws -> [UInt8] {
        switch d.read(cat, reg, sub, profile: profile, payload: payload) {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
    do {
        let p = try r(0x02, 0x06, 0x01)
        s.profile = p[7] != 0 ? p[7] : p[6]
        guard (1...6).contains(s.profile) else { return .failure(.badValue) }
        s.dpi = Array(try r(0x05, 0x04, 0x15, s.profile)[7..<39])
        guard (1...6).contains(s.stageCount), (1...s.stageCount).contains(s.activeStage) else { return .failure(.badValue) }
        let lod = try r(0x07, 0x02, 0x03, s.profile)
        s.lodTenths = lod[7] == 0x02 ? lod[8] : 10   // other modes: treat as 1 mm, like upstream
        s.polling = try r(0x01, 0x09, 0x02)[7]
        s.angleSnap = try r(0x07, 0x04, 0x02)[7] != 0
        s.ripple = try r(0x07, 0x03, 0x02)[7] != 0
        s.motionSync = try r(0x07, 0x05, 0x02)[7] != 0
        s.debounce = try r(0x04, 0x03, 0x03)[7]
        let sl = try r(0x08, 0x05, 0x03)
        s.sleepSeconds = Int(sl[7]) | Int(sl[8]) << 8
        s.lowPower = try r(0x08, 0x08, 0x02)[7]
        // LED registers (x2a.py): brightness 03/03/03 [01] -> [8]; effect block 03/04/0f [01]
        // -> effect [8], breathe speed [11]; stage colour 05/05/05 [stage] -> RGB [8..10].
        s.ledBrightness = try r(0x03, 0x03, 0x03, s.profile, [0x01])[8]
        let fx = try r(0x03, 0x04, 0x0F, s.profile, [0x01])
        s.ledEffect = fx[8]
        s.ledSpeed = fx[11]
        s.stageColor = Array(try r(0x05, 0x05, 0x05, s.profile, [0x01])[8..<11])
        return .success(s)
    } catch let e as HIDError {
        return .failure(e)
    } catch {
        return .failure(.noAnswer)
    }
}

enum Change {
    case dpi(Int), polling(UInt8), lod(UInt8), angleSnap(Bool), ripple(Bool), motionSync(Bool)
    case debounce(UInt8), sleep(Int), lowPower(UInt8)
    case ledEffect(UInt8), ledBrightness(UInt8), stageColor([UInt8])
}

/// Charge as LED colour: hue 0° (red) at <= 10 % to 120° (green) at >= 80 %, in 5 % steps
/// so the mouse is not rewritten for every 1 % drop.
func batteryColor(_ percent: Int) -> [UInt8] {
    let p = Double(percent / 5 * 5)
    let t = min(max((p - 10) / 70, 0), 1)
    // Red -> yellow -> green at full saturation and value.
    let r = t < 0.5 ? 1.0 : (1 - t) * 2
    let g = t < 0.5 ? t * 2 : 1.0
    return [UInt8(r * 255), UInt8(g * 255), 0]
}

func writeStageColor(_ d: Dongle, _ s: Settings, _ rgb: [UInt8]) -> Result<[UInt8], HIDError> {
    // The LED shows the active DPI stage's colour, so paint every stage.
    var last: Result<[UInt8], HIDError> = .failure(.badValue)
    for stage in 1...max(s.stageCount, 1) {
        last = d.write(0x05, 0x05, 0x05, profile: s.profile, [UInt8(stage)] + rgb)
        if case .failure = last { return last }
    }
    return last
}

/// Writes one setting, reads all settings back and checks the value stuck.
func apply(_ change: Change, _ d: Dongle) -> Result<Settings, HIDError> {
    guard case .success(var s) = readSettings(d) else { return .failure(.noAnswer) }
    let w: Result<[UInt8], HIDError>
    switch change {
    case .dpi(let v):
        guard (100...32000).contains(v) else { return .failure(.badValue) }
        let o = 2 + (s.activeStage - 1) * 5
        let lo = UInt8(v & 0xFF), hi = UInt8(v >> 8)
        s.dpi[o..<o + 5] = [UInt8(s.activeStage), lo, hi, lo, hi]
        w = d.write(0x05, 0x04, 0x21, profile: s.profile, Array(s.dpi[0..<2 + s.stageCount * 5]))
    case .polling(let c): w = d.write(0x01, 0x09, 0x02, [c])
    case .lod(let t):
        guard [7, 10, 20].contains(t) else { return .failure(.badValue) }
        w = d.write(0x07, 0x02, 0x03, profile: s.profile, [0x02, t])
    case .angleSnap(let b): w = d.write(0x07, 0x04, 0x02, [b ? 1 : 0])
    case .ripple(let b): w = d.write(0x07, 0x03, 0x02, [b ? 1 : 0])
    case .motionSync(let b): w = d.write(0x07, 0x05, 0x02, [b ? 1 : 0])
    case .debounce(let ms):
        guard ms <= 20 else { return .failure(.badValue) }
        w = d.write(0x04, 0x03, 0x03, [ms])
    case .sleep(let sec):
        guard (30...900).contains(sec) else { return .failure(.badValue) }
        w = d.write(0x08, 0x05, 0x03, [UInt8(sec & 0xFF), UInt8(sec >> 8)])
    case .lowPower(let p):
        guard p <= 100 else { return .failure(.badValue) }
        w = d.write(0x08, 0x08, 0x02, [p])
    case .ledEffect(let e):
        guard e <= 2 else { return .failure(.badValue) }
        let speed = e == 2 && s.ledSpeed == 0 ? 50 : s.ledSpeed   // 0 = no visible breathing
        w = d.write(0x03, 0x04, 0x0F, profile: s.profile, [0x01, e, 0x00, 0x00, speed])
        if e != 0 && s.ledBrightness == 0, case .success = w {   // brightness 0 = lit but dark
            if case .failure(let err) = d.write(0x03, 0x03, 0x03, profile: s.profile, [0x01, 128]) { return .failure(err) }
        }
    case .ledBrightness(let b): w = d.write(0x03, 0x03, 0x03, profile: s.profile, [0x01, b])
    case .stageColor(let rgb): w = writeStageColor(d, s, rgb)
    }
    if case .failure(let e) = w { return .failure(e) }
    guard case .success(let back) = readSettings(d) else { return .failure(.noAnswer) }
    let ok: Bool
    switch change {
    case .dpi(let v): ok = back.activeDPI == v
    case .polling(let c): ok = back.polling == c
    case .lod(let t): ok = back.lodTenths == t
    case .angleSnap(let b): ok = back.angleSnap == b
    case .ripple(let b): ok = back.ripple == b
    case .motionSync(let b): ok = back.motionSync == b
    case .debounce(let ms): ok = back.debounce == ms
    case .sleep(let sec): ok = back.sleepSeconds == sec
    case .lowPower(let p): ok = back.lowPower == p
    case .ledEffect(let e): ok = back.ledEffect == e
    case .ledBrightness(let b): ok = back.ledBrightness == b
    case .stageColor(let rgb): ok = back.stageColor == rgb
    }
    return ok ? .success(back) : .failure(.verifyFailed)
}

// MARK: - Formatting

func fmtSleep(_ s: Int) -> String {
    let sec = L("с", "s"), min = L("мин", "min")
    return s < 60 ? "\(s) \(sec)" : (s % 60 == 0 ? "\(s / 60) \(min)" : "\(s / 60) \(min) \(s % 60) \(sec)")
}
func fmtLOD(_ t: UInt8) -> String {
    let mm = L("мм", "mm")
    if t % 10 == 0 { return "\(t / 10) \(mm)" }
    let v = String(format: "%.1f", Double(t) / 10)
    return (lang == .ru ? v.replacingOccurrences(of: ".", with: ",") : v) + " " + mm
}
func fmtPolling(_ c: UInt8) -> String { pollingRates.first { $0.code == c }.map { "\($0.hz) \(L("Гц", "Hz"))" } ?? String(format: "0x%02x", c) }

// MARK: - CLI

func cli() -> Never {
    let args = CommandLine.arguments
    if args.contains("--once") {
        switch retrying(4, { withDongle(readBattery) }) {
        case .success(let b): print("\(b.name): \(b.percent)%\(b.charging ? " (charging)" : "")"); exit(0)
        case .failure(let e): print("error: \(e.text)"); exit(1)
        }
    }
    if args.contains("--settings") {
        switch retrying(4, { withDongle { d, _ in readSettings(d) } }) {
        case .success(let s):
            print("profile \(s.profile), DPI \(s.activeDPI) (stage \(s.activeStage)/\(s.stageCount)), polling \(fmtPolling(s.polling)), LOD \(fmtLOD(s.lodTenths))")
            print("motion sync \(s.motionSync), angle snap \(s.angleSnap), ripple \(s.ripple), debounce \(s.debounce) ms, sleep \(s.sleepSeconds) s, low power \(s.lowPower)%")
            print("led effect \(s.ledEffect), brightness \(s.ledBrightness), speed \(s.ledSpeed), stage colour \(s.stageColor)")
            exit(0)
        case .failure(let e): print("error: \(e.text)"); exit(1)
        }
    }
    if let i = args.firstIndex(of: "--set"), i + 1 < args.count {
        let kv = args[i + 1].split(separator: "=").map(String.init)
        guard kv.count == 2, let n = Int(kv[1]) else { print("usage: --set key=int"); exit(2) }
        let change: Change
        switch kv[0] {
        case "dpi": change = .dpi(n)
        case "polling": guard let c = pollingRates.first(where: { $0.hz == n })?.code else { exit(2) }; change = .polling(c)
        case "lod": change = .lod(UInt8(n))            // tenths of a mm: 7, 10, 20
        case "angle_snap": change = .angleSnap(n != 0)
        case "ripple": change = .ripple(n != 0)
        case "motion_sync": change = .motionSync(n != 0)
        case "debounce": change = .debounce(UInt8(n))
        case "sleep": change = .sleep(n)               // seconds
        case "low_power": change = .lowPower(UInt8(n))
        case "led": change = .ledEffect(UInt8(n))      // 0 off, 1 steady, 2 breathe
        case "led_brightness": change = .ledBrightness(UInt8(n))
        case "led_charge": change = .stageColor(n < 0 ? [255, 255, 255] : batteryColor(n))  // colour for n %, -1 = white
        default: print("unknown key"); exit(2)
        }
        switch retrying(3, { withDongle { d, _ in apply(change, d) } }) {
        case .success: print("ok"); exit(0)
        case .failure(let e): print("error: \(e.text)"); exit(1)
        }
    }
    print("usage: XliteBattery [--once | --settings | --set key=value]"); exit(2)
}

// MARK: - Menu bar app

/// Visibility decisions go to ~/Library/Logs/XliteBattery.log (one line each).
func logLine(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XliteBattery.log")
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let queue = DispatchQueue(label: "xlite-battery.hid")
    private var watcher: IOHIDManager?
    private var battery: Battery?
    private var settings: Settings?
    private var updatedAt: Date?
    private var pollTimer: Timer?
    private var busy = false
    private var failures = 0
    private var events: IOHIDManager?
    private var eventBuffer = [UInt8](repeating: 0, count: 64)
    private var signal: Int?
    private var signalAt = Date.distantPast
    private weak var signalItem: NSMenuItem?
    private var menuOpenAt: Date?
    private var signalWhileOpen = 0
    private var ledState: Settings?   // last known settings, kept for the wake-time brightness write
    private var lastProbe = Date.distantPast
    private var visible = false { didSet { item.isVisible = visible } }

    static let visibleInterval: TimeInterval = 60   // notices sleep within a minute
    static let fallbackInterval: TimeInterval = 300 // probe while hidden, in case no motion event arrives
    static let motionThrottle: TimeInterval = 15    // hidden: at most one probe per this, triggered by pointer motion

    func applicationDidFinishLaunching(_ note: Notification) {
        // One instance only: a copy started by hand (open, Finder) survives build.sh's launchd
        // restart, keeps old code and talks to the dongle too. The newest one wins.
        if let id = Bundle.main.bundleIdentifier {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: id)
            where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                logLine("terminating older instance pid \(other.processIdentifier)")
                other.terminate()
            }
        }
        UserDefaults.standard.register(defaults: ["colorByCharge": true])
        item.button?.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: L("Мышь", "Mouse"))
        item.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        visible = false

        watchDongle()
        // Any pointer activity may be the Pulsar waking up. Mouse events need no
        // Accessibility permission (only key events do); the trackpad triggers this
        // too, hence the throttle.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            guard let self, !self.visible, Date().timeIntervalSince(self.lastProbe) > Self.motionThrottle else { return }
            self.lastProbe = Date()
            // The link comes back ~0.1 s after the first movement; give it a moment.
            logLine("pointer motion while hidden -> probe")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh(quick: true) }
        }
        refresh(quick: false)
    }

    /// Plug/unplug notifications for the dongle's vendor interface (no Input Monitoring
    /// needed, unlike its pointer interface).
    private func watchDongle() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: dongleVID, kIOHIDProductIDKey: donglePID, kIOHIDPrimaryUsagePageKey: 0xFFFF]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, _ in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { me.refresh(quick: false) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            logLine("dongle removed")
            me.hide()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        watcher = m
        listenEvents()
    }

    /// The dongle pushes report ID 5 on interface 1 (System Control collection, usage
    /// 01/80, which opens without Input Monitoring): `05 0d <signal %>` every second,
    /// `05 08 <01 up | 02 down>` when the mouse link comes and goes (sleep included),
    /// `05 07 <charging> <percent>` when the mouse volunteers its battery
    /// (xlite_v4_wireless.py parse_hidraw_event).
    private func listenEvents() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: dongleVID, kIOHIDProductIDKey: donglePID,
                                    kIOHIDPrimaryUsagePageKey: 0x01, kIOHIDPrimaryUsageKey: 0x80]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(m, { ctx, _, _, _, reportID, report, length in
            guard reportID == 5, length >= 3 else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            let r = Array(UnsafeBufferPointer(start: report, count: length))
            me.handleEvent(r)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)  // common: also fires while the menu is open (event tracking mode)
        events = m
        openEvents()
    }

    /// Reading this interface needs Input Monitoring (kIOReturnNotPermitted otherwise):
    /// ask once, then keep retrying until it is granted in System Settings.
    private func openEvents() {
        guard let m = events else { return }
        let rc = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if rc == kIOReturnSuccess { logLine("event interface open"); return }
        logLine(String(format: "event interface open failed 0x%08x, access %d, requesting Input Monitoring", rc, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue))
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.openEvents() }
    }

    private func handleEvent(_ r: [UInt8]) {
        // The buffer may or may not start with the report ID; normalise to [kind, value...].
        let b = r.first == 5 ? Array(r.dropFirst()) : r
        guard b.count >= 2 else { return }
        switch b[0] {
        case 0x0D:
            signal = Int(b[1])
            signalAt = Date()
            signalItem?.title = signalText()
            if menuOpenAt != nil { signalWhileOpen += 1 }
        case 0x08:
            if b[1] == 0x02 {
                if visible { logLine("link down (mouse asleep or out of range)") }
                failures = 0
                hide()
            } else if b[1] == 0x01 {
                logLine("link up")
                // The mouse wakes with LED brightness 128: put ours back first, before the
                // full re-read, so the bright flash is as short as the radio allows.
                if let s = settings ?? ledState, s.ledEffect != 0,
                   let wb = UserDefaults.standard.object(forKey: "ledBrightness") as? Int {
                    ledState = s
                    queue.async {
                        let t0 = Date()
                        let r = retrying(3) { withDongle { d, _ in d.write(0x03, 0x03, 0x03, profile: s.profile, [0x01, UInt8(wb)]) } }
                        if case .success = r { logLine(String(format: "led brightness set on wake in %.2f s", Date().timeIntervalSince(t0))) }
                    }
                }
                settings = nil   // re-read everything (brightness resets during sleep)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh(quick: false) }
            }
        case 0x07 where b.count >= 3:
            if var bat = battery {
                bat.charging = b[1] != 0
                bat.percent = min(Int(b[2]), 100)
                battery = bat
                render()
            }
        default:
            break
        }
    }

    private func signalText() -> String {
        guard let s = signal, Date().timeIntervalSince(signalAt) < 5 else { return L("Связь: нет данных", "Signal: no data") }
        return L("Связь", "Signal") + ": \(s) %"
    }

    private func hide() {
        visible = false
        schedule(Self.fallbackInterval)
    }

    private func refresh(quick: Bool) {
        guard !busy else { return }
        busy = true
        lastProbe = Date()
        // Re-read after a wake too: the mouse forgets LED brightness while asleep.
        let wantSettings = settings == nil || !visible
        let wantBrightness = UserDefaults.standard.object(forKey: "ledBrightness") as? Int
        let cached = settings
        let colorByCharge = UserDefaults.standard.bool(forKey: "colorByCharge")
        queue.async {
            // Visible: full retries before deciding it fell asleep. Hidden: one cheap try.
            let result = retrying(quick ? 2 : 4) {
                withDongle { d, name -> Result<(Battery, Settings?), HIDError> in
                    readBattery(d, name).map { b in
                        var s: Settings? = nil
                        if wantSettings, case .success(let v) = readSettings(d) { s = v }
                        // LED brightness is not kept across sleep (comes back as 128): restore ours.
                        if let wb = wantBrightness, var cur = s ?? cached, cur.ledEffect != 0, Int(cur.ledBrightness) != wb,
                           case .success = d.write(0x03, 0x03, 0x03, profile: cur.profile, [0x01, UInt8(wb)]) {
                            logLine("led brightness restored \(cur.ledBrightness) -> \(wb)")
                            cur.ledBrightness = UInt8(wb)
                            s = cur
                        }
                        // Battery as LED colour, written only when the colour bucket changes.
                        if colorByCharge, var cur = s ?? cached, cur.ledEffect != 0 {
                            let c = batteryColor(b.percent)
                            if c != cur.stageColor, case .success = writeStageColor(d, cur, c) {
                                logLine("led colour \(c) for \(b.percent)%")
                                cur.stageColor = c
                                s = cur
                            }
                        }
                        return (b, s)
                    }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let (b, s)):
                    self.failures = 0
                    self.battery = b
                    if let s { self.settings = s; self.ledState = s }
                    self.updatedAt = Date()
                    self.render()
                    if !self.visible { logLine("shown: \(b.percent)% (\(quick ? "probe" : "poll"))") }
                    self.visible = true
                    self.schedule(Self.visibleInterval)
                case .failure(let e):
                    // Another program on the dongle (Fusion in Chrome) can steal a reply, so one
                    // failed poll is not proof of sleep: hide on the second in a row (~1 min later).
                    self.failures += 1
                    if self.visible && self.failures < 2 {
                        logLine("poll failed once: \(e.text)")
                        self.schedule(Self.visibleInterval)
                    } else {
                        if self.visible { logLine("hidden: \(e.text) (\(quick ? "probe" : "poll"))") }
                        self.hide()
                    }
                }
            }
        }
    }

    private func schedule(_ interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh(quick: !(self?.visible ?? false))
        }
    }

    private func render() {
        guard let b = battery, let button = item.button else { return }
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0)]
        if b.percent <= 15 && !b.charging { attrs[.foregroundColor] = NSColor.systemRed }
        button.attributedTitle = NSAttributedString(string: " \(b.percent)%" + (b.charging ? "⚡" : ""), attributes: attrs)
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpenAt = Date()
        signalWhileOpen = 0
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let at = menuOpenAt else { return }
        menuOpenAt = nil
        // Diagnostics for "signal does not tick while the menu is open": log only the anomaly.
        if Date().timeIntervalSince(at) > 3 && signalWhileOpen == 0 {
            logLine(String(format: "menu open %.1f s, signal updates %d, item %@", Date().timeIntervalSince(at), signalWhileOpen, signalItem == nil ? "gone" : "alive"))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        if let b = battery {
            menu.addItem(disabled("\(b.name) — \(b.percent)%\(b.charging ? L(", заряжается", ", charging") : "")"))
        }
        let sig = disabled(signalText())
        signalItem = sig   // updated live from the 1 s signal reports while the menu is open
        menu.addItem(sig)
        if let at = updatedAt { menu.addItem(disabled(L("Обновлено в", "Updated at") + " \(fmt.string(from: at))")) }
        menu.addItem(.separator())
        if busy {
            menu.addItem(disabled(L("Применяю…", "Applying…")))
        } else if let s = settings {
            addChoice(menu, "DPI", "\(s.activeDPI)" + (s.stageCount > 1 ? " (\(L("ступень", "stage")) \(s.activeStage))" : ""),
                      [400, 800, 1000, 1200, 1600, 2000, 2400, 3200, 6400].map { ("\($0)", $0 == s.activeDPI, Change.dpi($0)) },
                      extra: NSMenuItem(title: L("Другое…", "Custom…"), action: #selector(customDPI), keyEquivalent: ""))
            addChoice(menu, L("Частота опроса", "Polling rate"), fmtPolling(s.polling),
                      pollingRates.map { ("\($0.hz) \(L("Гц", "Hz"))", $0.code == s.polling, Change.polling($0.code)) })
            addChoice(menu, L("Высота отрыва", "Lift-off distance"), fmtLOD(s.lodTenths),
                      ([7, 10, 20] as [UInt8]).map { (fmtLOD($0), $0 == s.lodTenths, Change.lod($0)) })
            addToggle(menu, "Motion sync", s.motionSync, Change.motionSync(!s.motionSync))
            addToggle(menu, "Angle snapping", s.angleSnap, Change.angleSnap(!s.angleSnap))
            addToggle(menu, "Ripple control", s.ripple, Change.ripple(!s.ripple))
            addChoice(menu, "Debounce", "\(s.debounce) \(L("мс", "ms"))",
                      ([0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20] as [UInt8]).map { ("\($0) \(L("мс", "ms"))", $0 == s.debounce, Change.debounce($0)) })
            addChoice(menu, L("Сон через", "Sleep after"), fmtSleep(s.sleepSeconds),
                      [30, 60, 120, 180, 300, 600, 900].map { (fmtSleep($0), $0 == s.sleepSeconds, Change.sleep($0)) })
            addChoice(menu, L("Экономия при", "Power saving at"), "\(s.lowPower) %",
                      ([5, 10, 15, 20, 25, 30] as [UInt8]).map { ("\($0) %", $0 == s.lowPower, Change.lowPower($0)) })
            menu.addItem(.separator())
            let fxNames = [L("Выключена", "Off"), L("Горит", "Steady"), L("Дышит", "Breathing")]
            addChoice(menu, L("Подсветка", "LED"), fxNames[min(Int(s.ledEffect), 2)],
                      (0..<3).map { (fxNames[$0], UInt8($0) == s.ledEffect, Change.ledEffect(UInt8($0))) })
            if s.ledEffect != 0 {
                let levels: [(String, UInt8)] = [(L("Минимум", "Minimum"), 1), ("1 %", 3), ("3 %", 8), ("5 %", 13), ("10 %", 26), ("25 %", 64), ("50 %", 128), ("100 %", 255)]
                let cur = levels.first { $0.1 == s.ledBrightness }?.0 ?? "\(Int(s.ledBrightness) * 100 / 255) %"
                addChoice(menu, L("Яркость", "Brightness"), cur, levels.map { ($0.0, $0.1 == s.ledBrightness, Change.ledBrightness($0.1)) })
                let t = NSMenuItem(title: L("Цвет по заряду", "Colour shows charge"), action: #selector(toggleColorByCharge), keyEquivalent: "")
                t.target = self
                t.state = UserDefaults.standard.bool(forKey: "colorByCharge") ? .on : .off
                menu.addItem(t)
            }
        } else {
            menu.addItem(disabled(L("Настройки не прочитаны", "Settings not read")))
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: L("Обновить", "Refresh"), action: #selector(refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let langMenu = NSMenu()
        for (code, title) in [("system", L("Как в системе", "System")), ("en", "English"), ("ru", "Русский")] {
            let i = NSMenuItem(title: title, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = code
            i.state = (UserDefaults.standard.string(forKey: "language") ?? "system") == code ? .on : .off
            langMenu.addItem(i)
        }
        let langItem = NSMenuItem(title: L("Язык", "Language"), action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(NSMenuItem(title: L("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private final class ChangeBox: NSObject {
        let change: Change
        init(_ c: Change) { change = c }
    }

    private func addChoice(_ menu: NSMenu, _ title: String, _ current: String,
                           _ options: [(String, Bool, Change)], extra: NSMenuItem? = nil) {
        let parent = NSMenuItem(title: "\(title): \(current)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, on, change) in options {
            let i = NSMenuItem(title: label, action: #selector(pick(_:)), keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.representedObject = ChangeBox(change)
            sub.addItem(i)
        }
        if let extra {
            sub.addItem(.separator())
            extra.target = self
            sub.addItem(extra)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ change: Change) {
        let i = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = ChangeBox(change)
        menu.addItem(i)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ChangeBox else { return }
        run(box.change)
    }

    @objc private func customDPI() {
        let alert = NSAlert()
        alert.messageText = "DPI"
        alert.informativeText = L("От 100 до 32000, шаг 10", "100 to 32000, step 10")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = settings.map { "\($0.activeDPI)" } ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("Применить", "Apply"))
        alert.addButton(withTitle: L("Отмена", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (100...32000).contains(v) else { return }
        run(.dpi(v / 10 * 10))
    }

    @objc private func toggleColorByCharge() {
        let on = !UserDefaults.standard.bool(forKey: "colorByCharge")
        UserDefaults.standard.set(on, forKey: "colorByCharge")
        // Off: back to the stock white. On: the next refresh paints the charge colour.
        if on { refresh(quick: false) } else { run(.stageColor([255, 255, 255])) }
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "language")
        lang = resolveLang()
        item.button?.image?.accessibilityDescription = L("Мышь", "Mouse")
        // The menu is rebuilt on every open (menuNeedsUpdate), so nothing else to redraw.
    }

    @objc private func refreshAll() {
        settings = nil
        refresh(quick: false)
    }

    private func run(_ change: Change) {
        guard !busy else { return }
        if case .ledBrightness(let b) = change { UserDefaults.standard.set(Int(b), forKey: "ledBrightness") }
        busy = true
        queue.async {
            let result = retrying(3) { withDongle { d, _ in apply(change, d) } }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let s):
                    self.settings = s
                    self.refresh(quick: false)   // e.g. LED just turned on: paint the charge colour
                case .failure(let e):
                    let a = NSAlert()
                    a.messageText = L("Не удалось применить настройку", "Could not apply the setting")
                    a.informativeText = e.text + L(". Пошевели мышью и попробуй ещё раз.", ". Move the mouse and try again.")
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                    self.settings = nil   // re-read on the next refresh, the state is unknown
                    self.refresh(quick: false)
                }
            }
        }
    }
}

if CommandLine.arguments.count > 1 { cli() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
