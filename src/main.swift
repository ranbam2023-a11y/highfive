//
//  HighFive — do something with a five-finger trackpad tap (or pinch).
//
//  A tiny background agent (~80 KB). It reads raw trackpad contacts from Apple's
//  private MultitouchSupport framework and, when it sees five fingers land and
//  lift quickly, does one of three things:
//
//    raycast   open Raycast's launcher through its own raycast:// link
//    app       launch or activate any app
//    shortcut  press a keyboard shortcut (needs Accessibility)
//
//  Why a URL and not a keystroke for Raycast: on macOS 26+ WindowServer drops
//  synthetic modifier-bearing key events before they reach Carbon hotkey
//  matchers, so CGEventPost cannot trigger Raycast from an ad-hoc-signed helper.
//  Raycast's own deeplink has no such gate — and needs no permission at all.
//
//  Configure:   HighFive --action shortcut --shortcut "cmd+shift+4"
//               HighFive --show
//  Verbose log: touch ~/.highfive-debug, then restart the agent.
//

import Foundation
import AppKit
import Darwin

// MARK: - Private MultitouchSupport bindings (resolved with dlopen/dlsym)

typealias MTDeviceRef     = UnsafeMutableRawPointer
typealias MTFrameCallback = @convention(c) (MTDeviceRef?, UnsafeMutablePointer<MTTouch>?, Int, Double, Int) -> Void
typealias MTRegFn         = @convention(c) (MTDeviceRef, MTFrameCallback) -> Void
typealias MTCreateListFn  = @convention(c) () -> UnsafeMutableRawPointer?
typealias MTStartFn       = @convention(c) (MTDeviceRef, Int32) -> Int32

let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

// MARK: - Logging

let logURL    = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/HighFive.log")
let debugFlag = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".highfive-debug")
let logLock   = NSLock()
let verbose   = FileManager.default.fileExists(atPath: debugFlag.path)

func log(_ s: String, verboseOnly: Bool = false) {
    if verboseOnly && !verbose { return }
    logLock.lock(); defer { logLock.unlock() }
    let line = "\(Date()) \(s)\n"
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Config

struct Config: Codable {
    /// "raycast", "app" or "shortcut".
    var action = "raycast"

    // raycast
    var url = "raycast://"
    var bundleID = "com.raycast.macos"
    var app = "Raycast"
    var launchIfNeeded = true

    // app
    var appName = "Safari"

    // shortcut
    var shortcut = "cmd+space"

    // detection
    var fingers = 5
    var gesture = "both"            // "tap", "pinch" or "both"
    var tapMaxDuration = 0.50       // seconds from peak contact to all-up
    var tapMaxDrift = 0.06          // centroid movement, 0…1 of trackpad
    var pinchMaxDuration = 0.90
    var pinchShrink = 0.70          // spread must fall below this fraction of peak
    var cooldown = 0.60
}

let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/highfive/config.json")

func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: configURL),
          let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
    return config
}

func saveConfig(_ config: Config) {
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config) {
        try? data.write(to: configURL, options: .atomic)
    }
}

var currentConfig = loadConfig()

// MARK: - Actions

func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

@discardableResult
func runOpen(_ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = arguments
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    } catch {
        log("failed to run open \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        return -1
    }
}

let actionQueue = DispatchQueue(label: "com.ranbam.highfive.action")

/// Does whatever the config asks for.
func perform(_ config: Config) {
    switch config.action {
    case "app":
        let name = config.appName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { log("action=app but no app is set"); return }
        log("open -a \(name)")
        let status = runOpen(["-a", name])
        if status != 0 { log("open -a \(name) exited \(status)") }

    case "shortcut":
        guard ShortcutPoster.hasPermission else {
            log("action=shortcut but Accessibility permission is not granted")
            return
        }
        guard let combo = ShortcutParser.parse(config.shortcut) else {
            log("could not parse shortcut \"\(config.shortcut)\"")
            return
        }
        ShortcutPoster.post(combo)

    default:
        // Raycast's launcher, through its own deeplink.
        if config.launchIfNeeded, !config.bundleID.isEmpty, !isRunning(config.bundleID) {
            log("\(config.bundleID) not running, launching \(config.app) first")
            runOpen(["-a", config.app])
            Thread.sleep(forTimeInterval: 1.2)
        }
        log("open \(config.url)")
        let status = runOpen([config.url])
        if status != 0 { log("open \(config.url) exited \(status)") }
    }
}

// MARK: - Gesture detection

final class Detector {
    private let lock = NSLock()
    private var config: Config

    // Gesture state
    private var maxCount = 0
    private var baseTime: Double = 0
    private var baseCentroid: (x: Float, y: Float) = (0, 0)
    private var baseSpread: Float = 0
    private var maxDrift: Float = 0
    private var minSpread: Float = .greatestFiniteMagnitude
    private var lastFire: Double = 0

    init(config: Config) { self.config = config }

    func update(_ newConfig: Config) {
        lock.lock(); config = newConfig; lock.unlock()
    }

    func handle(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        var points: [(Float, Float)] = []
        if let touches = touches {
            for i in 0..<count {
                let touch = touches[i]
                if touch.state == 3 || touch.state == 4 {      // MakeTouch / Touching
                    points.append((touch.normalizedVector.position.x,
                                   touch.normalizedVector.position.y))
                }
            }
        }

        lock.lock(); defer { lock.unlock() }
        let config = self.config
        let now = timestamp
        let fingers = points.count

        if fingers == 0 {
            defer { clear() }
            guard maxCount > 0 else { return }

            let duration = now - baseTime
            guard maxCount >= config.fingers, now - lastFire > config.cooldown else { return }

            let allowsTap = config.gesture != "pinch"
            let allowsPinch = config.gesture != "tap"

            let isTap = allowsTap && duration < config.tapMaxDuration
                && maxDrift < Float(config.tapMaxDrift)
            let isPinch = allowsPinch && duration < config.pinchMaxDuration
                && baseSpread > 0 && minSpread < baseSpread * Float(config.pinchShrink)

            guard isTap || isPinch else {
                log(String(format: "skip fingers=%d dur=%.3f drift=%.3f", maxCount, duration, maxDrift),
                    verboseOnly: true)
                return
            }

            lastFire = now
            log(String(format: "fire %@ fingers=%d dur=%.3f action=%@",
                       isTap ? "tap" : "pinch", maxCount, duration, config.action))
            let snapshot = config
            actionQueue.async { perform(snapshot) }
            return
        }

        let cx = points.reduce(0) { $0 + $1.0 } / Float(fingers)
        let cy = points.reduce(0) { $0 + $1.1 } / Float(fingers)
        var spread: Float = 0
        for point in points { spread += hypot(point.0 - cx, point.1 - cy) }
        spread /= Float(fingers)

        if fingers > maxCount {                 // re-baseline whenever we hit a new peak
            maxCount = fingers
            baseTime = now
            baseCentroid = (cx, cy)
            baseSpread = spread
            maxDrift = 0
            minSpread = spread
        } else {
            let drift = hypot(cx - baseCentroid.x, cy - baseCentroid.y)
            if drift > maxDrift { maxDrift = drift }
            if spread < minSpread { minSpread = spread }
        }
    }

    private func clear() {
        maxCount = 0
        maxDrift = 0
        baseSpread = 0
        minSpread = .greatestFiniteMagnitude
    }
}

let detector = Detector(config: currentConfig)
let frameCallback: MTFrameCallback = { _, touches, count, timestamp, _ in
    detector.handle(touches: touches, count: count, timestamp: timestamp)
}

// Debug: `kill -USR1 <pid>` performs the action once, to test the agent's own
// context. `kill -HUP <pid>` re-reads the config without restarting.
signal(SIGUSR1, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
sigSrc.setEventHandler { actionQueue.async { perform(currentConfig) } }
sigSrc.resume()

signal(SIGHUP, SIG_IGN)
let hupSrc = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
hupSrc.setEventHandler {
    currentConfig = loadConfig()
    detector.update(currentConfig)
    log("reloaded config action=\(currentConfig.action)")
}
hupSrc.resume()

// MARK: - Command line

let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func printConfig(_ config: Config) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

if args.contains("--help") || args.contains("-h") {
    print("""
    HighFive — a five-finger trackpad gesture that does one thing.

      --show                       print the current settings
      --action raycast|app|shortcut  what the gesture does (default raycast)
      --url <url>                  raycast: link to open (default raycast://)
      --app <name>                 app: which app to open
      --bundle <id>                raycast: bundle id used for the cold-start check
      --shortcut <combo>           shortcut: e.g. cmd+shift+4, option+f, ⌥F
      --fingers <n>                how many fingertips are required (default 5)
      --gesture tap|pinch|both     which gesture to accept (default both)
      --fire                       do the action once, now
      --test-shortcut <combo>      parse a shortcut and report it

    After changing settings, restart the agent so it picks them up:
      launchctl kickstart -k gui/$(id -u)/com.ranbam.highfive
    """)
    exit(0)
}

if args.contains("--show") {
    printConfig(currentConfig)
    exit(0)
}

if let combo = value(after: "--test-shortcut") {
    guard let parsed = ShortcutParser.parse(combo) else {
        print("could not parse \"\(combo)\"")
        exit(1)
    }
    print("parsed: \(parsed.display)  keyCode=\(parsed.keyCode)  flags=\(parsed.flags.rawValue)")
    print("accessibility permission: \(ShortcutPoster.hasPermission)")
    if args.contains("--post") { print("posted: \(ShortcutPoster.post(parsed))") }
    exit(0)
}

if args.contains("--fire") {
    perform(currentConfig)
    Thread.sleep(forTimeInterval: 1.0)
    exit(0)
}

// Any setting flag rewrites the config file.
var configChanged = false
var config = currentConfig

if let action = value(after: "--action") {
    guard ["raycast", "app", "shortcut"].contains(action) else {
        print("--action must be raycast, app or shortcut"); exit(2)
    }
    config.action = action; configChanged = true
}
if let url = value(after: "--url")           { config.url = url; configChanged = true }
if let app = value(after: "--app")           { config.appName = app; configChanged = true }
if let bundle = value(after: "--bundle")     { config.bundleID = bundle; configChanged = true }
if let shortcut = value(after: "--shortcut") { config.shortcut = shortcut; configChanged = true }
if let fingers = value(after: "--fingers") {
    guard let n = Int(fingers), (1...10).contains(n) else { print("--fingers must be 1…10"); exit(2) }
    config.fingers = n; configChanged = true
}
if let gesture = value(after: "--gesture") {
    guard ["tap", "pinch", "both"].contains(gesture) else {
        print("--gesture must be tap, pinch or both"); exit(2)
    }
    config.gesture = gesture; configChanged = true
}

if configChanged {
    saveConfig(config)
    currentConfig = config
    print("Saved. Restart the agent to apply it:")
    print("  launchctl kickstart -k gui/$(id -u)/com.ranbam.highfive")
    exit(0)
}

// MARK: - Run the agent

log("start version=1.1 action=\(currentConfig.action) fingers=\(currentConfig.fingers) gesture=\(currentConfig.gesture) verbose=\(verbose)")

guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
    log("fatal: dlopen failed: \(String(cString: dlerror()))")
    exit(1)
}
guard let createListSym = dlsym(handle, "MTDeviceCreateList"),
      let registerSym   = dlsym(handle, "MTRegisterContactFrameCallback"),
      let startSym      = dlsym(handle, "MTDeviceStart") else {
    log("fatal: required MultitouchSupport symbols missing")
    exit(1)
}
let createList = unsafeBitCast(createListSym, to: MTCreateListFn.self)
let register   = unsafeBitCast(registerSym,   to: MTRegFn.self)
let start      = unsafeBitCast(startSym,      to: MTStartFn.self)

guard let listPtr = createList() else {
    log("fatal: no multitouch devices")
    exit(1)
}
let list = Unmanaged<CFArray>.fromOpaque(listPtr).takeRetainedValue()
let deviceCount = CFArrayGetCount(list)
log("devices=\(deviceCount)")
for i in 0..<deviceCount {
    guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
    let device = UnsafeMutableRawPointer(mutating: raw)
    register(device, frameCallback)
    log("device \(i) started status=\(start(device, 0))")
}

RunLoop.main.run()
