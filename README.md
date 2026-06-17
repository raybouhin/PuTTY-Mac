# PuTTY-Mac

A native macOS port of PuTTY for Apple Silicon. It uses a Cocoa (AppKit)
interface instead of GTK, so there is no X11 or GTK dependency. The result is
a normal, self contained `.app` bundle.

This is built on the PuTTY 0.84 source. The SSH stack, terminal emulator,
crypto and configuration code are the real PuTTY code, unchanged. Only the
front end (the window, drawing, dialogs and event loop) is rewritten in
Objective-C against macOS APIs. The macOS specific code lives in the
[`macosx/`](macosx/) directory.

## What works

* SSH sessions in a Core Text terminal
* The full PuTTY configuration dialog, with every panel, generated from
  PuTTY's own control definitions
* PuTTYgen for key generation (RSA, ECDSA, Ed25519, DSA), shipped as a
  helper inside the app and reachable from the File and Dock menus
* Dark mode
* Multiple independent windows (Cmd-N, the File menu, or the Dock menu)
* Saved sessions and host keys in `~/.putty`, the same layout PuTTY uses on
  Unix
* Telnet, Rlogin, Raw and SUPDUP backends, the same as upstream PuTTY

## Requirements

* An Apple Silicon Mac (arm64)
* macOS 11 or later
* To build: the Xcode command line tools and CMake

## Building

GTK detection is turned off so the build uses the portable cores plus the
Cocoa front end:

```
cmake -B build -DPUTTY_GTK_VERSION=NONE -DCMAKE_BUILD_TYPE=Release
cmake --build build --target PuTTY macputtygen -j
```

Use `-DCMAKE_BUILD_TYPE=Release` so the crypto is optimized. Without it
CMake builds with no optimization, which makes RSA key generation slow.

The app is written to `build/macosx/PuTTY.app`, with the `puttygen` helper
copied inside it. Copy it to your Applications folder if you want:

```
cp -R build/macosx/PuTTY.app /Applications/
```

The app is ad hoc signed (it has no Apple Developer ID). If you build it
yourself it runs directly. A copy that arrives through a browser or a
download gets a quarantine flag, and Gatekeeper will refuse to open it. To
allow it, right click the app and choose Open the first time, or clear the
flag:

```
xattr -dr com.apple.quarantine /Applications/PuTTY.app
```

## Where settings live

Sessions, known host keys and the random seed are stored in `~/.putty`
(saved sessions in `~/.putty/sessions`). This matches PuTTY on Unix, so the
data is kept outside the app bundle and survives reinstalling.

## Notes and limitations

* Apple Silicon only. This is not a universal binary, so it will not run on
  Intel Macs without a separate build.
* Text is drawn as runs with Core Text. This is fine for ordinary
  monospaced use. Harder cases such as full bidirectional text or unusual
  combining sequences are not specially handled yet.
* Scrollback exists in the engine, but there is no scrollbar widget yet.
* The colour and font pickers in the config dialog are basic.
* The keyboard handles the common keys (arrows, function keys, Control
  combinations, Backspace, and Option as Meta). It is not yet the complete
  PuTTY keymap.

## Development build

To compile in the optional debug logging and test hooks:

```
cmake -B build -DPUTTY_GTK_VERSION=NONE -DPUTTY_MAC_DEBUG=ON
```

Release builds leave all of that out.

## Credits

PuTTY is written by Simon Tatham and the PuTTY team. This repository is a
macOS port of their work. All of the protocol, crypto and terminal logic is
theirs. The original project is at
https://www.chiark.greenend.org.uk/~sgtatham/putty/.

## License

MIT, the same license as PuTTY. See the [LICENCE](LICENCE) file.
