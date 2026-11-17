# Building on Windows

The Windows build is driven by **`build.ps1`**, a PowerShell script that sets up the toolchain environment,
configures and builds the native app with MSVC + CMake, overlays the common
editors payload, generates fonts and theme thumbnails, and packages the result
as a ZIP and an Inno Setup installer (optionally an MSI).

> New here? Read the **[build overview](../README.md)** first — it explains the
> three CI jobs, the common payload, vcpkg, and caching, none of which are
> repeated below.

## Prerequisites

- **Windows** with **Visual Studio 2022** including the C++ x64 toolset. The
  build additionally needs the **MSVC v141 toolset**, the **Windows 10 SDK
  (10.0.19041.0)**, and **ATL + MFC**. If you don't have those components,
  `build.ps1 -InstallDeps` can add them (see below).
- **Cygwin** (parts of the native build shell out to its `bash`/`make`/`sh`).
- **CMake**, **Ninja**, and native (non-Cygwin) **perl**, **python**, and **git**
  on `PATH`.
- For packaging: **Inno Setup 6.2.2** and **7-Zip**; for the optional MSI,
  **Advanced Installer**.
- *(Optional but recommended)* **sccache** on `PATH` for a compiler cache.
- The submodules checked out (see the [overview](../README.md#prerequisites-all-platforms)).

`-InstallDeps` can install most of this for you (Cygwin, the VS components, and
the packaging tools via Chocolatey). It mutates the host and writes into
`Program Files`, so run it from an **elevated** PowerShell. You only need it
once per machine — omit it on subsequent builds.

## Getting the common payload first

`build.ps1` compiles the *native* app but does **not** build the editors web
content — that's the [common payload](../README.md#the-common-payload-again)
from the Linux `build-common` job. Supply it one of three ways:

1. **Download the `common-files` CI artifact**, and point the script at
   it with `-CommonDir <path>`.
2. **Build it locally with Docker** (Linux containers) by passing `-BuildCommon`.
   Slow; only worth it if you can't grab the artifact.
3. **Place it at `.\common`** (the default location) and pass nothing.

The expected layout is:

```
<common>\index.html
<common>\editors\webext\noconnect.html
<common>\editors\...            (the full editors payload)
```

## Quick start

Run from the **repository root** (the script derives the root from its own
location, so it works regardless of your current directory):

```powershell
# Common content already at .\common, tools already installed:
.\build\windows\build.ps1

# Point at a downloaded CI artifact:
.\build\windows\build.ps1 -CommonDir C:\downloads\common-files

# First-time machine: install everything (run elevated) and build common via Docker:
.\build\windows\build.ps1 -InstallDeps -BuildCommon
```

## Parameters

| Parameter         | Purpose                                                                 | Default                |
| ----------------- | ----------------------------------------------------------------------- | ---------------------- |
| `-RepoRoot`       | Repository root                                                         | two levels up from the script |
| `-CommonDir`      | Folder holding the Linux-built common payload                          | `<RepoRoot>\common`    |
| `-BuildCommon`    | Build the common payload locally with Docker                           | off                    |
| `-InstallDeps`    | Install Cygwin, VS components, and packaging tools (admin; one-time)   | off                    |
| `-BuildMsi`       | Also build the MSI with Advanced Installer (needs a license)          | off                    |
| `-SkipPackaging`  | Build and install only; skip ZIP / installer steps                    | off                    |
| `-SigningBundle`  | Also write a tar for the signing server (see [Code signing](#code-signing)) | off           |
| `-ProductVersion`, `-BuildNumber`, `-CompanyName`, `-ProductName` | Version / branding | see [overview](../README.md#versioning-and-branding) |

## What the script does

In order: validate the repo layout → *(optional)* install dependencies →
resolve the common payload → set up a deterministic `PATH` (native tools ahead of
Cygwin) and import the MSVC environment → set up vcpkg → CMake configure (Ninja,
Release, vcpkg toolchain, sccache if present) → build → install → overlay the
common payload → generate fonts (`allfontsgen`) and theme thumbnails
(`allthemesgen`) → package (ZIP, Inno installer, optional MSI).

## Output

With packaging enabled (the default), artifacts land under
`desktop-apps\package\`:

- `...\zip\*.zip` — portable ZIP
- `...\inno\*.exe` — Inno Setup installer
- `...\advinst\*.msi` — MSI (only with `-BuildMsi`)

Use `-SkipPackaging` to stop after the install step; the unpackaged app tree is
then at `<RepoRoot>\desktopeditors`.

## Code signing

Which brand gets signed is set by `sign:` in the `build-windows` matrix. In
this fork that is **Euro-Office**, signed in CI on tag builds (see
[Signing in CI (fork)](#signing-in-ci-fork)); branch and PR builds stay
unsigned.

Upstream, the signing certificate lives on a separate signing server (in this
fork the `sign-windows` job takes its place). The installer must be built from
signed binaries and is itself signed, so for these brands CI builds no packages
at all and the server does all packaging:

1. For brands with `sign: true` (in this fork: on tag builds only), CI runs
   `build.ps1 -SkipPackaging -SigningBundle ...` and uploads `windows-signing-bundle-<brand>-<arch>`
   instead of `windows-packages-<brand>-<arch>`. It is a tar holding the install tree
   (`desktopeditors\`), the `desktop-apps` packaging scripts and Inno project,
   the VC++ redistributable, and a `signing-bundle.json` manifest (version, arch,
   target, names, commit).
2. On the signing server, **`sign-package.ps1`** downloads those artifacts with
   the GitHub CLI and, for each bundle, runs:
   - `make.ps1 -Sign`: stages the tree, signs every `.exe`/`.dll`, and
     regenerates the VLC plugin cache (it must be generated *after* signing)
   - `make_zip.ps1`: builds the ZIP from the signed tree
   - `make_inno.ps1 -Sign`: builds the installer; iscc signs the setup and the
     uninstaller

   It then checks every signature with `Get-AuthenticodeSignature` and copies
   the results to `-OutDir\<Company>-<arch>\` plus `SHA256SUMS.txt`.

Server requirements: Windows 10+, signtool (Windows SDK, found automatically),
Inno Setup 6, 7-Zip, and `gh` with read access to the repo's Actions artifacts
(`GH_TOKEN`). From this repo the server only needs `build\windows\` (a checkout
without submodules is enough). Everything else comes from the bundle, so it
matches the build.

```powershell
$env:GH_TOKEN = '<token with actions:read on Euro-Office/DesktopEditors>'

# Nextcloud Office (default -Brand), all arches, latest run for a release tag:
.\build\windows\sign-package.ps1 -Tag v9.3.1 -CertThumbprint <sha1>

# One arch of a specific run:
.\build\windows\sign-package.ps1 -RunId 1234567890 -Arch amd64 -CertName "<subject>"

# Bundle copied over by other means:
.\build\windows\sign-package.ps1 -BundlePath D:\incoming\ -CertThumbprint <sha1>
```

By default the certificate is picked from the Windows certificate store
(`-CertThumbprint` → `/sha1`, `-CertName` → `/n`, neither → `/a`), with SHA-256
digests and an RFC 3161 timestamp (`-TimestampServer`). For any other setup,
such as a dlib-based signer like Azure Trusted Signing, pass the full signtool
argument list with `-SignArgs`. It goes to both `make.ps1` and `make_inno.ps1`.

Keep `-WorkDir` short (default `%SystemDrive%\eo-sign`). The editors tree is
deeply nested and would otherwise run into the 260-character path limit.
Staging the Inno language files writes to the Inno install directory, so run
the script elevated, or run it once elevated to stage those files.

**VLC plugin cache:** if the build ships `vlc-cache-gen.exe`, `make.ps1`
regenerates the cache after signing and then removes the tool. It can only do
that on a host with the same architecture, so on an x64 server arm64 builds
keep the tool and have no cache (upstream behaves the same way).

### Signing in CI (fork)

On tag pushes the `sign-windows` job in `.github/workflows/build.yml` takes
the place of the signing server. Per arch it downloads
`windows-signing-bundle-euro-office-<arch>`, logs in to Azure with OIDC
(`azure/login`), installs the Artifact Signing client (NuGet
`Microsoft.ArtifactSigning.Client`) and runs `sign-package.ps1 -BundlePath
... -SignArgs /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256
/dlib <dlib> /dmdf <metadata.json>`. The signed ZIP, EXE and a
`SHA256SUMS-windows-<arch>.txt` are uploaded as
`windows-packages-euro-office-<arch>`, which `publish-release` attaches to the
GitHub release. The certificate is UnityStack GmbH's public-trust profile.

The job runs in the GitHub environment **`signing`** and needs:

- Secrets (repository or `signing` environment): `AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
- Variables (optional, defaults in the workflow `env`):
  `ARTIFACT_SIGNING_ENDPOINT` (`https://neu.codesigning.azure.net`),
  `ARTIFACT_SIGNING_ACCOUNT` (`unitystackcodesign`),
  `ARTIFACT_SIGNING_PROFILE` (`unitystack`).

One-time Azure setup:

1. An Entra ID app registration (its client ID is `AZURE_CLIENT_ID`) with a
   federated credential for GitHub Actions: repository
   `UnityStack/DesktopEditors`, entity type *Environment*, environment
   `signing`. The repository uses GitHub's immutable subject format, so the
   subject is
   `repo:UnityStack@206505972/DesktopEditors@1442484805:environment:signing`
   (organization ID 206505972, repository ID 1442484805).
2. The role **Artifact Signing Certificate Profile Signer** for that app on the
   `unitystack` certificate profile (or the `unitystackcodesign` account).
3. The `signing` environment in the GitHub repository settings, ideally
   restricted to tags (`v*`).

## Updates via winget

Windows users install and update the Community Edition with the Windows
Package Manager:

```powershell
winget install UnityStack.EuroOfficeCommunityEdition
winget upgrade UnityStack.EuroOfficeCommunityEdition
```

The manifests in [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs)
point at the signed installers on this repository's GitHub releases. For each
final release a pull request adds the new version there; winget offers it once
the winget-pkgs pipeline and moderators have merged it.

### What is published

- **Identifier `UnityStack.EuroOfficeCommunityEdition`**, publisher
  *UnityStack GmbH*, name *Euro-Office Community Edition*. The first segment
  names who builds and signs the package. `EuroOffice.DesktopEditors`
  (maintained by volunteers, not by the Euro-Office project; it installs the
  project's unsigned installers) and `ONLYOFFICE.DesktopEditors` belong to
  others. The description says that this is an unofficial community build, not
  affiliated with the Euro-Office project.
- **Final releases only.** A `vX.Y.Z-ce` tag becomes package version
  `X.Y.Z.0`. Release candidates (`-ce.rc.N`, `-ce.beta.N`, `-ce.alpha.N`) and
  rebuilds (`-ce.N`) are not published. Every build of `X.Y.Z` writes the same
  version, `X.Y.Z.0`, to *Apps & features* (`build.ps1` passes
  `$ProductVersion.0` to the Inno script as `AppVersion`), and winget tells
  installed versions apart only by that value. A release candidate in the
  package would be offered to every user, and a separate identifier for
  release candidates would match the same installed app. Testers take release
  candidates from GitHub Releases.
- **The *Apps & features* entry** comes from the Inno script in
  `desktop-apps/package/inno`, unchanged from upstream: publisher
  `Euro-Office`, display name `Euro-Office (Standalone) X.Y.Z (<arch>)`,
  version `X.Y.Z.0`, product code (AppId) `Euro-Office Desktop Editors_is1`.
  The installer manifest lists these under `AppsAndFeaturesEntries`, because
  the publisher and name differ from the manifest's. `komac analyze` reads the
  same values from the `v9.3.6-ce.rc.1` installers. Upstream's builds write the
  same entry, so the two builds replace each other when installed, and winget
  can match an installation it did not make itself to both packages.
- **Installer:** Inno Setup (`inno`), machine scope, elevates itself, x64 and
  arm64. winget's default Inno switches apply (`/SP- /VERYSILENT
  /SUPPRESSMSGBOXES /NORESTART` for a silent install).
- **Known limitation: a mismatched existing installation.** At start-up the
  upstream installer checks the installed product (`CheckInstalledProduct` in
  `desktop-apps/package/inno/_code.iss`). If the existing installation has
  another architecture, came from the MSI package, or is another edition, it
  shows an error dialog with `MsgBox` and exits with an error.
  `/SUPPRESSMSGBOXES` does not suppress such dialogs, so a silent
  `winget upgrade` waits on the dialog and then fails. The likely case is
  Windows on ARM with the x64 build installed from a download: winget did not
  install it, so it does not know its architecture and can choose the arm64
  installer. Upgrade such an installation with
  `winget upgrade --architecture x64 UnityStack.EuroOfficeCommunityEdition`,
  or uninstall it and install it again with winget. The fix belongs upstream
  (`SuppressibleMsgBox` in `desktop-apps`); the submodule is not patched here.

The manifests are rendered from the templates in `build/windows/winget/templates/`
by `build/windows/winget/render-manifests.sh`, which takes the installer URLs
and SHA-256 from the release (GitHub's digest of each `.exe`, which must match
the release's `SHA256SUMS-windows-<arch>.txt`). Its offline checks run with
`build/windows/winget/test/render.sh build/windows/winget` (bash, jq).

### Automation

`.github/workflows/winget-community.yml` runs when a tag build of `build.yml`
has succeeded, whether a tag push or *Run workflow* on the tag started it, and
by hand (*Run workflow*, with the tag and an optional dry run).
`publish-release` creates the release with `GITHUB_TOKEN`, and events caused
by that token start no workflows, so the workflow cannot listen for the
release itself.

1. `check` (no secrets) stops unless the tag is `vX.Y.Z-ce`, its release is
   published and not a prerelease, and `microsoft/winget-pkgs` has neither the
   version nor an open pull request for it. A rebuild tag leaves a warning.
   A missing release ends the job with a notice; any other failed lookup
   (rate limit, server error) fails the job.
2. `publish` (environment `winget`) installs komac 2.17.2 (checked against its
   SHA-256), renders the manifests with the script and template of the default
   branch, uploads them as the artifact `winget-manifests-<version>`, and runs
   `komac submit`, which opens the pull request from the token owner's fork.

The first version opens a *New package* pull request, later ones *New
version*. `winget.yml` is upstream's job (`ONLYOFFICE.DesktopEditors`) and
only runs in Euro-Office's repository.

### Never replace a submitted installer

The manifests pin the SHA-256 of each installer. Once the winget pull request
for a final tag is open or merged, never replace that tag's Windows
installers, for example with a `build.yml` run dispatched with
`replace_assets`. A signed installer gets new bytes on every signing (the
signature carries a new timestamp). Every winget install and upgrade of that
version then fails with a hash mismatch, and the workflow does not submit
again, because the version is already in winget-pkgs or has an open pull
request. A rebuild tag (`-ce.N`) does not help either, because rebuilds are
not published to winget.

If a submitted installer has to change anyway:

- **Pull request still open:** close it, then run the workflow by hand for
  the tag. It finds no open pull request and submits the new hashes.
- **Already merged:** render the manifests again with `render-manifests.sh`
  and submit them by hand with `komac submit <directory>`, which opens an
  *Update version* pull request for the existing version. Say in the pull
  request why the hash changed.

### Note for the winget moderators

winget-pkgs already has `EuroOffice.DesktopEditors`, which volunteers outside the Euro-Office
project submitted (9.3.5.0 in microsoft/winget-pkgs#453509, 9.3.8.0 in #480021). It installs
the project's unsigned installers from its GitHub releases, and both builds write the same *Apps & features* entry. The validation
bot will probably not flag the first pull request: it adds `Possible-Duplicate` only when
another pull request targets the same manifest path or an `InstallerSha256` is already in the
repository, and the signed installers have hashes of their own. A moderator may still ask
whether the package duplicates `EuroOffice.DesktopEditors`, or label it
`Policy-Test-2.2` (trademarks) because of the name. Then post this comment (check the facts,
including the upstream version number, against the current upstream release first):

```markdown
This is not a duplicate of `EuroOffice.DesktopEditors`. It is a separate,
signed build of the same open-source code, published under its own
identifier and publisher name:

- **Publisher:** UnityStack GmbH, not affiliated with the Euro-Office project.
  The description says so, and the identifier's publisher segment is
  `UnityStack`, not `EuroOffice`.
- **Signed installers:** both installers carry an Authenticode signature of
  UnityStack GmbH (Azure Artifact Signing). The Euro-Office project's
  installers in `EuroOffice.DesktopEditors` (9.3.8.0) carry none, so UAC
  shows an unknown publisher for them.
- **Same install entry:** both builds use the unchanged Inno script of
  `desktop-apps`, so they write the same *Apps & features* entry
  (`Euro-Office Desktop Editors_is1`, publisher `Euro-Office`), and
  `AppsAndFeaturesEntries` lists it as the installer writes it. Installing
  one build replaces the other. That is intended: users choose which
  publisher they install from.
- **Releases and support:**
  https://github.com/UnityStack/DesktopEditors/releases and
  https://github.com/UnityStack/DesktopEditors/issues
```

The facts behind it, as of upstream v9.3.8 (checked 2026-11-16): the security directory of
both upstream installers is empty (no Authenticode signature), and upstream's `build.yml`
builds the `euro-office` brand with `sign: false`. Upstream signs only its Nextcloud Office
brand (Authenticode, Nextcloud GmbH), released at `nextcloud-releases/Office-DesktopEditors`
under its own product code, `Nextcloud Office Desktop Editors_is1`; its winget package
`Nextcloud.Office` was still an open pull request (microsoft/winget-pkgs#480016) on
2026-11-16. Check the security directory again for the release you submit against, for
example with `Get-AuthenticodeSignature` on Windows.

winget-pkgs also checks that the installer URLs can be reached from the publisher's website
(*URL Domain Validation*). `PackageUrl` points at this repository, which helps; a link from
<https://unitystack.eu> to this repository or its releases makes it certain.

### One-time setup

1. **A GitHub account for the pull requests**, ideally a machine account
   without write access to UnityStack's repositories. Fork
   `microsoft/winget-pkgs` to it under the name `winget-pkgs` (komac does not
   create the fork).
2. **A classic personal access token** of that account with only the
   `public_repo` scope, with an expiry and a reminder to renew it.
   Fine-grained tokens can push to the fork but cannot open the pull request
   on `microsoft/winget-pkgs`.
3. **The environment `winget`** in this repository's settings, with
   deployment branches limited to `main`, and the token as its secret
   `WINGET_TOKEN`.
4. **Issues enabled on this repository.** The manifests' `PublisherSupportUrl`
   is <https://github.com/UnityStack/DesktopEditors/issues>, which returns 404
   while Issues are turned off in the repository settings.
5. **The installers can be found from the package page.** winget-pkgs
   requires that installer URLs can be found from the publisher's site. The
   manifests' `PackageUrl` is this repository, whose *Releases* list the
   installers. <https://euro-office.org> does not resolve yet, and its source
   links the Euro-Office project's releases, not these. Switch `PackageUrl` in
   `templates/UnityStack.EuroOfficeCommunityEdition.locale.en-US.yaml.in` (and
   in `test/render.sh`) to it only once it is live and its Windows downloads
   point at this repository's releases.

Before the first version goes in, review it: run the workflow by hand for the
tag with *dry run*, check the manifests in the artifact, then run it again
without. To do the same locally:

```bash
build/windows/winget/render-manifests.sh --tag v9.3.8-ce --out winget-out
# prints winget-out/manifests/u/UnityStack/EuroOfficeCommunityEdition/9.3.8.0
```

On Windows, `winget validate --manifest <that directory>` checks the
manifests and, after `winget settings --enable LocalManifestFiles`,
`winget install --manifest <that directory>` installs from them (best in
Windows Sandbox). `komac submit <that directory>` (or `wingetcreate submit`)
opens the pull request with the account's token. Post the
[note for the winget moderators](#note-for-the-winget-moderators) on the first
pull request and answer their questions; later versions need no manual step.

## Good to know

- **sccache is optional.** Without it on `PATH` the script just builds without a
  compiler cache (and says so). With it, object files are cached by content hash;
  embedded debug info (`/Z7`) is required for caching to work and the script sets
  it for you.
- **The packaging step pulls a couple of inputs at build time.** It stages the
  VC++ redistributable and fetches Inno Setup's "unofficial" language files (which
  no stock Inno install ships) into the Inno `Languages` folder. Both run on every
  packaging build — including CI, which does *not* pass `-InstallDeps`. Writing
  the language files into the Inno install dir needs write access there, so a
  plain local packaging run may need elevation. If that's a hassle, consider
  vendoring those files in the fork.
- **The build mutates the host** when `-InstallDeps` is used (VS components, global
  tools). That's fine on a throwaway CI runner; on your own machine, know that it
  changes your Visual Studio installation and `Program Files`.