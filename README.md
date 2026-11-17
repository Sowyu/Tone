<p align="center">
  <img src="docs/icon.png" width="128" alt="Tone icon">
</p>

<h1 align="center">Tone</h1>

<p align="center">Per-app volume and EQ from your menu bar.</p>

<p align="center">
  <img src="docs/panel.png" width="340" alt="Tone's menu bar panel">
</p>

Tone lives in your menu bar, and when you click it you'll see every app that's making sound. You can adjust each one independently, and you also get controls for your output, input, and Now Playing.

- You can set each app's volume anywhere from 0 to 200%.
- There's a 10-band EQ you can apply to any app, and it comes with presets.
- You can switch output and input devices, and connect paired Bluetooth headphones from the same list.
- You'll see AirPods battery before they even connect, and you can change Listening Mode and Conversation Awareness.
- You can play, pause, and skip whatever's playing.
- There's also a slider for the main output volume.

There's no drivers or kernel extensions, instead Tone just uses what macOS provides.

## Requirements

- macOS 15 or later. I've tested it on macOS 27.
- Optional: `brew install media-control` if you want Now Playing support.

## Permissions

The first time you change volume or EQ, macOS will ask you to allow system audio recording. Your audio never leaves your Mac. It'll also ask for Bluetooth so Tone can show battery and control your AirPods.

## Build from source

```
brew install xcodegen
make identity   # once
make install
```

`make identity` makes a local signing certificate, so macOS remembers Tone's permissions every time you rebuild it.

## Credits

The design is based on Jace's sound mixer concept (JaceThings on X): https://x.com/JaceThings/status/2105247096916099505. I'm not affiliated with Jace, I just loved the idea and built it.

## Known limits

- Now Playing only works if you've installed media-control.
- Spatial Audio isn't available.
- Battery for non-Apple headphones only shows while they're connected.

## License

MIT. See [LICENSE](LICENSE).