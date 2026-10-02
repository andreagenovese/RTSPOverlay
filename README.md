# RTSP Overlay

**English** · [Italiano](README.it.md)

A tiny native macOS app (< 1 MB, no dependencies) to watch IP cameras and NVRs live over RTSP,
including as floating windows that stay on top of everything else. It works with any H.264/H.265 RTSP source;
for cameras that don't use the default URL scheme, just set a custom path.

The interface is available in English and Italian and follows the macOS language.

![Three cameras as overlays on top of other windows, with the menu bar menu open](docs/screenshot.svg)
<sub>Illustration.</sub>

## Installation

### 1. Requirements
- macOS 14 (Sonoma) or later, on Apple silicon or Intel.
- Apple's command line developer tools (Swift 5.9 or later). If you don't have them (or Xcode) yet:
  ```bash
  xcode-select --install
  ```
  Check with `swift --version`.

### 2. Clone the repository
```bash
git clone https://github.com/andreagenovese/RTSPOverlay.git
cd RTSPOverlay
```

### 3. Build
```bash
./build.sh
```
This compiles a release build and creates `build/RTSPOverlay.app` (signed ad hoc, under 1 MB).

### 4. Install
```bash
cp -R build/RTSPOverlay.app /Applications/
open /Applications/RTSPOverlay.app
```
The app has no Dock icon: look for the 📹 icon in the menu bar. On first launch the settings window opens.

### 5. First launch
- macOS asks for **Local Network** access: allow it, otherwise the app cannot reach the cameras.
  You can change it later in System Settings → Privacy & Security → Local Network.
- Add your cameras in the settings window (see [Configuration](#configuration)).
- Optional: to start the app automatically, add it in System Settings → General → Login Items.

Since you build the app yourself, Gatekeeper does not block it. If you copy the built app to another Mac
and macOS refuses to open it, run `xattr -dr com.apple.quarantine /Applications/RTSPOverlay.app`.

### Update
```bash
cd RTSPOverlay
git pull
./build.sh
rm -rf /Applications/RTSPOverlay.app && cp -R build/RTSPOverlay.app /Applications/
```
Quit the app from its menu before replacing it. Cameras and settings are kept.

### Uninstall
Delete `/Applications/RTSPOverlay.app`. To also remove settings and passwords:
```bash
defaults delete local.rtspoverlay.app
security delete-generic-password -s RTSPOverlay
```

## Usage
- 📹 icon in the menu bar: camera list (click = open/close overlay), grid, settings.
- **Overlay**: drag to move, resize from the edges (keeps the aspect ratio).
  - Double-click: switch between the sub stream (light) and the main stream (HD).
  - Right-click: always on top, opacity, ignore clicks, reconnect.
- Position, size and open overlays are restored on relaunch.
- Passwords are stored in the macOS Keychain.

## Configuration
| Field | Typical value |
|---|---|
| Address | Local IP (192.168.1.100) or DDNS/public IP |
| RTSP port | 554 (or the port forwarded on your router) |
| Channel | 1 for a standalone camera; for an NVR, the camera's input number |

Generated URL: `rtsp://host:554/Streaming/Channels/<channel>01` (main) / `…02` (sub).
The "duplicate" button quickly creates an entry for the next channel of the same NVR.

Supported codecs: H.264 and H.265 (hardware decoding). MJPEG is not supported.

## Diagnostics
```bash
build/RTSPOverlay.app/Contents/MacOS/RTSPOverlay --probe 'rtsp://admin:password@192.168.1.100:554/Streaming/Channels/102'
```
Connects, decodes about 5 seconds of video and prints codec, resolution, fps and any errors.

## License
[MIT](LICENSE)
