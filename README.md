# MusicEmby

Native iOS 26+ music client for Emby, built with SwiftUI and AVPlayer.

## Run

Open `ios-music.xcodeproj` in Xcode 26 or later, choose an iOS 26+ iPhone simulator or device, then run the `ios-music` scheme.

The sign-in screen accepts Emby server addresses such as:

```text
http://192.168.1.10:8096
https://music.example.com
```

## Current Features

- Apple Music style SwiftUI tabs: Listen Now, Library, Search, Settings
- Emby username/password authentication
- Local session restore with `UserDefaults`
- Music library fetch through Emby audio item APIs
- Album artwork loading from Emby image endpoints
- Streaming playback through Emby audio stream URLs
- Mini player and full now playing screen
- Search against the Emby music library

## Notes

The project allows arbitrary HTTP loads so local Emby servers on plain `http://` work during development. For a production build, prefer HTTPS and tighten App Transport Security settings.
