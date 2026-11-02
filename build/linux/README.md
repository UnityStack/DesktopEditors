# Building on Linux

The Linux build runs entirely in Docker via `docker buildx bake`. It compiles the
desktop application, overlays the common editors payload, generates fonts and
theme thumbnails, and produces the installable packages — all inside containers,
so it needs almost nothing installed on the host.

> New here? Read the **[build overview](../README.md)** first — it explains the
> three CI jobs, the common payload, vcpkg, and caching, none of which are
> repeated below.

## Prerequisites

- **Docker** with the **Buildx** plugin (Docker Desktop, or `docker buildx`
  available on a Docker Engine install).
- The submodules checked out (see the [overview](../README.md#prerequisites-all-platforms)).

That's it — the C++ toolchain, Qt, the WASM toolchain, and all system `-dev`
packages are installed inside the images, not on your machine.

## One-time builder setup

The default `docker` driver supports the local cache export (`cache-to`) used by
these bake files when Docker's containerd image store is enabled. If it is not
enabled, the build fails with:

```
ERROR: Cache export is not supported for the docker driver.
```

Create a builder that uses the `docker-container` driver instead (this runs
BuildKit as a sidecar container, which supports cache export):

```sh
docker buildx create --name desktop-editors --driver docker-container --use
```

The `--use` flag makes it the active builder for all subsequent `docker buildx`
commands. This is a one-time step — once the builder exists you can switch back
to it at any time with `docker buildx use desktop-editors`.

## Quick start

Run from the **repository root**. The bake graph is defined in
`build/docker-bake.hcl`; build a target with:

```sh
cd build
docker buildx bake -f ./docker-bake.hcl <target>
```
or
```sh
cd build/linux
docker buildx bake -f ./docker-bake.hcl <target>
```

The two targets you'll care about:

- **`desktop-common`** — the shared web/WASM editors payload. This is the same
  artifact the `build-common` CI job produces, and it's what the Windows build
  consumes. Build it on its own when you only need the common content:

  ```sh
  cd build
  docker buildx bake -f ./docker-bake.hcl desktop-common
  ```

- **`desktop-linux`** — the full desktop application build (depends on
  `desktop-common`), which compiles the native app and runs the font/theme
  post-steps.

Check `docker-bake.hcl` for the authoritative list of targets, their outputs,
and any overrides the workflow uses (version, branding, output type).

You can also use the build.sh script in this directory to build **`desktop-common`** and **`desktop-linux`** at once:

```sh
cd build/linux
./build.sh
```

For local testing you usually don't need the packages. `--no-package` builds only
the app (the `desktop-app` bake target) and unpacks it to `build/linux/deploy/desktopeditors`,
skipping the slow `.deb`/`.rpm`/`.tar.xz` step:

```sh
cd build/linux
./build.sh --no-package
cd deploy/desktopeditors && ./start_desktop.sh
```

## How the desktop image is built

The desktop stage (in the bake Dockerfile) follows the standard sequence:

1. Install the build/system dependencies into the image.
2. Copy in the relevant submodules (`desktop-sdk`, `desktop-apps`, `core-fonts`)
   plus branding overlays.
3. Configure CMake with the vcpkg toolchain, Ninja, and `ccache`, then
   `cmake --build` / `cmake --install`.
4. Overlay the `desktop-common` payload onto the installed tree
   (`COPY --from=desktop-common`).
5. Run `allfontsgen` (fonts) and `allthemesgen` (slide-theme thumbnails), then
   remove the generator binaries so they don't ship.

## Caching

Compilation is cached with **ccache** via a BuildKit cache mount. If you're
working on the build itself, a few things are worth knowing:

- The ccache mount uses a **stable id** (`id=ccache`), so it persists and is
  reused across builds.
- Some other cache mounts (the build and NuGet caches) currently fold a
  `CACHE_BUST` arg into their mount **id**. Changing that arg starts a fresh
  cache rather than reusing the old one — so don't expect those two to persist
  across a bust. ccache is unaffected.
- The compile step builds inside a cache mount and copies the result out. That
  buys fast incremental rebuilds at the cost of strict layer reproducibility —
  fine for development and CI, worth knowing if you need a bit-reproducible
  release.

## Output

The build produces the installed application tree and the Linux packages inside
the image / bake output, default is `build/linux/deploy`. Use the bake `output` setting (e.g.
`type=docker`, `type=local,dest=...`) to control where artifacts land; see
`docker-bake.hcl`.

## Signing in CI (fork)

On tag pushes `build-linux` uploads its packages as
`linux-unsigned-euro-office-<arch>` instead of `linux-packages-...`, and the
`sign-linux` job in `.github/workflows/build.yml` signs them. Per arch it:

1. imports the GPG signing subkey into a temporary `GNUPGHOME`,
2. signs every `.rpm` with `rpmsign --addsign` and checks each one with
   `rpmkeys --checksig` against the public key,
3. writes `SHA256SUMS-linux-<arch>.txt.asc`: the SHA-256 sums of every `.deb`,
   `.rpm` and `.tar.xz`, clearsigned with the same subkey and checked with
   `gpg --verify`,
4. uploads the result as `linux-packages-euro-office-<arch>`, which
   `publish-release` attaches to the GitHub release.

The `.deb` files are not signed one by one: apt and dpkg check no per-package
signature (debsigs is off by default). Until the apt repository exists and signs
its `Release` file, the `.deb` and `.tar.xz` files are covered by the signed
checksum file only. Only the clearsigned file is published, without a plain
`.txt`, so users check the hashes in the same file whose signature they verified.

Branch and PR builds are not signed and are still uploaded as
`linux-packages-euro-office-<arch>` by `build-linux`. If `sign-linux` fails or
is skipped, `publish-release` does not run.

The job runs in the GitHub environment **`signing`** (the same one as
`sign-windows`) and needs these secrets there:

- `LINUX_GPG_PRIVATE_KEY`: the ASCII-armored export of the signing subkey (see
  below). The job fails if it is empty or not an armored secret key.
- `LINUX_GPG_PASSPHRASE` (optional): the subkey's passphrase. Leave it unset for
  a subkey without a passphrase.

### Signing key

The armored **public** key is
`build/linux/unitystack-package-signing.asc`:

| | |
|---|---|
| User ID | `UnityStack GmbH Package Signing <packages@unitystack.eu>` |
| Primary key (certify, offline) | RSA-4096 `62E1 6713 F445 9962 B020  2B01 038A B9E6 3A2B 29ED` |
| Signing subkey (CI, expires 2028-11-01) | RSA-4096 `E94F 0929 2FC4 6A1B B63A  50E4 A4A6 410F 8A26 DCC6` |

The key is UnityStack's package-signing key, not specific to this product; other
UnityStack packages get their own signing subkey under the same primary key.
`sign-linux` fails unless this file contains the signing subkey from the secret,
so a secret that does not match the published key is caught before release.

Recommended layout:

- The primary key only certifies (`cert`) and stays offline.
- A signing subkey (`sign`) expires after 2 years and is the only secret key in
  CI.
- Use RSA-4096 for both. Ed25519 is smaller, but in our tests (Nov 2026,
  containers) rpm 4.14.3 on Rocky Linux 8 could not import an Ed25519 key and
  reported the package signature as BAD. Rocky 9 (rpm 4.16), Rocky 10
  (4.19), Fedora 43 (rpm 6.0) and openSUSE Leap 15.6 (4.14.3 with SUSE patches)
  verified both. RSA-4096 verified on all of them. EL8 is supported until 2029.
  We did not test a mixed Ed25519 primary key with an RSA subkey.

On the offline machine (GnuPG 2.2 or newer):

```sh
gpg --quick-generate-key "UnityStack GmbH Package Signing <packages@unitystack.eu>" rsa4096 cert never
gpg --quick-add-key <primary-fpr> rsa4096 sign 2y
gpg --list-keys --with-subkey-fingerprints <primary-fpr>   # note the subkey fingerprint

# Secret: only the signing subkey. The trailing "!" selects exactly that
# subkey, and the primary key is exported as a stub without its secret.
gpg --armor --export-secret-subkeys <subkey-fpr>! > signing-subkey.asc
#   For a CI copy without a passphrase, add
#   --export-options export-reset-subkey-passwd
gh secret set LINUX_GPG_PRIVATE_KEY --env signing < signing-subkey.asc
gh secret set LINUX_GPG_PASSPHRASE --env signing    # only if it has a passphrase
shred -u signing-subkey.asc

# Public key, committed to the repository:
gpg --armor --export <primary-fpr> > build/linux/unitystack-package-signing.asc
```

The job signs with the newest valid signing subkey in the secret, and passes it
to gpg and rpmsign (`%_gpg_name`) as `<subkey-fpr>!`. To rotate, add a new
signing subkey offline, then commit the re-exported public key and update
`LINUX_GPG_PRIVATE_KEY` before the old subkey expires. Users who imported the
key into rpm then import the updated public key again (older rpm versions need
the old `gpg-pubkey` package removed first).

### Verifying a download

Check that the key's fingerprint is
`62E1 6713 F445 9962 B020  2B01 038A B9E6 3A2B 29ED` before trusting it:

```sh
gpg --show-keys unitystack-package-signing.asc
gpg --import unitystack-package-signing.asc

# Checksums (all package types). sha256sum warns about the
# signature lines; that is expected.
gpg --verify SHA256SUMS-linux-amd64.txt.asc
sha256sum --ignore-missing -c SHA256SUMS-linux-amd64.txt.asc

# RPM signature (should print "digests signatures OK")
sudo rpm --import unitystack-package-signing.asc
rpm -K euro-office-*.rpm
```
