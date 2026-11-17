# Tone

Tone is a per-app volume mixer and equalizer that lives in the macOS menu bar. Click the icon and a panel shows the output volume, output and input devices, what's playing, and every app making sound. Each app gets its own volume from 0 to 200% and its own 10-band EQ.

Tone is a native Swift 6 and SwiftUI app. It installs no audio driver, HAL plug-in or kext. Per-app audio goes through Core Audio process taps, which macOS has offered since 14.2.

## Credits

The design is Jace's sound mixer concept (JaceThings on X): https://x.com/JaceThings/status/2105247096916099505. Tone is an independent implementation of that concept and is not affiliated with Jace.

## Design

The status item opens a panel laid out like the concept video: Sound with the output slider, then Output, Input, Now Playing and Applications as sections that open and close, then Settings… and Quit Tone. It is drawn to match a macOS 27 menu. The surface is the same `NSGlassEffectView` a native menu uses, with its 12 pt radius. Rows have the native highlight, an accent fill inset 5 pt from the edge with white text, and only one row is ever highlighted. The mouse and the arrow keys move the same highlight. Return clicks, Right and Left open and close, and Escape closes the panel.

Output rows match the system Sound menu, with the device's glyph in a circle, battery levels, and paired Bluetooth outputs that connect when clicked. Selected AirPods open their Listening Mode list. Clicking an app or a Now Playing row springs open its volume slider, Equalizer switch and Preset menu, and the graph button next to Preset shows the equalizer in a popover to the left. The curve is the actual magnitude response of the biquads the DSP runs. Right-click an app for Keep in Menu, Reset Volume, Move Up, Move Down and Hide from Menu. Reduce Motion swaps the springs for a short fade.

## Requirements

- macOS 15 or later. Developed and tested on macOS 27.
- Xcode 16 or later, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Optional: [media-control](https://github.com/ungive/media-control) (`brew install media-control`) for the Now Playing section.

## Build and install

1. Create the signing identity once with `make identity`. This step is safe to re-run because it never replaces an existing identity.
2. Copy `Config/Signing.example.xcconfig` to `Config/Signing.local.xcconfig`. `make` does this for you if the file is missing.
3. Run `make install`.

`make install` generates the Xcode project, builds Release, re-signs the app with the stable identity and a fixed designated requirement, copies it to `/Applications/Tone.app` with `ditto`, prints the signature, and launches it. Always run Tone from `/Applications`, never from DerivedData.

To work in Xcode, run `xcodegen generate` and open `Tone.xcodeproj`. It signs with the same identity through `Config/Tone.xcconfig`.

## Why the signing setup matters

macOS stores privacy grants such as audio capture against the app's designated requirement. An ad-hoc signature contains the code hash, so every rebuild looks like a new app and loses its permissions.

`scripts/create-signing-identity.sh` creates a self-signed code-signing certificate called "Tone Local Signing" in the login keychain. It's valid for 10 years and its name contains no personal details. `make sign` then signs with:

```
designated => identifier "com.gooober.tone" and certificate leaf = H"<sha1 of that certificate>"
```

That requirement contains no code hash, so it stays the same on every build and the grant survives. Check it with:

```
codesign -dv --verbose=4 /Applications/Tone.app
codesign -d -r- /Applications/Tone.app
```

Never regenerate the certificate and never change the bundle identifier `com.gooober.tone`. Either change resets the permissions. If permissions get stuck from an older ad-hoc build, run `tccutil reset All com.gooober.tone` once and launch Tone again.

The certificate is self-signed, so `security find-identity` lists it as `CSSMERR_TP_NOT_TRUSTED`. That's expected. `codesign` and TCC only compare the leaf hash.

## Permissions

1. The first time you change an app's volume or EQ, macOS asks whether Tone may record system audio. The prompt text comes from `NSAudioCaptureUsageDescription`.
2. Click Allow. Tone taps only the apps you've changed, and the audio never leaves your Mac.
3. If you clicked Don't Allow, the Applications section shows Allow System Audio Recording…, which opens System Settings > Privacy & Security > Screen & System Audio Recording. Turn Tone on there.

Tone checks the permission state before it taps anything. If the check isn't available and a tap delivers only silence while the app is playing, Tone removes its taps so the app's audio isn't lost, then shows the same row.

Open at login uses `SMAppService`. Turn it on in Settings… in Tone's panel.

## How it works

- `DeviceManager` lists devices, switches the system default output and input, and reads and writes the master volume (`VirtualMainVolume`, falling back to per-channel volume).
- `ProcessMonitor` watches `kAudioHardwarePropertyProcessObjectList` and each process's `kAudioProcessPropertyIsRunningOutput`, and groups helper processes under the app that owns them.
- `AppTap` creates a private `CATapDescription` tap with `.mutedWhenTapped`, then a private aggregate device on the current output with the tap attached, then an IOProc.
- `DSPKernel` runs on the HAL IO thread: preamp, ten RBJ peaking biquads through `vDSP_biquad`, gain smoothing and a peak limiter for overdrive. Parameters arrive through a seqlock, so the audio thread never allocates, locks or waits.
- `AudioEngine` keeps taps in sync with your settings. It taps an app only while its volume isn't 100% or its EQ is on. When the default output changes it builds the new taps before it stops the old ones, so the unprocessed audio never leaks through.
- `NowPlayingService` reads media sessions from `media-control`.
- `PresetStore` and `SettingsStore` save per-app volume, EQ, presets, pins, hidden apps and row order as JSON in `~/Library/Application Support/Tone/`, keyed by bundle ID. Settings re-apply whenever the app plays again.

The tap and the aggregate are private to Tone's process. If Tone quits or crashes, macOS removes both and the app's normal audio returns.

## Testing hooks

Tone has an opt-in debug mode for scripted tests. Turn it on with `defaults write com.gooober.tone DebugControl -bool YES`. Tone then writes per-tap stats every second to `~/Library/Logs/Tone/diagnostics.log`, including callbacks, input and output peak, gain ratio and processor overloads. It also accepts these distributed notifications:

- `com.gooober.tone.debug.set` with a `key` (bundle ID) plus `volume`, `eqEnabled` or `preset` changes an app's settings.
- `com.gooober.tone.debug.panel` opens or closes the panel.
- `com.gooober.tone.debug.expand` opens the panel and expands the row named by the notification's object, such as `app:com.apple.Music` or `np:com.spotify.client`. Plain `app` expands the first app.
- `com.gooober.tone.debug.equalizer` expands the first app and shows its equalizer popover.
- `com.gooober.tone.debug.keys` replays keys named in the object, for example `down down return`, against the open panel.
- `com.gooober.tone.debug.settings` opens the Settings window.

`DebugAppearance` set to `light` or `dark` overrides the system appearance in debug mode.

Turn debug mode off with `defaults delete com.gooober.tone DebugControl`.

## Privacy checks

The repo ships a gitleaks pre-commit hook. Enable it once per clone:

```
brew install gitleaks
git config core.hooksPath .githooks
```

The hook runs `gitleaks git --staged` and refuses commits whose author email isn't a GitHub no-reply address. To block personal strings such as your email or name, create a gitignored `.gitleaks.local.toml` that extends `.gitleaks.toml` and adds your own rule. The hook uses the local file when it exists, so the patterns never get committed.

Signing material (`*.p12`, `*.cer`, keys, keychains, `Signing.local.xcconfig`) is in `.gitignore`.

## Known limits

- Now Playing needs `media-control`. Since macOS 15.4 only Apple-entitled apps can read MediaRemote directly, and there's no public API for other apps' sessions. Without the tool the section is left out of the panel, and Settings says how to install it.
- MediaRemote exposes one active session. Tone keeps earlier sessions listed as paused until their app quits, but only the active one accepts play/pause and next.
- Command line tools are grouped under the app that launched them. For example, `afplay` started from Terminal shows up as Terminal.
- If an output device also has input channels, such as a USB headset, the aggregate lists those first. Tone reads the tap from the last input stream.

## License

MIT. See [LICENSE](LICENSE).
