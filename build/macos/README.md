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
2. unpacks the DMG and creates the script caches (see
   [Script caches](#script-caches)),
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
release. If `sign-macos` fails or is skipped, `publish-release` does not run.
On every exit, cancelled runs included, the script puts the previous
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

### Not part of this

Automatic updates (Sparkle, whose framework the app already contains with
`SUEnableAutomaticChecks` off) are a later step: an appcast, an EdDSA key and
signed update archives.
