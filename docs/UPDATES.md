# App updates

Cadence uses Sparkle 2. The menu bar provides **Check for Updates…** and
**Automatically Check for Updates**. Automatic checks are enabled by default;
installation requires the user's confirmation. Scheduled update reminders found
while locked are held until unlock.

The feed URL is a stable GitHub Releases asset URL:
https://github.com/niketdutta/Cadence/releases/latest/download/appcast.xml

## Prepare a release

1. Increase `CFBundleVersion` (an integer, currently `2`) and set
   `CFBundleShortVersionString` (currently `0.1.1`) in `Info.plist`.
2. Run `./make-update.sh` on the Mac with the signing key. This builds the app,
   creates `updates/Cadence-VERSION.zip`, and signs the entry in
   `updates/appcast.xml`. It does not publish anything.
3. Create a GitHub Release with the exact tag matching the short version
   (for example `0.1.1`, without a `v` prefix). Upload the versioned zip and
   `appcast.xml` to the same release. You can also upload `Cadence.dmg` from
   `./make-dmg.sh` for manual installation.
4. Keep attaching the updated `appcast.xml` to every subsequent latest release.
   Preserve the local `updates/` directory to retain previous feed entries.

The feed will return an error until the first release with `appcast.xml` is
published. Old versions without Sparkle require one manual installation.
Try update checks from an app copied to `/Applications`, not a mounted DMG.

## Signing key

The private EdDSA key is stored in the macOS Keychain under Sparkle's service
with account `dev.niket.cadence`. Only the public key is committed in
`Info.plist`. Keep a secure backup of the private key; do not regenerate it for
each release. Sparkle's `generate_keys --account dev.niket.cadence -x PATH`
can export a backup; keep that file outside the repository.

Build tools are downloaded through SwiftPM to
`.build/artifacts/sparkle/Sparkle/bin/`. `Package.resolved` pins the dependency.
`build.sh` embeds the original signed Sparkle framework and preserves symlinks.
Cadence itself is still ad-hoc signed, as before. Sparkle archive signing is
separate from Apple Developer ID signing and notarization.

## Verification

Before publishing, check the bundle and the generated feed:

```sh
codesign --verify --deep --strict --verbose=2 Cadence.app
plutil -lint Cadence.app/Contents/Info.plist
otool -L Cadence.app/Contents/MacOS/Cadence
```

Test a real update using two different bundle versions and a test feed before
announcing automatic updates. Include an update found while locked, declining
an update, disabling automatic checks, and relaunching after installation.
Never replace a published archive in place: its EdDSA signature covers its exact
contents. Publish a higher version instead.
