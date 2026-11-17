[![License](https://img.shields.io/badge/License-GNU%20AGPL%20V3-green.svg?style=flat)](https://www.gnu.org/licenses/agpl-3.0.en.html)
![Platforms Windows | macOS | Linux](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey.svg?style=flat)

## Euro-Office Community Edition 🇪🇺

This repository builds the **Euro-Office Community Edition**: the desktop editors of the
[Euro-Office project](https://github.com/Euro-Office/DesktopEditors), built from its
unchanged editor sources with this repository's own build, packaging and signing, and
published by UnityStack GmbH. Each release is named after the upstream version it builds
(`v9.3.6-ce…` is upstream 9.3.6). It is an unofficial build and not affiliated with the
Euro-Office project.

What the Community Edition adds to upstream's own releases (compared with upstream v9.3.8,
checked on 2026-11-16):

| | Upstream Euro-Office releases | Community Edition |
| --- | --- | --- |
| Windows installer (x64, arm64) | not signed | signed by UnityStack GmbH (Azure Artifact Signing) |
| macOS app (Apple silicon) | no Developer ID signature, not notarized | signed with UnityStack GmbH's Developer ID and notarized by Apple |
| macOS updates | none | automatic, with Sparkle; a stable and a testing channel |
| Linux packages | `.deb`, `.rpm`, `.tar.xz`, not signed; no repository | signed `.rpm`; `.deb` and `.rpm` from signed apt, dnf and zypper repositories |
| Checksums | none | `SHA256SUMS` files for every platform; the Linux ones signed with OpenPGP |
| Cloud providers | Nextcloud | Nextcloud and openWorkspace |

macOS signing, notarization and automatic updates, the package repositories and the macOS
checksum file start with v9.3.6-ce.rc.2. The first release candidate, v9.3.6-ce.rc.1, has a
signed Windows installer and signed `.rpm` files, but an unsigned `.dmg` that does not update
itself, and its Linux checksum file names the packages with `~` where the downloaded files
have `.`.

Signed installers mean Windows names a verified publisher when it asks for administrator
rights, macOS opens the app without warning about an unidentified developer, and apt, dnf and
zypper check every package from the repositories against UnityStack's key (downloaded files
are covered by the signed checksums and, for `.rpm`, by `rpm -K`). Upstream also points to
signed builds under the **Nextcloud Office** name, published by Nextcloud.

Report problems with the Community Edition's builds, signatures, packages or updates in this
repository's [issues](https://github.com/UnityStack/DesktopEditors/issues), and problems in the
editors themselves to the [Euro-Office project](https://github.com/Euro-Office/DesktopEditors/issues).

## Welcome to the Desktop Editors repo!

[Desktop Editors](https://github.com/Euro-Office/DesktopEditors) is a free office suite that combines text, spreadsheet, presentation, and PDF editors & Diagram Viewer. The application allows creating, viewing and editing documents stored on your Windows/Linux PC or Mac without an Internet connection. It is fully compatible with Office Open XML formats: .docx, .xlsx, .pptx.

## Features you'll love ✨

Take advantage of the powerful editors included in Desktop Editors.

* Document Editor
* Spreadsheet Editor
* Presentation Editor
* Form Creator
* PDF Editor
* Diagram Viewer

The suite empowers you to create, edit, save, and export text documents, spreadsheets, presentations, PDFs, fill out PDF forms, open diagrams, all while offering additional advanced features such as:

* Connection to the cloud (Nextcloud, openWorkspace, OpenCloud) for real-time collaboration ☁️
* AI-powered assistants 🤖
* Digital signatures ✍️🔏
* Password protection 🔒🔑
* Scalable UI options (including dark mode 🌓)

## Cloud providers ☁️

**Connect to cloud** on the start page offers these providers:

| Provider | Server requirement |
| --- | --- |
| **Nextcloud** | The Euro-Office app installed on the Nextcloud server. |
| **openWorkspace** | None. UnityStack's OpenCloud-based workspace ships the [OpenCloud Desktop Bridge][bridge] preinstalled. |
| **OpenCloud** | The [OpenCloud Desktop Bridge][bridge] extension installed on the OpenCloud server, as a web app under `WEB_ASSET_APPS_PATH`. |

OpenCloud opens office files in a way the desktop app cannot see, so a plain OpenCloud server
connects but never opens a document in an editor tab, and the app does not keep it in the
Clouds list after a restart. The OpenCloud Desktop Bridge adds **Open in Euro-Office desktop**,
opens documents in native editor tabs and registers the host in the Clouds list. Only the
bridge's launcher (`/desktop-bridge/apps/eurooffice/` right after the host) opens as an editor
tab; other OpenCloud apps that open a new window go to the system browser. The Connect dialog
shows the same hint with a link when you pick OpenCloud.

Bridge 0.2.0, the current release, lists a host connected with OpenCloud as openWorkspace; it
works the same. A later bridge release that includes the OpenCloud provider change lists it as
OpenCloud. The app keeps the provider a host was first connected with; remove the entry and
connect again to switch.

The provider definitions live in [`build/providers/`](./build/providers) (openWorkspace,
OpenCloud) and [`desktop-apps`](https://github.com/Euro-Office/desktop-apps/tree/main/common/loginpage/providers/nextcloud) (Nextcloud).
See [build/README.md](./build/README.md#cloud-providers) for how they are packaged.

[bridge]: https://git.unitystack.org/UnityStack/opencloud-desktop-bridge

## Localization 🌐

Constantly improving localization of the editors to make the suite accessible to all users, all over the world.

* Interface available in 46 languages
* RTL support
* Hieroglyph support 🈴

## Plugins 🧩

Desktop Editors offer support for plugins allowing developers to add specific features to the editors that are not directly related to the OOXML format.

## Components 📦

Desktop Editors contain the following components:

* [desktop-apps](https://github.com/Euro-Office/desktop-apps) - the frontend for Desktop Editors which is used to build the program interface for the operating system selected.
* [desktop-sdk](https://github.com/Euro-Office/desktop-sdk) - SDK which is a core part of Desktop Editors.
* [core](https://github.com/Euro-Office/core) - server core components for [Document Server][1] which is a part of Desktop Editors and is used to enable the conversion between the most popular office document formats (DOC, DOCX, ODT, RTF, TXT, PDF, HTML, EPUB, XPS, DjVu, XLS, XLSX, ODS, CSV, PPT, PPTX, ODP).
* [sdkjs](https://github.com/Euro-Office/sdkjs) - JavaScript SDK for the [Document Server][1] which is a part of Desktop Editors and contains API for all the included components client-side interaction.
* [web-apps](https://github.com/Euro-Office/web-apps) - the frontend for [Document Server][1] which is a part of Desktop Editors that allows the user to create, edit, save and export text, spreadsheet and presentation documents using the common interface of a document editor.
* [dictionaries](https://github.com/Euro-Office/dictionaries) - the dictionaries of various languages used for spellchecking in Desktop Editors.

## Install 💾

The Community Edition is published on the [releases](https://github.com/UnityStack/DesktopEditors/releases)
page of this repository. Release candidates are marked as pre-releases.

* **Windows** (x64, arm64): the `.exe` installer, or the `.zip`, a portable copy that runs
  without installing (it needs the Microsoft Visual C++ Redistributable, which the installer
  adds). The installer's file properties show the digital signature of UnityStack GmbH, as do
  the programs in the `.zip`.
* **macOS** (Apple silicon, macOS 11 or later): the `.dmg`. From v9.3.6-ce.rc.2 on, the app
  checks for updates once a day; see
  [Automatic updates](./build/macos/README.md#automatic-updates-sparkle).
* **Linux** (x86_64, aarch64): add the [package repository](./build/linux/README.md#package-repositories)
  for apt, dnf or zypper (from v9.3.6-ce.rc.2 on) to get updates with the rest of the system,
  or download the `.deb`, `.rpm` or `.tar.xz`. Check downloads as in
  [Verifying a download](./build/linux/README.md#verifying-a-download) with the key
  [`build/linux/unitystack-package-signing.asc`](./build/linux/unitystack-package-signing.asc);
  its fingerprint is `62E1 6713 F445 9962 B020  2B01 038A B9E6 3A2B 29ED`. Testers of rc.1:
  see [Testers of v9.3.6-ce.rc.1](./build/linux/README.md#testers-of-v936-cerc1).

Upstream's own builds are on the [Euro-Office releases](https://github.com/Euro-Office/DesktopEditors/releases/latest)
page, and builds under the Nextcloud Office name on
[Nextcloud's releases](https://github.com/nextcloud-releases/Office-DesktopEditors/releases/latest).
See the [installation guide](https://euro-office.github.io/documentation/installation/) in the
[official documentation](https://euro-office.github.io/documentation/) for general details.

## Build it yourself 🛠️

You can build Desktop Editors from source on **Windows**, **Linux**, and **macOS**. This is a
super-repository, so the first step is always to check out the submodules:

```sh
git clone https://github.com/Euro-Office/DesktopEditors.git
cd DesktopEditors
git submodule update --init --recursive
```

Then head to the build docs:

* **[build/](./build/README.md)** — start here for the overall build model (the
  shared CMake definition, the common editors payload, vcpkg, and caching).
* **[build/windows/](./build/windows/README.md)** — the Windows build (`build.ps1`, MSVC + CMake).
* **[build/linux/](./build/linux/README.md)** — the Linux build (Docker / `docker buildx bake`).
* **[build/macos/](./build/macos/README.md)** — the macOS build (native CMake + Xcode).

## Get involved 🤝

Contributions are welcome! Whether it's a bug report, a feature idea, a
translation, or a pull request, here's how to take part:

* **Found a bug or have an idea?** Open an [issue](https://github.com/Euro-Office/DesktopEditors/issues)
  and describe what you ran into or what you'd like to see.
* **Want to contribute code?** Fork the relevant [component](#components-) repo,
  make your change, and open a pull request. For build changes, see the
  [build docs](./build/README.md) above.
* **Want to help translate?** Localization improvements are always appreciated —
  see 
  the editors' interface translations.

Please keep contributions compatible with the project's AGPL v3 license.

## License 📄

Desktop Editors is licensed under the GNU Affero Public License, version 3.0, ensuring its transparency and commitment to the open-source community.

  [1]: https://github.com/Euro-Office/DocumentServer