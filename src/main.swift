//
//  HighFive — open Raycast with a five-finger tap (or pinch) on the trackpad.
//
//  A tiny background agent (~70 KB). It reads raw trackpad contacts from Apple's
//  private MultitouchSupport framework and, when it sees five fingers touch and
//  lift quickly, opens Raycast's launcher via its URL scheme (`raycast://`).
//
//  Why a URL and not a keystroke? On macOS 26+ WindowServer drops synthetic
//  modifier-bearing key events before they reach Carbon hotkey matchers, so
//  CGEventPost cannot trigger Raycast from an ad-hoc-signed helper. The app's
//  own deeplink has no such gate — and needs no Accessibility permission.
//
//  No third-party app, no license, no menu bar item, ~0% CPU.
//
//  Configure:   HighFive --set-url "raycast://"
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

/// Default target: Raycast's launcher deeplink.
let defaultURL = "raycast://"

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
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Config

let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/highfive/url")

func configuredURL() -> String {
    if let s = try? String(contentsOf: configURL, encoding: .utf8) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    return defaultURL
}

let targetURL = configuredURL()

// MARK: - Launching

let raycastBundleID = "com.raycast.macos"

func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

@discardableResult
func runOpen(_ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError  = pipe
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty { log("open(\(arguments.joined(separator: " "))) out=\(out)") }
        return task.terminationStatus
    } catch {
        log("failed to run open: \(error.localizedDescription)")
        return -1
    }
}

/// Opens the target through LaunchServices (the same path as `open raycast://`).
/// Cold start matters: if Raycast isn't running, the deeplink is delivered before
/// it can show its launcher, so launch it first and give it a moment.
func openTarget() {
    log("open \(targetURL)")
    if !isRunning(raycastBundleID) {
        log("raycast not running; launching first")
        runOpen(["-a", "Raycast"])
        Thread.sleep(forTimeInterval: 1.2)
    }
    log("open exit=\(runOpen([targetURL]))")
}

// MARK: - Gesture detection

final class Detector {
    private let lock = NSLock()

    // Tunables
    private let requiredFingers: Int   = 5
    private let tapMaxDuration: Double = 0.50   // seconds from peak to fingers-up
    private let tapMaxDrift: Float     = 0.06   // centroid movement (0..1)
    private let pinchMaxDuration: Double = 0.90
    private let pinchShrink: Float     = 0.70   // spread must fall below 70% of peak
    private let cooldown: Double       = 0.60

    // Gesture state
    private var maxCount = 0
    private var baseTime: Double = 0
    private var baseCentroid: (x: Float, y: Float) = (0, 0)
    private var baseSpread: Float = 0
    private var maxDrift: Float = 0
    private var minSpread: Float = .greatestFiniteMagnitude
    private var lastFire: Double = 0

    func handle(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        var pts: [(Float, Float)] = []
        if let touches = touches {
            for i in 0..<count {
                let t = touches[i]
                if t.state == 3 || t.state == 4 {           // MakeTouch / Touching
                    pts.append((t.normalizedVector.position.x, t.normalizedVector.position.y))
                }
            }
        }

        lock.lock(); defer { lock.unlock() }
        let now = timestamp
        let n = pts.count

        if n == 0 {
            if maxCount > 0 {
                let dur = now - baseTime
                let isTap = maxCount >= requiredFingers && dur < tapMaxDuration && maxDrift < tapMaxDrift
                let isPinch = maxCount >= requiredFingers && dur < pinchMaxDuration
                    && baseSpread > 0 && minSpread < baseSpread * pinchShrink
                if (isTap || isPinch) && (now - lastFire) > cooldown {
                    lastFire = now
                    log(String(format: "fire %@ fingers=%d dur=%.3f drift=%.3f spread=%.3f->%.3f",
                               isTap ? "tap" : "pinch", maxCount, dur, maxDrift, baseSpread, minSpread))
                    DispatchQueue.main.async { openTarget() }
                } else {
                    log(String(format: "skip fingers=%d dur=%.3f drift=%.3f", maxCount, dur, maxDrift),
                        verboseOnly: true)
                }
            }
            maxCount = 0; maxDrift = 0; baseSpread = 0
            minSpread = .greatestFiniteMagnitude
            return
        }

        let cx = pts.reduce(0) { $0 + $1.0 } / Float(n)
        let cy = pts.reduce(0) { $0 + $1.1 } / Float(n)
        var spread: Float = 0
        for p in pts { spread += hypot(p.0 - cx, p.1 - cy) }
        spread /= Float(n)

        if n > maxCount {                       // re-baseline whenever we hit a new peak
            maxCount = n
            baseTime = now
            baseCentroid = (cx, cy)
            baseSpread = spread
            maxDrift = 0
            minSpread = spread
        } else {
            let d = hypot(cx - baseCentroid.x, cy - baseCentroid.y)
            if d > maxDrift { maxDrift = d }
            if spread < minSpread { minSpread = spread }
        }
    }
}

let detector = Detector()
let frameCallback: MTFrameCallback = { _, touches, count, timestamp, _ in
    detector.handle(touches: touches, count: count, timestamp: timestamp)
}

// Debug: `kill -USR1 <pid>` opens the target once, to test the agent's own context.
signal(SIGUSR1, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
sigSrc.setEventHandler { openTarget() }
sigSrc.resume()

// MARK: - Entry point

let args = CommandLine.arguments

func argValue(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let raw = argValue(after: "--set-url") {
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? (raw + "\n").write(to: configURL, atomically: true, encoding: .utf8)
    print("HighFive will now open: \(raw)")
    exit(0)
}

if args.contains("--show") {
    print("HighFive opens: \(targetURL)")
    exit(0)
}

if args.contains("--fire") {                      // self-test: open it once
    openTarget()
    Thread.sleep(forTimeInterval: 1.0)
    exit(0)
}

log("start version=1.0 target=\"\(targetURL)\" verbose=\(verbose)")

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
