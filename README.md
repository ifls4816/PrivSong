# PrivSong (私音)

Native iOS 26.1+ music client for Emby, built with SwiftUI and AVPlayer.

## Run

Open `PrivSong.xcodeproj` in Xcode 26 or later, choose an iOS 26.1+ iPhone simulator or device, then run the `PrivSong` scheme. GitHub Actions builds the unsigned IPA with Xcode 27 and runs the regression suite on iOS 26 and iOS 27 simulators.

The sign-in screen accepts Emby server addresses such as:

```text
https://music.example.com
```

## Current Features

- Apple Music style SwiftUI tabs: Listen Now, Library, Search, Settings
- Emby username/password authentication
- Local session restore with Keychain credentials and account-scoped library, queue, and history
- Music library fetch through Emby audio item APIs
- Album artwork loading from Emby image endpoints
- Streaming playback through Emby audio stream URLs
- Mini player and full now playing screen
- Search against the Emby music library

## Notes

Server addresses default to HTTPS. For Emby servers on a trusted local network that only support HTTP, enter the full `http://` address and allow Local Network access when iOS prompts. HTTP sends login credentials in plaintext.

The Library, Playback, and Artwork signpost categories mark sync, indexing, snapshot I/O, track startup, and cover loading in Instruments. iOS 27 can also group device metrics by the active screen and library loading state.
