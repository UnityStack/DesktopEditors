# Building on macOS

Building on macOS is a few separate steps: build `desktop-sdk` natively, stage
the result, apply branding/version, then build the Xcode project.
`build/macos/stage.sh` handles the staging step — overlaying the web payload
onto a built `desktop-sdk` tree and generating fonts/theme thumbnails. It does
**not** build `desktop-sdk` itself, and it does **not** run the Xcode build.

> New here? Read the **[build overview](../README.md)** first — it explains the
> three CI jobs, the common payload, vcpkg, and caching, none of which are
> repeated below.

## Prerequisites

- Xcode with the `Euro-Office-arm` scheme (`desktop-apps/macos/Euro-Office.xcodeproj`).
- **CMake**, **Ninja**, and **vcpkg** (bootstrapped) on `PATH`.
- Homebrew `autoconf`, `automake`, GNU `libtool` (not Apple's `/usr/bin/libtool`),
  and `pkg-config` — needed by vcpkg's `hunspell` port.
- The submodules checked out (see the [overview](../README.md#prerequisites-all-platforms)),
  including `core-fonts`.
- Docker, for building the [common payload](../README.md#the-common-payload-again)
  locally. Use `type=tar`, not the default `type=local` — `type=local` is known
  to hang indefinitely on Docker Desktop's macOS/virtiofs backend for this many
  small files (confirmed stuck, not just slow), and `type=tar` is also what CI
  already uses:
  ```bash
  docker buildx bake desktop-common --set desktop-common.output=type=tar,dest=./build/deploy/common.tar
  mkdir -p build/deploy/common && tar -xf build/deploy/common.tar -C build/deploy/common
  ```

## The steps

Set these once and reuse them across all the steps below:
```bash
REPO=/path/to/your/checkout
VCPKG=/path/to/vcpkg
EO_3RDPARTY=/path/to/3rdparty-cache
STAGE=/path/to/staging-root  # arbitrary, doesn't need to exist yet - step 1 creates it
```

1. **Build `desktop-sdk`** (the native `ascdocumentscore.framework`,
   `ooxmlsignature.framework`, the 3 `editors_helper*.app` bundles, `x2t`, and
   every converter — all one CMake project):
   ```bash
   cmake -S "${REPO}/desktop-sdk/ChromiumBasedEditors/lib" -B build-mac-sdk \
     -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_DESKTOP=1 \
     -DCMAKE_TOOLCHAIN_FILE="${VCPKG}/scripts/buildsystems/vcpkg.cmake" \
     -DVCPKG_TARGET_TRIPLET=arm64-osx \
     -DVCPKG_MANIFEST_MODE=ON \
     -DVCPKG_MANIFEST_DIR="${REPO}/core" \
     -DEO_CORE_3RD_PARTY_DIR="${EO_3RDPARTY}" \
     -DEO_CORE_OUTPUT_DIR="${STAGE}/converter"

   cmake --build build-mac-sdk
   ```
   First run fetches boost/openssl/icu/v8/cef via `build_3rdparty.py` —
   expect this to take a while and need several GB free. Confirm it worked:
   `${STAGE}/ascdocumentscore.framework`, `${STAGE}/ooxmlsignature.framework`,
   `${STAGE}/editors_helper.app` (+ GPU/Renderer variants), and
   `${STAGE}/converter/x2t` should all exist.
2. **Stage it** — this is what `stage.sh` automates:
   ```bash
   "${REPO}/build/macos/stage.sh" \
     --stage-dir "${STAGE}" \
     --3rdparty-dir "${EO_3RDPARTY}"
   ```
   (`--payload-dir` and `--core-fonts-dir` default to `build/deploy/common` and
   `core-fonts` under the repo root — override with flags or the matching env
   vars if yours live elsewhere.)
3. **Apply branding/version** — patches the committed `Info.plist` in place
   with the company/product name and version to actually ship. Run this every
   time: the committed file is just whatever was last checked in, and nothing
   else keeps it in sync, so don't rely on it already being correct.
   ```bash
   "${REPO}/desktop-apps/macos/apply-branding.sh" \
     --company-name Euro-Office \
     --product-name Euro-Office \
     --version "$(cat "${REPO}/VERSION.txt")"
   ```
   This is exactly what CI's own "Apply branding" step in `build-macos` runs
   before `xcodebuild` — patches `NSHumanReadableCopyright`/`CFBundleName`/
   `CFBundleShortVersionString`. Use different `--company-name`/`--product-name`
   values to build a different brand (e.g. nextcloud-office).
4. **Build the Xcode project**, pointed at the staged tree:
   ```bash
   xcodebuild -project "${REPO}/desktop-apps/macos/Euro-Office.xcodeproj" \
     -scheme Euro-Office-arm -configuration Release \
     EO_MAC_STAGE_DIR="${STAGE}" \
     CONFIGURATION_BUILD_DIR="${REPO}/build/macos/out" \
     build
   ```
   `Euro-Office.app` lands directly at `${REPO}/build/macos/out/Euro-Office.app` —
   without `CONFIGURATION_BUILD_DIR`, Xcode uses its default DerivedData
   location instead (`~/Library/Developer/Xcode/DerivedData/Euro-Office-<hash>/Build/Products/<configuration>/`).
5. **(Optional) Package a DMG installer** — `make-dmg.sh` packages the built
   `.app` into a distributable `.dmg` (app + `/Applications` symlink,
   background graphic), using [`appdmg`](https://github.com/LinusU/node-appdmg)
   and the config/assets in `desktop-apps/macos/fastlane/resources/`. Needs
   Node/npm on `PATH` (not required for steps 1-4) — CI's macOS runners have
   it by default.
   ```bash
   "${REPO}/build/macos/make-dmg.sh" \
     --app "${REPO}/build/macos/out/Euro-Office.app" \
     --output "${REPO}/build/macos/out/Euro-Office-DesktopEditors-9.3.5-1-macos-arm64.dmg"
   ```

## What `stage.sh` does

In order: merge the CMake build's `package/` output into `converter/` → merge
the web payload (`index.html`, `editors/`, `fonts/`, `providers/`, plus
`converter/`'s extra config/locale files) → build `allfontsgen`/`allthemesgen`
standalone (they're not part of the `desktop-sdk` build; rebuilt fresh every
run, ~1-2 minutes, so they're always current against whatever native code
changed) → run `allfontsgen` (native + web `AllFonts.js`, `font_selection.bin`)
→ run `allthemesgen` (slide-theme thumbnails) → delete both generator
binaries from `converter/` so they don't ship.

Mirrors the equivalent sequence in Linux's
`desktop-apps/.docker/desktop-apps.bake.Dockerfile` and Windows'
`build.ps1` (step 9/9b) — **matching Windows' version specifically**, not
Linux's: Windows passes `--allfonts-web=`/`--output-web=` to `allfontsgen`,
Linux's Dockerfile doesn't. Omitting them silently drops the web `AllFonts.js`
that `doctrenderer` needs, which then makes `allthemesgen` fault — Windows'
own comment documents this exact gotcha, and it's why this script follows
Windows' fuller flag set.

## Good to know

- **Verifies real output, not just exit codes.** `allfontsgen` can exit `0`
  while writing essentially nothing — a real failure mode, not a theoretical
  one. The script checks file sizes, not just existence or exit status, to
  catch that class of failure.
- **Safe to re-run.** Each run fully replaces `editors/`, `fonts/`, and
  `providers/` from the payload dir and regenerates the font/theme data from
  scratch, so stale content from a previous run doesn't linger.
- **`--stage-dir` must already have a built `package/`.** The script fails
  fast with a clear message if it doesn't, rather than staging a broken tree.

## Signing and notarization

On tag builds CI ships a DMG that is signed with UnityStack GmbH's
Developer ID Application certificate and notarized by Apple, so Gatekeeper
opens it without a warning. The app keeps the upstream Euro-Office brand and
bundle ID (`asc.euro-office.Euro-Office`); only the signature is ours.
Branch and PR builds stay unsigned.

### What CI does

On a tag, `build-macos` uploads its DMG as `macos-unsigned-euro-office-arm64`
instead of `macos-packages-...`, and the `sign-macos` job in
`.github/workflows/build.yml` runs `build/macos/sign.sh` on it:

1. imports the certificate from `APPLE_DEVELOPER_ID_P12` into a new
   keychain under `$RUNNER_TEMP`, together with Apple's Developer ID G2
   intermediate (`DeveloperIDG2CA.pem`), puts that keychain on the keychain
   search list for the run and checks that it holds one valid
   `Developer ID Application` identity of team `APPLE_TEAM_ID` (only with
   `GITHUB_ACTIONS=true`; see [Running it locally](#running-it-locally-without-a-certificate)),
2. unpacks the DMG, writes the update settings into the app's `Info.plist`
   (`sparkle-configure.sh`, see [Automatic updates](#automatic-updates-sparkle))
   and creates the script caches (see [Script caches](#script-caches)),
3. signs every Mach-O inside-out with the hardened runtime, a secure
   timestamp and the entitlements in `entitlements/`: the loose libraries and
   executables (the `converter/` dylibs and `x2t`, the helpers' `MacOS/system`
   copies, the CEF libraries, Sparkle's `Autoupdate`), then the nested
   bundles deepest first (frameworks, the three helpers, Sparkle's XPC
   services and `Updater.app`), then the app; it fails on an executable that
   has no entitlements decision yet,
4. checks the result: `codesign --verify --deep --strict`, and for each
   Mach-O the hardened runtime flag, the signer, the timestamp, the team and
   that `get-task-allow` is absent,
5. runs a smoke test (`--smoke-test`): the signed `x2t` converts a document to
   PDF, the app opens that document and must still run after 20 s and have
   started a renderer process, no process of the app may crash, it may not
   write to a keychain, and no file in the bundle may change (a SHA-256
   manifest before and after); see [Smoke test](#smoke-test),
6. notarizes the app (`xcrun notarytool submit --wait`, App Store Connect API
   key) and staples it,
7. builds the DMG again from the signed app with the original layout
   (`/Applications` link, background, window settings from `.DS_Store`),
   signs it, notarizes and staples it,
8. mounts the result and checks it like a user's Mac would:
   `spctl --assess --type execute` on the app,
   `spctl --assess --type open --context context:primary-signature` on the
   DMG, `xcrun stapler validate` on both.

The job then names the DMG like the release asset GitHub makes of it, writes
`SHA256SUMS-macos-arm64.txt` and uploads both as
`macos-packages-euro-office-arm64`, which `publish-release` attaches to the
release. It also signs that DMG for Sparkle and uploads the update
description as `macos-update-euro-office-arm64` (see
[Automatic updates](#automatic-updates-sparkle)). If `sign-macos` fails or
is skipped, `publish-release` does not run. On every exit, cancelled runs included, the script puts the previous
keychain search list back and deletes the keychain
(`$RUNNER_TEMP/eo-signing-keychain.*`) and its work directory
(`$RUNNER_TEMP/macos-signing`, which holds the decoded API key); an
`always()` step deletes both again if the script was killed before it could.

### Smoke test

The app runs as a new instance (`open -n`) with its own home in the work
directory (`HOME` and `CFFIXED_USER_HOME`), so its data stays out of the real
home. Its preferences do not (NSUserDefaults ignore `CFFIXED_USER_HOME`): they
are those of the bundle ID, which an installed Euro-Office shares, so the test
refuses to run while a `Euro-Office` process runs, exports them first and puts
them back exactly afterwards, also when the test fails, and turns Sparkle's
update check off for the launch. In the test home the Security framework
finds no keychain, and a
write to the default keychain makes macOS ask to create a login keychain
("Keychain Not Found"). Two things in the app write there on a first start,
and the test keeps both away from any keychain:

- Chromium's "Safe Storage" key: the app already passes `--use-mock-keychain`
  to CEF (`desktop-sdk/.../cefwrapper/client_app.h`); the test passes it too.
- desktop-sdk's crypto key (`NSAscCrypto::CAscKeychain::Check`), which is
  added to the default keychain whenever `<app data>/data/user.data` is
  missing: the test writes an empty `user.data` (header only), so the app only
  looks the key up.

Afterwards the test reads the unified log for the PIDs of the app and fails
on any keychain write, through the old API (`SecKeychainAddGenericPassword`
and the like) or the new one (`SecItemAdd`, `SecItemUpdate`, `SecItemDelete`),
or on a request to create a login keychain (authd's
`system.keychain.create.loginkc`, for the app or one of its helpers). On early exit it prints launchd's
termination record for the app (signal or exit status). It stops every
process of the bundle (TERM, then KILL) on every exit path and removes the
copy from Launch Services.

### Entitlements

Each executable gets only what it was shown to need under the hardened
runtime (tested by removing each one: the process is killed or never
starts):

| Executable | Entitlements | Why |
|---|---|---|
| `Euro-Office` (main app) | `allow-jit`, `allow-unsigned-executable-memory` | Runs Chromium's V8 (`MAP_JIT` code pages) and doctrenderer's V8 from `libdoctrenderer`, which writes code into ordinary memory. Without either, the app starts but never creates a renderer. |
| `editors_helper (Renderer)` | `allow-jit`, `allow-unsigned-executable-memory` | The same two V8s: the web editors and their native part (`ascdocumentscore`, `libdoctrenderer` from `MacOS/system`). Without either, the renderer crashes or never starts. |
| `editors_helper (GPU)` | none | No JIT; ran with none. |
| `editors_helper` (utility processes) | none | No JIT; ran with none. |
| `converter/x2t` | `allow-unsigned-executable-memory` | doctrenderer's V8 (PDF and image output, script caches). Without it the kernel kills `x2t` (`CODESIGNING`, `Invalid Page`); `allow-jit` alone does not help. |
| Sparkle (`Autoupdate`, `Updater.app`, XPC services) | none | As Sparkle's documentation describes for apps that are not sandboxed. |

Left out on purpose, although upstream's
`desktop-apps/macos/.../Euro-Office.entitlements` has them:
`get-task-allow` (lets any process attach a debugger; notarization refuses
it), `allow-dyld-environment-variables` (nothing sets `DYLD_*`) and
`disable-library-validation` (every library in the bundle carries our team
ID, so library validation passes; it only matters for code from other
teams). If a future build loads a library signed by someone else, the smoke
test fails with "different Team IDs" and the library, not the entitlement,
is what to fix.

Camera and microphone (`com.apple.security.device.camera`,
`com.apple.security.device.audio-input`) are not granted either, although
the app's `Info.plist` has `NSCameraUsageDescription` and
`NSMicrophoneUsageDescription` (upstream's, in `desktop-apps`). No document tab
can reach a camera or microphone today: the app's CEF client
(`CAscClientHandler` in desktop-sdk's `cefview.cpp`) inherits
`OnRequestMediaAccessPermission` from CEF's sample `client::ClientHandler`,
which answers every `getUserMedia` request with `CEF_MEDIA_PERMISSION_NONE`
while `media_handling_disabled_` is `true`. That is its default, and only a
debug context menu entry that the app's own `OnBeforeContextMenu` never adds
turns it off. So Chromium refuses the request before macOS is asked, with or
without the entitlements. If a later desktop-sdk grants media access, add both
keys to `app.entitlements` (where Chromium's own `app-entitlements.plist` puts
them) and test `getUserMedia` in a document tab of a notarized build; without
them the hardened runtime denies the devices without a prompt.

### Script caches

`x2t` (doctrenderer) compiles `editors/sdkjs/<editor>/sdk-all.js` on first use
and writes the V8 code cache next to it, as `sdk-all.cache` inside the app
bundle. A signed bundle that gains files no longer verifies ("a sealed
resource is missing or invalid": Nextcloud Office shows this after its first
conversions). `sign.sh` therefore runs upstream's `x2t -create-js-cache`
before signing whenever one of the caches it writes is missing, and fails if
one is still missing afterwards: `word`, `cell`, `slide`, `pdf` (built from
`word/sdk-all.js` and `pdf/src`, so `pdf/` has a cache but no `sdk-all.js`)
and `visio` (when `visio/sdk-all-min.js` exists), each
`editors/sdkjs/<editor>/sdk-all.cache`. rc.1, for example, ships only
`slide/sdk-all.cache` from the build. doctrenderer only writes a cache that does not
exist, so the bundle stays as signed; the smoke test checks that. No
submodule is changed for this.

### One-time setup (Account Holder)

Only the Account Holder of the UnityStack GmbH team can create a Developer ID
certificate. The private key is created on your Mac and never leaves it
except inside the password-protected `.p12` that goes into the GitHub secret.

1. **Certificate signing request.** Keychain Access → Keychain Access menu →
   Certificate Assistant → *Request a Certificate From a Certificate
   Authority*: your email, common name `UnityStack GmbH`, *Saved to disk*.
   This creates the key pair in your login keychain and a `.certSigningRequest`
   file.
2. **Certificate.** [developer.apple.com/account](https://developer.apple.com/account)
   → Certificates, Identifiers & Profiles → Certificates → **+** →
   *Developer ID Application* → Profile Type **G2 Sub-CA** (the previous
   Sub-CA expires on 1 February 2027) → upload the request → download
   `developerID_application.cer` and double-click it. Keychain Access → My
   Certificates now shows *Developer ID Application: UnityStack GmbH
   (TEAMID)* with its private key underneath.
3. **Export.** Right-click that entry (the certificate, not the key) →
   *Export* → format *Personal Information Exchange (.p12)* → a strong
   password. Keep the `.p12` and its password in the company password
   manager; it is also the backup of the key.
4. **Team ID.** developer.apple.com/account → Membership details → Team ID
   (10 characters; also in the certificate name).
5. **API key for notarytool.** [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api)
   → Users and Access → Integrations → App Store Connect API → *Team Keys* →
   **+**: name `GitHub notarization`, access **Developer** (enough for
   `notarytool`; Admin is not needed). Download `AuthKey_<KEYID>.p8` (only
   possible once) and note the Key ID and the Issuer ID shown above the list.
   It has to be a Team key: `sign.sh` always passes `--issuer`, which
   `notarytool` accepts only with a Team key (an *Individual* key would need
   the call without it).
6. **Check locally (optional).** With the certificate in your login keychain:
   ```bash
   xcrun notarytool history --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-ID>
   gh release download v9.3.6-ce.rc.1 -R UnityStack/DesktopEditors -p '*macos*' -D /tmp/eo/in --skip-existing
   APPLE_API_KEY_ID=<KEYID> APPLE_API_ISSUER_ID=<ISSUER-ID> \
   APPLE_API_KEY_P8="$(cat AuthKey_<KEYID>.p8)" APPLE_TEAM_ID=<TEAMID> \
     build/macos/sign.sh --input /tmp/eo/in/*.dmg --output /tmp/eo/out/signed.dmg \
       --identity "Developer ID Application: UnityStack GmbH (<TEAMID>)" --smoke-test
   ```
   This submits to Apple's notary service like CI does (two submissions,
   usually a few minutes each). The smoke test opens a window for 20 s to
   about a minute. `--identity` takes a certificate from the keychain search
   list; if `security find-identity -v -p codesigning` does not list it as
   valid, double-click `build/macos/DeveloperIDG2CA.pem` to add Apple's
   intermediate.
7. **Secrets.** In the GitHub environment `signing` of
   `UnityStack/DesktopEditors` (the one `sign-windows` and `sign-linux` use).
   The second command prompts for the `.p12` password, so it does not end up
   in the shell history:
   ```bash
   R=UnityStack/DesktopEditors
   base64 -i DeveloperID.p12 | gh secret set APPLE_DEVELOPER_ID_P12 --env signing -R "$R"
   gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD --env signing -R "$R"
   gh secret set APPLE_TEAM_ID --env signing -R "$R" --body '<TEAMID>'
   gh secret set APPLE_API_KEY_ID --env signing -R "$R" --body '<KEYID>'
   gh secret set APPLE_API_ISSUER_ID --env signing -R "$R" --body '<ISSUER-ID>'
   gh secret set APPLE_API_KEY_P8 --env signing -R "$R" < AuthKey_<KEYID>.p8
   ```
   Then delete the `.p12` and `.p8` copies you no longer need from disk.
8. **Test with a tag.** Push a prerelease tag (for example the next
   `v9.3.6-ce.rc.N`). `sign-macos` runs after `build-macos`; its log shows the
   identity, every signed file, the smoke test, both notarization results
   with Apple's log, and the `spctl` and `stapler` checks. On a Mac, download
   the DMG from the release and check it:
   ```bash
   spctl --assess --type open --context context:primary-signature -vv Euro-Office-*.dmg
   xcrun stapler validate Euro-Office-*.dmg
   ```

A missing secret fails `sign-macos` with the names of all missing secrets; a
wrong password, a certificate of another team, an Apple Development or an
expired certificate fail with their own message before anything is signed.

### Running it locally without a certificate

`--identity -` signs ad hoc, which needs `--no-notarize`. Ad hoc code has no
team ID, so library validation rejects every library; for a local test use a
copy of `entitlements/` with `com.apple.security.cs.disable-library-validation`
added to each file and pass it with `--entitlements-dir`. Everything else
(inside-out signing, the checks, the smoke test, the DMG) runs as in CI:

```bash
gh release download v9.3.6-ce.rc.1 -R UnityStack/DesktopEditors -p '*macos*' -D /tmp/eo/in --skip-existing
rm -rf /tmp/eo/ent-adhoc
cp -R build/macos/entitlements /tmp/eo/ent-adhoc
for f in /tmp/eo/ent-adhoc/*.entitlements; do
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$f"
done
build/macos/sign.sh --input /tmp/eo/in/*.dmg --output /tmp/eo/out/adhoc.dmg \
  --identity - --no-notarize --entitlements-dir /tmp/eo/ent-adhoc --smoke-test
```

`/tmp/eo/in` holds only the downloaded DMG and the signed DMGs go to
`/tmp/eo/out`, so `/tmp/eo/in/*.dmg` stays one file on the next run.

Without `--identity` the script imports `APPLE_DEVELOPER_ID_P12` into a
temporary keychain, which changes the keychain search list for the run. It
does that only on GitHub Actions (`GITHUB_ACTIONS=true`) and otherwise stops
before it creates or reads anything; on a Mac, sign with an identity that is
already in your keychains (`--identity`, see step 6 above).

## Automatic updates (Sparkle)

Tag builds update themselves: the app reads an appcast (an RSS feed) about
once a day, and when it lists a newer build, Sparkle offers it, downloads
the signed and notarized DMG from the GitHub release and replaces the app.
Linux gets its updates from the package repositories instead
([build/linux/README.md](../linux/README.md#package-repositories)).

### The app

The app bundles Sparkle 2.0.0 (`desktop-apps/macos/Vendor/Sparkle`, with
its `sign_update`, `generate_keys` and `generate_appcast`). `Main.storyboard`
creates an `SUUpdater` (Sparkle 1's interface, kept by Sparkle 2) without a
delegate, and nothing in the app sets a feed at run time. Upstream's
`Info.plist` has `SUEnableAutomaticChecks` false,
`SUScheduledCheckInterval` 86400 (one day) and no feed or key, so it never
checks. Before signing, `sign.sh` (`--update-feed`, `--update-key`,
`--bundle-version`) runs `sparkle-configure.sh`, which writes into the
app's `Info.plist`:

| Key | Value |
|---|---|
| `SUFeedURL` | the stable or the testing appcast (below) |
| `SUPublicEDKey` | `build/macos/sparkle-ed25519.pub`, the public EdDSA key |
| `SUEnableAutomaticChecks` | `true`; with the key in `Info.plist` Sparkle does not ask the user first |
| `CFBundleVersion` | the tag's build number (below) |

The submodule is not changed; the signature covers the result. In CI the
three options are required: without them, or with only some, `sign.sh`
fails before it signs anything, and so does a missing
`sparkle-ed25519.pub`. Branch and PR builds are not signed and keep
upstream's settings, so they do not update.

Not possible without a change in desktop-apps:

- The *Check for Updates…* item of the app menu is `hidden` in
  `Main.storyboard` and the app never shows it, so users cannot check by
  hand; the daily check is the only one.
- Sparkle 2.0.0 is older than 2.7.2, which fixes CVE-2025-10015 and
  CVE-2025-10016 (local privilege escalation through Sparkle's
  `Downloader` XPC service and its `Autoupdate` installer). Both ship in the
  bundle already; automatic updates make the installer run. Updating
  Sparkle means updating `desktop-apps/macos/Vendor/Sparkle`.

### Versions

Sparkle offers an item only when its `sparkle:version` is above the
running app's `CFBundleVersion`. Upstream's is a fixed build number (544 in
v9.3.6-ce.rc.1, the same for every build), so `appcast.py bundle-version`
derives one integer from the tag: the digits `X YY ZZ S NNN` for `vX.Y.Z`,
stage `S` (1 alpha, 2 beta, 3 rc, 5 final) and number `NNN` (the `N` of
`rc.N`, or of a rebuild `-ce.N`, 0 for the final):

| Tag | `CFBundleVersion` |
|---|---|
| `v9.3.6-ce.rc.2` | 903063002 |
| `v9.3.6-ce` | 903065000 |
| `v9.3.6-ce.1` | 903065001 |
| `v9.3.7-ce.rc.1` | 903073001 |

Within the CE tags that orders like the package versions
(`0~ce~rc.2 < 0~ce < 0~ce.1`). `X` up to 20, `Y` and `Z` up to 99 and
`N` up to 999 fit (below 2^31). Only CE tags (`vX.Y.Z-ce`, `-ce.N`,
`-ce.rc.N`, beta and alpha like rc) get macOS updates: the upstream formats
the version job also accepts (`vX.Y.Z`, `vX.Y.Z-N`, `vX.Y.Z-rc.N`) would get
the number of a CE tag (`v9.3.6` and `v9.3.6-ce` are both 903065000), so
`sign-macos` fails on them in its first steps, and so does a tag outside the
limits. `CFBundleShortVersionString` stays `9.3.6`
(`apply-branding.sh`); when both short versions are the same, Sparkle adds
the build numbers ("9.3.6 (903065000)", you have "9.3.6 (903063002)"). The
About dialog shows `CFBundleVersion` too, after a click on its version line.
v9.3.6-ce.rc.1 has no feed and cannot update itself: its testers install
the next build once by hand.

### Feeds and channels

| Feed | Items | Read by |
|---|---|---|
| `https://packages.unitystack.eu/euro-office/macos/appcast.xml` | stable releases | apps from stable tags (`v9.3.6-ce`, `v9.3.6-ce.1`) |
| `https://packages.unitystack.eu/euro-office/macos/appcast-testing.xml` | stable and prerelease | apps from prerelease tags (`-ce.rc.N`, `-ce.beta.N`, `-ce.alpha.N`) |

Like the Linux channels (`release-info` decides): a tester's rc build moves
to newer rcs and to the final, and the final reads the stable feed from
then on. Two feeds rather than Sparkle's `sparkle:channel` because the app
cannot opt in to a channel: that needs `allowedChannelsForUpdater:` of a
`SPUUpdaterDelegate`, and the storyboard's `SUUpdater` has no delegate.
Each feed keeps the newest 10 items (`KEEP` of `publish-repo.sh`), newest
first. An item carries `sparkle:version`, `sparkle:shortVersionString`,
`sparkle:minimumSystemVersion` (`LSMinimumSystemVersion` of the app, 11.0),
the release page as `link`, the release notes as GitHub renders them
(`description`, which Sparkle shows) and the enclosure: the URL of the
release asset, its length and `sparkle:edSignature`.

The feeds live in the `packages` branch next to the Linux repositories
(`macos/`), written by `publish-repo.sh` with `appcast.py`, which keeps one
fragment per release in `.state/macos/<tag>.json` and writes both feeds
from them on every run, like the repository indexes. nginx serves them
below `/euro-office/` like every other file of the branch; the DMG itself is
downloaded from GitHub Releases.

### What CI does

1. `sign-macos` first computes the tag's `CFBundleVersion` (`appcast.py
   bundle-version`, which refuses a tag that is not a CE tag) and checks
   `SPARKLE_ED_PRIVATE_KEY` against `sparkle-ed25519.pub` (`appcast.py
   check-key`), then signs the app with the update settings, notarizes and
   staples.
2. On the final DMG, under its release asset name, `sparkle-sign.sh`
   writes the key to a mode 600 file under `$RUNNER_TEMP/sparkle-sign.*`,
   runs Sparkle's own `sign_update -f` (from the desktop-apps commit the tag
   pins; the key never goes on a command line, and without `-f` the tool
   would read the login keychain), deletes the file, verifies the signature
   with an independent Ed25519 implementation (`appcast.py`, RFC 8032)
   against the committed public key, checks the app's `Info.plist`
   (`SUPublicEDKey` is the committed key, `CFBundleVersion` the tag's, an
   https `SUFeedURL`, `SUEnableAutomaticChecks` true) and writes
   `sparkle-update-macos-arm64.json`, uploaded as
   `macos-update-euro-office-arm64` (not a release asset).
3. `publish-repo`, after `publish-release`, downloads the DMG from the
   release and its notes, and `appcast.py publish` checks that the release
   asset has the length, SHA-256 and signature of the description and that
   the app reads the feed of the tag's channel, then adds the item and
   rewrites both feeds. A re-run keeps the item's date while the DMG is the
   same. A second tag with the same `CFBundleVersion` is refused.
4. The job checks that the feeds parse and list the tag's signature, then
   pushes with the Linux repositories.

### One-time setup (key)

One EdDSA (Ed25519) key pair signs every update. Every installed app
checks updates against the public key it was built with, so the private key
must not leak, and losing it costs a key change (below). `sign_update` of
the bundled Sparkle 2.0.0 reads only one key format: 96 bytes, 128 base64
characters, what its `generate_keys -x` exports; later versions of
`generate_keys` export a 32-byte seed, which it refuses.

`appcast.py generate` makes the key pair in that format, from
`os.urandom`, without a keychain. Do not use `generate_keys`: it keeps one
Sparkle key per macOS user in the login keychain (service
`https://sparkle-project.org`, no option to choose another), and when one
is already there, from any other app, it prints that key ("A pre-existing
signing key was found") instead of making a new one.

1. **Create it** on your Mac. The private key goes to a file outside any
   repository (`generate` refuses a path inside a git work tree and an
   existing file, and creates it with mode 600); the public key goes into
   the checkout:
   ```bash
   python3 -I build/macos/appcast.py generate --private-out ~/sparkle-private.key \
     --public-out build/macos/sparkle-ed25519.pub
   python3 -I build/macos/appcast.py check-key --public-key build/macos/sparkle-ed25519.pub \
     --private-key-file ~/sparkle-private.key
   ```
2. **Back it up**: the contents of `~/sparkle-private.key` go into the
   company password manager, next to the Developer ID `.p12`.
3. **Secret**, in the environment `signing`:
   ```bash
   gh secret set SPARKLE_ED_PRIVATE_KEY --env signing -R UnityStack/DesktopEditors < ~/sparkle-private.key
   ```
   Then delete `~/sparkle-private.key`. To sign by hand later, take the key
   from the password manager into a mode 600 file and pass it to
   `sign_update -f`; no keychain is needed.
4. **Commit** `build/macos/sparkle-ed25519.pub` (one line, the public
   key). Until it is in the tag, `sign-macos` fails.
5. **Test with a prerelease tag**: the job log shows the check of the key,
   the `Info.plist` values and the verified signature; the testing feed
   lists the tag after `publish-repo`. A Mac with that build installed is
   offered the next prerelease within a day of its publication
   (`SUScheduledCheckInterval`).

### Changing the key

The bundled Sparkle 2.0.0 checks a DMG update after unpacking it
(`mustValidateBeforeExtraction` is `NO` in
`Autoupdate/SUDiskImageUnarchiver.m`), in `validateUpdateForHost` of
`Sparkle/SUUpdateValidator.m`. It installs the new app if either holds:

- the DMG's EdDSA signature verifies with the *installed* app's
  `SUPublicEDKey`; or
- the new app meets the installed app's designated requirement
  (`Autoupdate/SUCodeSigningVerifier.m`) *and* the DMG's signature
  verifies with the *new* app's `SUPublicEDKey`.

The designated requirement of a Developer ID app names the bundle
identifier and the team ID, not the certificate. So:

- **Renewing the Developer ID certificate** (it expires; a new `.p12` in
  `APPLE_DEVELOPER_ID_P12`) within the same team passes both checks and
  needs nothing else.
- **A new EdDSA key**, also **after losing the old one**, passes the second
  check: keep the Developer ID team, delete `sparkle-ed25519.pub`
  (`generate` does not overwrite it), make a key pair as in the one-time
  setup, and in one release commit the new `sparkle-ed25519.pub` and set
  the new `SPARKLE_ED_PRIVATE_KEY`. The scripts need no change; they
  already require that the secret, `sparkle-ed25519.pub` and the app's
  `SUPublicEDKey` are one key.
- **Never change the EdDSA key and the Developer ID team in the same
  release**: neither check passes, and installed apps refuse the update, so
  users have to install it by hand. A change of team needs one release with
  an unchanged key first.
- **If the private key leaked**, an attacker who can also put a DMG into a
  feed the apps read (the `packages` branch, or `packages.unitystack.eu`
  itself) passes the first check without our Developer ID signature. Change
  to a new key as above at once; apps that have not installed that release
  yet still accept the old key.

### Testing locally with a throwaway key

Nothing here touches a keychain: `appcast.py test-key` makes a key pair
like `generate` (it may overwrite the public key file), and `sign_update`
reads the key from the file. Do not run `generate_keys`. With the ad hoc
setup from [Running it locally](#running-it-locally-without-a-certificate):

```bash
T=/tmp/eo/sparkle; mkdir -p "$T"
python3 -I build/macos/appcast.py test-key --private-out "$T/test.key" --public-out "$T/test.pub"
build/macos/sign.sh --input /tmp/eo/in/*.dmg --output /tmp/eo/out/Euro-Office-test.dmg \
  --identity - --no-notarize --entitlements-dir /tmp/eo/ent-adhoc \
  --update-feed https://packages.unitystack.eu/euro-office/macos/appcast-testing.xml \
  --update-key "$T/test.pub" \
  --bundle-version "$(python3 -I build/macos/appcast.py bundle-version v9.3.6-ce.rc.2)"
build/macos/sparkle-sign.sh --dmg /tmp/eo/out/Euro-Office-test.dmg --tag v9.3.6-ce.rc.2 \
  --sign-update desktop-apps/macos/Vendor/Sparkle/bin/sign_update \
  --public-key "$T/test.pub" --private-key-file "$T/test.key" --out "$T/update.json"
python3 -I build/macos/appcast.py publish --update "$T/update.json" \
  --dmg /tmp/eo/out/Euro-Office-test.dmg --tag v9.3.6-ce.rc.2 --channel prerelease \
  --public-key "$T/test.pub" --state "$T/site/.state/macos" --out "$T/site/macos" \
  --base-url https://packages.unitystack.eu/euro-office
cat "$T/site/macos/appcast-testing.xml"
security find-generic-password -s https://sparkle-project.org   # "could not be found"
rm -rf "$T"
```

`appcast.py verify --public-key <file> --signature <sig> <dmg>` checks a
single signature. `sign.sh` without `--update-feed` (an ad hoc test as
above, without the three options) leaves the update settings as upstream
has them.
