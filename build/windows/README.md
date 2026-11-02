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