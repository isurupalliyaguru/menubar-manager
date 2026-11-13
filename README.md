# MenuBar Manager

A small, open-source menu bar manager for macOS. It's built for MacBooks with a notch, where
too many menu bar icons end up hidden behind the camera housing.

- **Hide icons** you rarely use behind a `│` separator.
- **Open the dropdown** with the chevron (`⌄`) to see every icon, including the ones under the
  notch. Click one to open its menu.
- **Pin** the few you want always visible.
- Search, real icon previews, and launch at login.

```
[ hidden icons… ] │ [ always visible ] ⌄  Wi‑Fi  Battery  Clock
                  ^ separator          ^ click for the dropdown
```

## Install

```bash
brew tap isurupalliyaguru/menubar-manager https://github.com/isurupalliyaguru/menubar-manager
brew install --cask menubar-manager
```

Or download `MenuBarManager.zip` from [Releases](https://github.com/isurupalliyaguru/menubar-manager/releases).

> The app isn't notarized yet. If macOS refuses to open it, go to
> **System Settings → Privacy & Security** and click **Open Anyway**.

### Permissions

| Permission | Why |
|---|---|
| Accessibility (required) | To list menu bar icons, and to click or reorder them for you |
| Screen Recording (optional) | To show the real icon images in the dropdown instead of app icons |

Nothing leaves your Mac. The app makes no network requests.

## Usage

- **Left-click `⌄`**: open the dropdown.
- **Right-click `⌄` or click `│`**: settings (show all icons, open at login, permissions, quit).
- **Pin / unpin**: hover an icon in the dropdown and click the pin. You can also ⌘-drag icons
  across the `│` separator yourself.

## How it works

- The `│` separator is a status item. When "collapsed", its width is set to 10,000 pt, which
  pushes every item to its left off-screen (the same trick Hidden Bar uses).
- Items are discovered through the Accessibility API (`AXExtrasMenuBar` on each running app).
- Clicking an icon in the dropdown briefly expands the bar, sends a click to the icon (which
  works even behind the notch), and collapses the bar again after you're done.
- Pinning is a synthesized ⌘-drag across the separator, exactly what you'd do by hand.
- Icon previews use ScreenCaptureKit.

## Build from source (no Xcode IDE needed)

You need the Swift toolchain (Xcode or Command Line Tools) on macOS 14 or later.

```bash
./build.sh                 # -> build/MenuBar Manager.app (ad-hoc signed)
open "build/MenuBar Manager.app"
```

Every ad-hoc build has a new signature, so macOS asks you to grant Accessibility again after
each rebuild. To avoid that, create a local signing identity once:

```bash
./scripts/make-dev-cert.sh
SIGN_IDENTITY="MenuBarManager Local Dev" ./build.sh
```

### Releasing

Push a tag. GitHub Actions builds a universal app, attaches the zip to a release, and updates
the cask's version and checksum.

```bash
git tag v0.1.0 && git push origin v0.1.0
```

## Known limitations

- If the hidden icons don't all fit even when the bar is expanded (for example, while an app
  with a long menu is in front), macOS drops some of them. The dropdown then falls back to an
  Accessibility "press", which most apps support.
- Control Center items can't show real icon previews yet.

## License

MIT
