# Cadence

A Now Playing widget for the **macOS lock screen**, with synced lyrics, animated album covers and a full-screen player.

Cadence shows what's playing in Apple Music or Spotify on your lock screen, under the clock. Tap the album art to open a full-screen view with the cover, the player, Apple Music-style scrolling lyrics, or the album's animated cover.

> **Experimental.** Cadence relies on private macOS APIs (see [How it works](#how-it-works)). It can break after a macOS update, it can't be on the Mac App Store, and you use it at your own risk.

## Features

- Now Playing card on the lock screen: title, artist, progress, play / pause / skip, album art
- Clickable, draggable progress bar to seek
- Tap the cover for a full-screen view with a soft, slowly moving blur of the album art
- Your own lock screen clock style and font (the system's glass clock), shown on top
- **Synced lyrics**, Apple Music style, from [LRCLIB](https://lrclib.net)
- **Animated album covers** (Apple Music's motion artwork) as a full-screen background, for albums that have one
- Audio output picker (speakers, Bluetooth headphones, displays, …)
- Global shortcut **Control + Option + L** to turn the lock widget on or off
- Menu bar menu: now playing, previous / play / next, audio output, lyrics and widget toggles, launch at login

## Requirements

- Mac with Apple Silicon
- macOS 26 or later
- Apple Music or Spotify (control and metadata via AppleScript)
- Xcode command line tools (to build from source)

## Install

### From a release

1. Download `Cadence.dmg` from the [Releases](../../releases) page.
2. Drag **Cadence** to **Applications**.
3. The app is not notarized, so macOS says it "could not verify" it. Click **Done**, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Cadence. Or run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Cadence.app
   ```

### From source

```sh
git clone <this repo>
cd cadence
./build.sh run        # builds Cadence.app and opens it
./make-dmg.sh         # optional: package Cadence.dmg
```

## Use

1. Open Cadence. A **♪** icon appears in the menu bar.
2. Allow the **Automation** permission prompt for Music / Spotify.
3. Play a song, then lock your Mac (**Control + Command + Q**).
4. Tap the small album thumbnail to go full screen. In the player card you get buttons for lyrics, the full-screen animated cover (when the album has one), and the audio output.

The small button in the top-left corner of the lock screen has the lyrics settings.

## How it works

| Part | Technique |
| --- | --- |
| Drawing on the lock screen | Private **SkyLight** calls move the overlay windows into the lock screen's own Space |
| Lock / unlock detection | `com.apple.screenIsLocked` notifications and `CGSessionCopyCurrentDictionary` |
| Your clock style | Private **LoginUIKit** `LUI2GlassTextView`, configured from your saved lock screen font and weight |
| Now Playing + controls | AppleScript to Music and Spotify |
| Lyrics | [LRCLIB](https://lrclib.net) synced lyrics (no key needed) |
| Album art | The player's own art; otherwise the iTunes Search API at higher resolution |
| Animated covers | Read from the album's public Apple Music web page; **fragile**, breaks if Apple changes the page |
| Audio output | CoreAudio (sets the system default output) |

Everything is in `Sources/Cadence/main.swift`. It builds with SwiftPM and the command line tools, no Xcode project needed.

## macOS says it "could not verify" Cadence

That is Gatekeeper. It shows for any app that isn't signed with a paid Apple Developer ID and notarized by Apple, and Cadence is only ad-hoc signed because it is free and open source. It does not mean anything is wrong with the app, and you can read every line of the source here.

To open it anyway: click **Done**, go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Cadence. Or run once in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Cadence.app
```

You only need to do this the first time. If you'd rather not trust a downloaded build, [build it from source](#from-source); apps you build yourself aren't quarantined.

## Limitations

- Uses **private, undocumented APIs**, so it may stop working on any macOS update.
- Not sandboxed, not notarized (see [the warning above](#macos-says-it-could-not-verify-cadence)), not for the App Store.
- Lyrics and animated covers depend on third-party services and web pages; some songs won't have them.
- Only Music and Spotify are supported (no browser or other players).

## Debugging

Start the app with `CADENCE_DEBUG=1` to write a log to `~/Library/Logs/Cadence.log` and enable the test hooks (creating `/tmp/cadence-preview`, `/tmp/cadence-expand`, `/tmp/cadence-full` triggers a preview / expand / full-screen toggle):

```sh
CADENCE_DEBUG=1 ./Cadence.app/Contents/MacOS/Cadence
```

## Disclaimer

Not affiliated with or endorsed by Apple, Spotify, or any lock screen widget app. "Apple Music", "Spotify" and "macOS" are trademarks of their owners. Album art, lyrics and animated covers belong to their respective rights holders and are fetched for personal display only.

## License

[MIT](LICENSE)
