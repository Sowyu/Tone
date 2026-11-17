<p align="center">
  <img src="docs/icon.png" width="128" alt="Tone icon">
</p>

<h1 align="center">Tone</h1>

<p align="center">Per-app volume and EQ, right in your menu bar.</p>

<p align="center">
  <img src="docs/demo.gif" width="600" alt="Tone in action: switching outputs, setting an app's volume and shaping its EQ">
</p>

<p align="center"><a href="docs/demo.mp4">Watch the full-quality video</a></p>

Tone is a menu bar app that lets you mix and shape audio per app. Click the icon and you'll see every app making sound, plus your output and input devices and what's currently playing.

You can set each app's volume anywhere from 0 to 200%, and give it its own 10-band EQ with presets. Switch outputs and inputs, connect paired Bluetooth headphones, and check your AirPods battery before you connect them. You can also change AirPods Listening Mode and Conversation Awareness, and play, pause or skip whatever's playing.

There's no drivers or kernel extensions, instead Tone just uses what macOS provides.

## Requirements

- macOS 15 or later, tested on macOS 27
- Optional: `brew install media-control` for the Now Playing section

## Permissions

The first time you change a volume or EQ, macOS asks to allow system audio recording. The audio never leaves your Mac. Tone also asks for Bluetooth access so it can read battery levels and control AirPods.

## Build from source

```
brew install xcodegen
make identity
make install
```

The local signing certificate is what lets macOS remember Tone's permissions across rebuilds.

## Credits

The design is based on Jace's sound mixer concept ([JaceThings on X](https://x.com/JaceThings/status/2105247096916099505)). Tone isn't affiliated with Jace.

## Known limitations

- Now Playing needs `media-control` installed
- Spatial Audio isn't available
- Battery for non-Apple headphones only shows while connected

## License

[MIT](LICENSE)