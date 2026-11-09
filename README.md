# Wallpaper Display

Wallpaper Display is a macOS app for displaying images and videos across one or more monitors. It supports per-monitor media selection, local media files, direct media URLs, and optional YouTube URL resolution through the bundled `yt-dlp` executable.

## Features

- Detects and labels all connected monitors.
- Applies the same media to every monitor or a different media item to each monitor.
- Supports local images and videos.
- Supports direct media links.
- Offers maximum, balanced, and performance quality choices for YouTube downloads.
- Plays video without audio, as intended for wallpaper use.

## Running

Open `WallpaperDisplay.app`, or run `start.command` from Finder. The app does not require Apache, Python, or a local web server.

## YouTube and yt-dlp

YouTube URLs are handled by the separately distributed `yt-dlp` executable. This project does not bypass YouTube access controls. Users are responsible for complying with applicable laws, YouTube's terms, and the rights of the content owner. YouTube availability can change independently of this application.

The bundled executable is accompanied by `yt-dlp-LICENSE.txt` and the upstream `yt-dlp-THIRD_PARTY_LICENSES.txt` notice. See the [yt-dlp project](https://github.com/yt-dlp/yt-dlp) for source and licensing information.

## Repository contents

The compiled app bundle and user media are ignored from source control. Build the app locally from `WallpaperApp.swift` using the included plist, then place the resulting executable in the app bundle's `Contents/MacOS` directory and copy `yt-dlp` into `Contents/Resources`.

## License

No license is granted for the Wallpaper Display source code unless a separate license file is added by the copyright holder. Third-party components retain their own licenses.
