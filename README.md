# Sideport

A Mac app for sideloading IPAs onto an iPhone with your Apple ID and keeping them signed.

Open it, check the rings, press **Refresh All**. That's the whole weekly routine.

## Download

Get `Sideport-<version>.zip` from [Releases](../../releases/latest), unzip it and move `Sideport.app` to Applications. It runs on macOS 13 or later, on Apple silicon and Intel.

Sideport isn't notarized, so macOS blocks it the first time. Right-click the app and choose **Open**, or on macOS 15 and later open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. You can also run:

```
xattr -dr com.apple.quarantine /Applications/Sideport.app
```

You need your phone connected by USB the first time so it can be paired. After that it also works over Wi-Fi if you've turned on "Show this iPhone when on Wi-Fi" in Finder. Developer Mode has to be on (Settings → Privacy & Security → Developer Mode), which iOS asks for after the first install.

Your Apple ID password only goes to Apple. Sideport stores the login token and signing key in `~/Library/Application Support/Sideport` on your Mac. Using a spare Apple ID for sideloading is a good idea anyway.

## What it does

- **Library of your apps.** Every app you've sideloaded, with a ring showing how many of its 7 days are left. Expired and nearly-expired apps sort to the top.
- **Refresh All** (⇧⌘R) re-signs and reinstalls everything on the connected phone, one after another. **Refresh What's Due** (⌘R) only does the ones running out or with a new IPA.
- **Keeps your app data.** A refresh reuses the bundle ID already on the phone, so the app is replaced in place and keeps its saves.
- **Automatic refresh.** With the phone connected (USB or Wi-Fi) and Sideport running (it stays in the menu bar), apps under 2 days left are refreshed on their own. You get a notification when one is about to expire.
- **New builds.** IPAs in `~/IPAs` that aren't in the library show up for one-click adding, and an app whose IPA changed gets a "New build" badge.
- **Customise each app**, saved and repeated on every refresh:
  - name, icon (drop any image on the preview), bundle ID, version
  - remove device restrictions, lower or set the minimum iOS, 120 Hz ProMotion, Game Mode, iPad full screen, Liquid Glass, remove URL schemes
  - show the app's documents in the Files app
  - remove app extensions and the Watch app (each one costs a free account an App ID)
  - inject tweaks (.deb, .dylib, .framework) with ElleKit, replace files inside the app
- **Signing:** your Apple ID (free or paid), your own certificate and provisioning profile, or ad-hoc for TrollStore and jailbroken phones. Any of them can export a signed IPA instead of installing.
- **Apple ID page:** sign in with two-factor (device code or text message), see and delete App IDs, see and revoke certificates.
- **Devices page:** every connected phone, what's installed on it, and delete apps from it.
- **Moving from Sideloadly:** **Import from Sideloadly** brings in every app Sideloadly installed, with its custom name and bundle ID. Sideport signs with Sideloadly's existing certificate while it's still valid, so nothing gets revoked and apps you installed with Sideloadly keep working.
- Double-click an IPA in Finder, or drop it on the window or the Dock icon, to install it.

## Building

Needs Xcode (15 or later) and Rust (`brew install rust`).

```
./build.sh             # builds build/Sideport.app
./build.sh --install   # and copies it to ~/Applications
./build.sh --release   # universal build zipped for a release (needs rustup with both macOS targets)
```

`engine/` is the part that talks to Apple and the phone (Rust). `app/` is the Mac app (SwiftUI). The app runs the engine in the background and talks to it over stdin and stdout.

Sideport keeps its data in `~/Library/Application Support/Sideport`: the library, the activity log, your Apple ID login token and its signing key.

## Credits

The Apple ID login, developer account, signing and device code is [Impactor](https://github.com/claration/Impactor) by claration (MIT; its `plume_core` crate is MPL-2.0), which uses [idevice](https://github.com/jkcoxson/idevice) and a modified [apple-codesign](https://github.com/indygreg/apple-platform-rs). See `NOTICE`.

## License

MIT. See `LICENSE`. The libraries it uses keep their own licenses, listed in `NOTICE`.
