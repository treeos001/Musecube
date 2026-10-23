# Releasing Musecube

## Build
`./build_app.sh` → `build/Musecube.app` (includes Sparkle).

## Bundle ID
`com.shukuinan.musecube`. The entitlements do not grant a temporary exception to read another app's data.

## Display name
The app shows Musecube in every localization. `CFBundleDisplayName` and `CFBundleName` are Musecube in both `en.lproj` and `zh-Hans.lproj`, and the in-app strings use Musecube as well. The Chinese name 灵感盒 is a note in the docs only.

## Signing & notarization
`./build_app.sh` without `SIGN_IDENTITY` produces an ad-hoc signature. Do not distribute that build.

A shareable build is signed with Developer ID, notarized, and stapled. Release v0.1.1 (build 2) was signed, notarized, and stapled on 2026-10-22. Source newer than that build is not notarized. Sign, notarize, and staple again before the next release. Replace the download zip only after stapling. The zip is not committed.

- Identity: Developer ID Application: Your Name (TEAMID)
- Keychain profile: the notarytool profile on your Mac, for example `notarytool-profile`

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
ditto -c -k --norsrc --keepParent build/Musecube.app /tmp/Musecube-submit.zip
xcrun notarytool submit /tmp/Musecube-submit.zip --keychain-profile notarytool-profile --wait
xcrun stapler staple build/Musecube.app
# --norsrc avoids AppleDouble `._*` entries that break Gatekeeper after unzip
ditto -c -k --norsrc --keepParent build/Musecube.app Musecube.zip
```

## Feedback
`IssuesConfig.url` is `https://github.com/treeos001/Musecube/issues`. The Help menu, the store footer, and About open it in the system browser. The app does not record the click.

## Sparkle
The official build checks `https://raw.githubusercontent.com/treeos001/Musecube/main/appcast.xml`. Release zips are GitHub Release assets. Automatic checks stay off; “Check for Updates…” is the only request. A build without `SU_FEED_URL` and `SU_PUBLIC_ED_KEY` keeps the placeholders and does not contact the update server.

1. Get Sparkle's tools (after the first build they are in `.build-direct/artifacts/sparkle/Sparkle/bin/`, or download a Sparkle release).
2. Generate the EdDSA key pair once: `./bin/generate_keys --account musecube`. The private key stays in the login Keychain. Back it up offline. **Never commit the private key.**
3. Build the release with the feed URL and the public key:
   `SU_FEED_URL=https://raw.githubusercontent.com/treeos001/Musecube/main/appcast.xml SU_PUBLIC_ED_KEY=<public key> SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build_app.sh`
4. Sign, notarize and staple the app (see above). Zip it only after stapling. Run `./bin/generate_appcast --account musecube --download-url-prefix https://github.com/treeos001/Musecube/releases/download/<tag>/ <folder with the zip>`, commit `appcast.xml`, and upload the zip to that GitHub Release.
5. Sandbox note: `SUEnableInstallerLauncherService` is set; before the first real update, verify Sparkle's sandboxed installer flow (the entitlements may need the `-spks`/`-spki` mach-lookup exceptions described in Sparkle's sandboxing docs).
