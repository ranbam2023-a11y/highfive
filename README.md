# HighFive ✋

**Open [Raycast](https://raycast.com) with a five‑finger tap on your Mac trackpad.**

macOS ships a five‑finger gesture that opens its own Spotlight/Launchpad picker, and gives you no way to point it at an app. HighFive fills that gap: a ~70 KB background agent that watches the trackpad and opens Raycast for you when it sees five fingers.

No third‑party launcher, no subscription, no menu‑bar item, **no permissions**, ~0% CPU.

---

## Why

- Raycast has no trackpad‑gesture support.
- macOS's built‑in five‑finger gesture is hard‑wired to Apple's Spotlight/Launchpad picker.
- Big gesture apps (BetterTouchTool, Multitouch, …) work, but they're another licence and another heavyweight process for one gesture.

HighFive is the smallest possible thing that does exactly this one job.

## Download

Grab `dist/HighFive-1.0.dmg`, open it, and drag **HighFive** to Applications — or just build from source below. (No permissions are required either way.)

## Install

```bash
git clone https://github.com/ranbam2023-a11y/highfive.git
cd highfive
./install.sh          # builds and installs
./build.sh --dmg      # or just build a .dmg into dist/
```

Then turn off Apple's own gesture so it doesn't race Raycast:

> **System Settings → Trackpad → More Gestures → Show Desktop: OFF**

In macOS 26/27 this also disables the new "Open Apps" Spotlight picker. Now do a **five‑finger tap** — Raycast opens.

**No Accessibility permission is required.** HighFive opens Raycast through its `raycast://` URL scheme instead of synthesising a keystroke.

## How it works

HighFive reads raw trackpad contacts from Apple's private `MultitouchSupport.framework`
(via `dlopen`/`dlsym`, so nothing is linked at build time) and keeps a tiny state machine:

| Gesture | Rule |
|---|---|
| **Tap** | 5 fingers peak, all lift within 0.50 s, centroid moved < 0.06 |
| **Pinch** | 5 fingers peak, all lift within 0.90 s, finger spread shrank below 70 % |

When either matches, it runs `open raycast://`, which LaunchServices routes to Raycast's own
launcher. Two reasons this beats pressing a hotkey:

1. **It works.** On macOS 26+ WindowServer drops synthetic modifier‑bearing key events
   before they reach Carbon hotkey matchers (`CGXSenderCanSynthesizeEvents`), so an
   ad‑hoc‑signed helper cannot trigger Raycast with `CGEventPost`. The deeplink has no
   such gate.
2. **No permissions.** Posting events needs Accessibility + PostEvent TCC grants; opening
   a URL needs nothing.

## Configuration

Change what the gesture opens:

```bash
~/Applications/HighFive.app/Contents/MacOS/HighFive --set-url "raycast://"
~/Applications/HighFive.app/Contents/MacOS/HighFive --show
launchctl kickstart -k gui/$(id -u)/com.ranbam.highfive   # reload
```

Stored in `~/.config/highfive/url`. Any URL or app‑registered scheme works.

**Gesture tunables** live at the top of `Detector` in [`src/main.swift`](src/main.swift):
finger count, tap duration/movement, pinch thresholds, and the debounce cooldown.
Edit, then re‑run `./install.sh`.

## Troubleshooting

Logs go to `~/Library/Logs/HighFive.log` (fires only). For verbose per‑touch logging:

```bash
touch ~/.highfive-debug
launchctl kickstart -k gui/$(id -u)/com.ranbam.highfive
```

To test the launch part in isolation:

```bash
~/Applications/HighFive.app/Contents/MacOS/HighFive --fire
```

## Uninstall

```bash
./uninstall.sh
```

## Requirements

- macOS 12+ (developed on macOS 27 / Apple silicon, built‑in trackpad)
- Xcode Command Line Tools (`swiftc`) to build

## Notes

- Uses a **private** Apple framework. It has been stable for years, but a future macOS
  update could change it — if the gesture stops working, check the log.
- Not affiliated with Raycast. "Raycast" is a trademark of its owners.

## License

MIT — see [LICENSE](LICENSE).
