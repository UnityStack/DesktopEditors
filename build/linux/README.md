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
3. Build with `desktop-apps/scripts/build.sh`, then `cmake --install`. It
   links the prebuilt core from the `core-package` context, which
   `fetch-core.sh` fills before the bake when the build cache has a package for
   the `core` checkout; with an empty context it builds core first.
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

1. imports the GPG signing subkey into a temporary `GNUPGHOME` and checks it
   (`build/linux/import-signing-key.sh`, see [The checks](#the-checks)),
2. on arm64, drops the arch-independent help packages (`_all.deb`,
   `.noarch.rpm`, `-any.tar.xz`): both arches build them, with different
   bytes under the same name, and only amd64's are released. Since 9.3.8
   desktop-apps builds them only with `WITH_HELP=1` (the offline help is
   still ONLYOFFICE-branded), so CI has none to drop,
3. signs every `.rpm` with `rpmsign --addsign` and checks each one with
   `rpmkeys --checksig` against the public key,
4. renames the files to the names GitHub gives release assets (`~` becomes
   `.`, as in `9.3.6-0.ce`) and writes `SHA256SUMS-linux-<arch>.txt.asc`: the
   SHA-256 sums of every `.deb`, `.rpm` and `.tar.xz`, clearsigned with the
   same subkey and checked with `gpg --verify`,
5. uploads the result as `linux-packages-euro-office-<arch>`, which
   `publish-release` attaches to the GitHub release. `publish-release` fails
   if a file name is in two artifacts or a file does not match its checksum
   file, and it never replaces a release asset with different bytes (see
   [How CI publishes](#how-ci-publishes)).

The `.deb` files are not signed one by one: apt and dpkg check no per-package
signature (debsigs is off by default). A `.deb` installed from the
[apt repository](#package-repositories) is checked against its signed
`Release` file, which lists the hash of every index and through them of every
package; a `.deb` or `.tar.xz` downloaded from the releases page is covered by
the signed checksum file. Only the clearsigned file is published, without a
plain `.txt`, so users check the hashes in the same file whose signature they
verified.

Before any of that, and before anything is built, a `v*` tag build runs
`signing-preflight`: the same import and check, a test signature, and a
check of the newest releases' signatures. If the secret does not hold
exactly one signing subkey, that subkey is not the designated one or does
not match the committed or the published key, the committed key no longer
verifies what was released, or the passphrase does not work, the run stops
there, not after the hour-long
builds (see [The checks](#the-checks)). `sign-linux` and `publish-repo`
check again. On branches and PRs the preflight is skipped; the build jobs
then still run (see the comment above `signing-preflight` in `build.yml`
for why they carry `if: ${{ !cancelled() && !failure() }}`). It is also
skipped on tags that do not start with `v`, which the `signing` environment
refuses anyway: those build as before, and their sign and publish jobs are
skipped.

Branch and PR builds are not signed and are still uploaded as
`linux-packages-euro-office-<arch>` by `build-linux`. If `sign-linux` fails or
is skipped, `publish-release` does not run.

`signing-preflight`, `sign-linux` and `publish-repo` run in the GitHub
environment **`signing`** (the same one as `sign-windows`; its required
reviewers are asked at the start of a tag run, by the preflight) and need
these secrets there:

- `LINUX_GPG_PRIVATE_KEY`: the ASCII-armored export of the signing subkey CI
  signs with, and only that one (see
  [Exporting the CI subkey](#exporting-the-ci-subkey)). The jobs fail if it
  is empty, not an armored secret key, holds the primary key's secret or
  more than one signing subkey, or another subkey than the one
  `build/linux/unitystack-package-signing.ci-subkey` names.
- `LINUX_GPG_PASSPHRASE` (optional): the subkey's passphrase. Leave it unset for
  a subkey without a passphrase.

### Signing key

The armored **public** key is
`build/linux/unitystack-package-signing.asc`:

| | |
|---|---|
| User ID | `UnityStack GmbH Package Signing <packages@unitystack.eu>` |
| Primary key (certify only, no expiry, secret offline) | RSA-4096 `62E1 6713 F445 9962 B020  2B01 038A B9E6 3A2B 29ED` |
| Signing subkey in CI (no expiry; created 2026-11-02, re-bound without expiry 2026-11-03) | RSA-4096 `E94F 0929 2FC4 6A1B B63A  50E4 A4A6 410F 8A26 DCC6` |
| Spare signing subkey (no expiry; created 2026-11-03, secret offline) | RSA-4096 `3718 42FE 38AD 622F E03D  F246 0933 8103 D3B1 B0A0` |

The secrets of the primary key and of the spare are offline, in the owner's
password manager. CI holds only the secret of `E94F...`
(`LINUX_GPG_PRIVATE_KEY`, exported again after the re-binding on
2026-11-03, so it carries the binding without expiry). The spare is in the
key from the first release on, so every installed system trusts it from the
start. It signs nothing until the CI secret has to be replaced (see
[If the CI secret leaks](#if-the-ci-secret-leaks)). The key file carries
both binding signatures of `E94F...`, the first one (2026-11-02, with an
expiry) and the re-binding (2026-11-03, without): the `v9.3.6-ce.rc.1` RPMs
were signed under the first one, and Fedora checks them against it (see
[Changing the public key](#changing-the-public-key)).

The layout:

- The primary key only certifies (`cert`), has no expiry and stays offline.
- The signing subkeys (`sign`) have no expiry. CI holds the secret of
  exactly one; at least one more, the spare, has its secret offline only.
  The jobs that sign fail when CI holds two (a leak of the CI secrets would
  then take the spare too), and every check warns when the key has no
  spare.
- Use RSA-4096 for all of them. Ed25519 is smaller, but in our tests (Nov
  2026, containers) rpm 4.14.3 on Rocky Linux 8 could not import an Ed25519
  key and reported the package signature as BAD. Rocky 9 (rpm 4.16), Rocky 10
  (4.19), Fedora 43 (rpm 6.0) and openSUSE Leap 15.6 (4.14.3 with SUSE
  patches) verified both. RSA-4096 verified on all of them. EL8 is supported
  until 2029. We did not test a mixed Ed25519 primary key with an RSA subkey.

The key is UnityStack's package-signing key, not specific to this product;
other UnityStack packages may get their own signing subkeys under the same
primary key. Those would then be in this file too, trusted by this
repository's clients and counted as spares by the checks below, so think
twice before adding them.

The import step of `signing-preflight`, `sign-linux` and `publish-repo`
(`build/linux/import-signing-key.sh`) runs
`build/linux/select-signing-subkey.sh`, which checks the secret and prints
its signing subkey. The jobs pass it to gpg and rpmsign (`%_gpg_name`) as
`<subkey-fpr>!`.

Which subkey CI holds is committed next to the key, in
`build/linux/unitystack-package-signing.ci-subkey` (its fingerprint, now
`E94F...`). The jobs that sign fail if the secret is another subkey, so
exporting the spare by mistake (both are RSA-4096 without expiry, easy to
confuse) stops the release instead of quietly using up the spare. The
checks of the public key name that subkey as CI's, and warn when the newest
signature they verify was made by another one. The repository variable
`LINUX_GPG_SIGN_SUBKEY` (40-digit fingerprint, normally unset) is an
optional second copy: when it is set, it must agree with the file.

#### Why the subkeys do not expire

Most vendors' package repositories sign with keys that do not expire
(Docker, Signal, Tailscale, Microsoft, Mozilla, PostgreSQL, among others).
An expiry protects little here: a leaked subkey has to be revoked anyway,
and installed systems learn of an expiry the same way they learn of a
revocation, through the key they have. Its cost is an outage planned in
advance: apt and dnf reject signatures of an expired subkey (`EXPKEYSIG`),
the repository is re-signed only when a release is published, and every
extension is a new binding signature, which the key file must then carry
next to the old one (see [Changing the public key](#changing-the-public-key)).
The spare covers what an expiry would be for: when the CI secret leaks, CI
switches to a subkey every installed system already trusts.

The checks still handle a subkey with an expiry (see
[A subkey with an expiry](#a-subkey-with-an-expiry)); a subkey without one
is the normal, healthy state and gives no warning.

#### Exporting the CI subkey

`LINUX_GPG_PRIVATE_KEY` holds the secret of exactly one subkey, the one CI
signs with and `build/linux/unitystack-package-signing.ci-subkey` names.
To put a subkey there (`E94F...` now, the spare in an emergency), on the
offline machine with the primary key, type the commands below one by one,
not as a script with `set -e` (see `--passwd` below). The command blocks in
this section and the next two work as typed in bash and in zsh, the macOS
default: they have no comments, and the `!` that selects a subkey is in
single quotes, where neither shell expands it (bash and zsh would read
`"$sub!"` as history expansion).

```sh
sub=<40-digit fingerprint of the subkey>
media=<directory on the removable media>
tmp=$(mktemp -d)
gpg --armor --export-secret-subkeys "$sub"'!' | gpg --homedir "$tmp" --import
gpg --homedir "$tmp" --passwd "$sub"
gpg --homedir "$tmp" --list-secret-keys --with-subkey-fingerprints
gpg --homedir "$tmp" --armor --export-secret-subkeys "$sub"'!' > "$media/ci-signing-subkey.asc"
gpgconf --homedir "$tmp" --kill all
rm -rf "$tmp"
```

- `"$sub"'!'` selects exactly this subkey: the primary key comes along as
  a stub, the other subkeys not at all. Without the `!`, gpg exports every
  subkey's secret, the spare's included.
- `--passwd` gives the CI copy a passphrase of its own instead of the
  owner's: gpg asks for the current one, then the new one (or none). It
  also reports "error changing passphrase: No secret key" for the primary
  key stub, and GnuPG 2.4 then exits 2; both are expected.
- `--list-secret-keys` must show `sec#` (the primary key, a stub) and one
  `ssb` with this fingerprint.

Then, on an online machine with `gh` (the second command asks for the CI
copy's passphrase; with no passphrase, run
`gh secret delete LINUX_GPG_PASSPHRASE --env signing -R UnityStack/DesktopEditors`
instead):

```sh
media=<directory of the removable media on this machine>
gh secret set LINUX_GPG_PRIVATE_KEY --env signing -R UnityStack/DesktopEditors < "$media/ci-signing-subkey.asc"
gh secret set LINUX_GPG_PASSPHRASE --env signing -R UnityStack/DesktopEditors
```

Then remove the file from the media: `shred -u "$media/ci-signing-subkey.asc"`
on Linux. macOS has no `shred` (only through Homebrew's coreutils), and its
`rm -P` has no effect any more; neither reliably overwrites flash media
anyway. There, delete the file and wipe or destroy the media.

The export never goes from the offline machine to the network directly,
and the file on the media holds only that subkey, protected by the CI
passphrase. Without the `--passwd` step the subkey keeps the owner's
passphrase, which `LINUX_GPG_PASSPHRASE` would then have to hold, and a
leak of the CI secrets would expose the passphrase of the primary key and
of the spare. (`--export-options export-reset-subkey-passwd`, which older
guides suggest, is not an option of GnuPG 2.2 or 2.4; both refuse it.) The
secret carries the subkey's binding, which must be the committed key's
newest one: after a re-binding, export the secret again (the checks refuse
the old one, "another binding"). The CI messages point here; they never
print a command that exports a secret.

#### Changing the public key

The key file changes when a subkey is revoked, a spare is added, or a
binding is renewed (an expiry set or extended). Installed systems keep
every signature packet they got, and the committed key must keep them too:

- **Never export with `--export-options export-minimal` or `export-clean`.**
  They keep only a subkey's newest binding signature.
- **gpg keeps only a subkey's newest binding in its keyring.**
  `--quick-set-expire` replaces the old one, and importing a key file with
  two bindings of a subkey into an empty keyring keeps one (GnuPG 2.2, 2.4
  and 2.5). So the owner's keyring cannot export the full key; it is the
  published key plus what changed.
- Fedora's rpm 6, and sqv (apt's verifier on Debian 13), check a signature
  against the binding that was valid when it was made; so does RHEL 10's
  rpm 4.19 (in `revocation.sh`, AlmaLinux 10 rejected a package signed
  before the re-binding with a key that lacked the old binding). Measured Nov 2026:
  with the owner's export of 2026-11-03, which had only the re-binding of
  `E94F...`, `rpm -K` of the `v9.3.6-ce.rc.1` RPM on fedora:43 printed
  `Certificate 038AB9E63A2B29ED does not contain key E94F... or it is not
  valid`, `SIGNATURES NOT OK`, and sqv on debian:13 rejected that release's
  `SHA256SUMS-linux-arm64.txt.asc` ("No binding signature at time
  2026-11-02T11:00:11Z"). With both bindings both pass, and Rocky 9, Leap
  15.6 and Tumbleweed pass either way.
- **gpg writes a subkey's revocation in front of its binding**, and rpm
  4.14 and 4.16 (openSUSE Leap 15.6, RHEL 9 and its rebuilds) then refuse
  to import the whole key ("key 1 import failed", measured Nov 2026), so
  those systems could not verify anything, not even the spare's
  signatures. With the revocation after the bindings they import it.
- **The subkeys must stay in their order.** dnf 4.14 (RHEL 9) shows the
  first signing subkey's fingerprint when it imports the key (see
  [Fingerprints users see](#fingerprints-users-see)). `sq keyring merge`,
  which keeps every signature, may reorder the subkeys (measured with sq
  1.3.1: merging each of 6 throwaway keys with three subkeys with itself
  put another subkey first in 4 of them).
- **One armored block, no secret.** gpg takes two concatenated exports as
  one key, but rpm 4 imports only the first block; and gpg imports a secret
  key where a public one was meant. The checks fail on both.

`build/linux/merge-public-key.py` does all of this: it keeps every
signature packet of every file it is given byte for byte, keeps the first
file's subkey order and appends new subkeys, puts revocations behind the
bindings, and refuses secret keys, several keys or armored blocks. So,
after the change on the offline machine, export the public key there with
no `--export-options` at all:

```sh
primary=62E16713F4459962B0202B01038AB9E63A2B29ED
gpg --armor --export $primary > new.asc
```

and on any machine with Python 3, in the repository root (only public keys
from here on). The first file is the key installed systems have, the
second the committed one (it may hold changes not released yet), the
third the new export. Until the site serves a key, `curl` fails (404);
leave `published.asc` out of the merge then.

```sh
curl -fsSL -o published.asc https://packages.unitystack.eu/keys/unitystack.asc
python3 build/linux/merge-public-key.py --output merged.asc published.asc build/linux/unitystack-package-signing.asc new.asc
mv merged.asc build/linux/unitystack-package-signing.asc
gpg --show-keys --with-subkey-fingerprints build/linux/unitystack-package-signing.asc
GITHUB_REPOSITORY=UnityStack/DesktopEditors bash build/linux/fetch-released-signatures.sh released
PUBLIC_KEY_FILE=build/linux/unitystack-package-signing.asc bash build/linux/select-signing-subkey.sh --public --released released
```

`--show-keys` must show the primary key `[C]` without expiry, the user ID
and every `[S]` subkey as intended (a revoked one as `[revoked: ...]`), in
the old order with new subkeys last. The check exits 3 (warnings) until
the release: "The published key ... differs" (it lacks the new signatures)
is expected, and so is "not in the published key" for a new subkey. It
must report no error, and in particular not that the key "lacks ...
signature(s) that the published key has", that a revocation comes "before
a binding", that a released signature was made before every binding of
its subkey, or that the subkeys are listed "in another order". (With
`--require-published`, as the monthly `signing-key-check.yml` runs it, the
difference is an error; that check fails until the release publishes the
key.) Then commit the file, together with
`build/linux/unitystack-package-signing.ci-subkey` if CI's subkey changes.
The `.deb` and `.rpm` copy the key at build time, so the next release, and
the site it publishes, carry it.

#### If the CI secret leaks

If `LINUX_GPG_PRIVATE_KEY` (or the CI passphrase with it) may have leaked:

1. On the offline machine, revoke `E94F...`. In
   `gpg --edit-key 62E16713F4459962B0202B01038AB9E63A2B29ED` select it with
   `key 1` and check that the line marked `*` is
   `ssb  rsa4096/A4A6410F8A26DCC6` (`--edit-key` shows key IDs, the last 16
   digits of the fingerprint), then `revkey`, reason `1` (key has been
   compromised), and `save`.
2. Change the public key as in
   [Changing the public key](#changing-the-public-key) (export, merge with
   the published key, check). In the same commit, change
   `build/linux/unitystack-package-signing.ci-subkey` to the spare,
   `371842FE38AD622FE03DF24609338103D3B1B0A0`: from then on the jobs that
   sign accept only the spare's secret.
3. Export the spare's secret for CI as in
   [Exporting the CI subkey](#exporting-the-ci-subkey)
   (`sub=371842FE38AD622FE03DF24609338103D3B1B0A0`; the temporary keyring
   and `gpg --passwd` to the CI passphrase) and replace
   `LINUX_GPG_PRIVATE_KEY`, and `LINUX_GPG_PASSPHRASE` if it changed (it
   should, if it may have leaked too). If the repository variable
   `LINUX_GPG_SIGN_SUBKEY` is set, set it to the spare too or delete it;
   the checks fail while it disagrees with the file.
4. Tag a release. The preflight accepts the spare, since the published key
   has it, and refuses the revoked subkey. `sign-linux` signs the packages
   with the spare, and `publish-repo` re-signs every index and publishes
   the key with the revocation.
5. Write the key without the revoked subkey for the rpm systems that
   ignore the revocation (see below), check it, and attach it to that
   release:

   ```sh
   python3 build/linux/merge-public-key.py --drop-revoked-subkeys --output unitystack-without-revoked-subkeys.asc build/linux/unitystack-package-signing.asc
   gpg --show-keys --with-subkey-fingerprints unitystack-without-revoked-subkeys.asc
   gh release upload <tag> unitystack-without-revoked-subkeys.asc -R UnityStack/DesktopEditors
   ```

6. Tell users: in that release's notes and in a pinned issue, say which
   subkey was revoked and since when, that everything signed by the spare
   is genuine, and give them the commands of
   [What users must do](#what-users-must-do) below.
7. The key now has no spare, and every check warns so. Make a new one on
   the offline machine (`gpg --quick-add-key $primary rsa4096 sign never`,
   with `primary` as in [Changing the public key](#changing-the-public-key)),
   back up its secret offline, change the public key again, and ship it in
   the next release. Only apt systems (with the package update) and new
   installs then trust it before it is needed: rpm and dnf do not import a
   key again that they already have, and rpm 4 does not add subkeys to a
   key it has (see below), so rpm users get the new spare only through the
   commands of step 6 run again. Once the new spare is in the committed
   key the checks stop warning, although those rpm systems do not trust
   it. A second spare in the key before the repository goes live, while
   no repository client has the key yet, would leave one pre-trusted
   subkey after the first emergency; it needs the offline primary key.

What reaches whom (measured Nov 2026 with a throwaway key of this layout,
`build/linux/repo/test/revocation.sh`):

- Everything the spare signs verifies on every installed system without
  any action: they have had the spare since their first install.
- apt: the package update, signed by the spare, rewrites
  `/usr/share/keyrings/unitystack.asc` with the revocation, and gpgv (as
  apt reads it) and sqv then reject the leaked subkey's signatures. The key
  files are UnityStack's, not this product's (see
  [Package repositories](#package-repositories)): once another product
  ships them, its packages need the changed key in the same emergency
  release, or an install of one of its older packages writes the old key
  back (apt), and rpm refuses whichever package carries different bytes.
- rpm: the package installs the updated key file, but rpm and dnf do not
  import a key again that they already have. Fedora's rpm 6 takes the
  revocation with `sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-unitystack`
  and then rejects the leaked subkey's packages. Tumbleweed (rpm 4.20)
  rejects them only after a fresh import (`rpm -e` of the old key first).
  rpm 4.14, 4.16 and 4.19 (Leap 15.6, RHEL 9 and 10) import the key but
  ignore the subkey revocation, on a fresh import too: they keep accepting
  the leaked subkey's packages, including systems installed after the
  emergency (dnf imports the full key from the `.repo`'s `gpgkey=`). The
  only thing that helps there is a key without the revoked subkey: with
  it, all five rpm versions tested reject the leaked subkey's package and
  accept the spare's.
- dnf keeps its own keyring per repository for `repo_gpgcheck` and never
  updates it for a primary key it knows (measured for dnf5 and dnf 4.20;
  not measured for dnf 4.14 on EL9). Deleting it makes dnf import the
  current key from `gpgkey=` again; that gpg-based keyring should then
  honour the revocation for the signed `repomd.xml` (not measured).
- Until a system has the revocation, anyone holding the leaked secret can
  sign indexes and packages it accepts, if they can also serve them (the
  site, GitHub Releases or a network path in between). Signatures made
  before the revocation look the same as the attacker's. The primary key is
  not affected, which is why it stays offline; if it leaked, only a new key
  with manual steps for every user would help.

##### What users must do

The advisory of step 6 gives these commands (`<tag>` is the release of
step 4):

- Debian, Ubuntu, Linux Mint: `sudo apt update && sudo apt upgrade`. The
  updated package carries the key with the revocation.
- Fedora (rpm 6, dnf5), after `sudo dnf upgrade --refresh` installed the
  package with the updated key file:

  ```sh
  sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-unitystack
  sudo rm -rf /var/cache/libdnf5/euro-office*/pubring
  ```

- RHEL, AlmaLinux, Rocky Linux 9 and 10, openSUSE Leap and Tumbleweed (rpm
  4): rpm keeps accepting the revoked subkey with the normal key, so
  replace it by the key without that subkey, after checking that
  `gpg --show-keys` shows the primary key `62E1 6713 ... 3A2B 29ED`:

  ```sh
  curl -fsSLO https://github.com/UnityStack/DesktopEditors/releases/download/<tag>/unitystack-without-revoked-subkeys.asc
  gpg --show-keys unitystack-without-revoked-subkeys.asc
  sudo rpm -e gpg-pubkey-3a2b29ed
  sudo rpm --import unitystack-without-revoked-subkeys.asc
  sudo rm -rf /var/cache/dnf/euro-office*/pubring
  ```

  The last line is for dnf (RHEL and its rebuilds); zypper asks to trust
  the key again on the next `zypper refresh`. A system that later imports
  the full key again (a new install, or `rpm --import` of the packaged
  key file) trusts the revoked subkey again on these rpm versions.

##### Why the spare is in the key from the start

A subkey added later reaches installed systems only partly (measured Nov
2026, containers: Ubuntu 22.04/24.04, Debian 12/13, Fedora 43, Rocky 9 and
10, openSUSE Leap 15.6 and Tumbleweed):

- apt gets a changed key only through a package update, since the `.deb`
  rewrites `/usr/share/keyrings/unitystack.asc`. If the repository is
  signed by a new subkey before that update arrived, `apt-get update`
  prints `W:` lines, keeps the old lists and exits 0: the system silently
  stops updating. Fresh installs fail.
- `rpm --import` of the updated key adds new subkeys only on rpm 6
  (Fedora). rpm 4.14 (Leap 15.6), 4.16 (EL9), 4.19 (EL10) and 4.20.1
  (Tumbleweed) exit 0 and change nothing. Users must remove the old key
  first (rpm 4 names it `gpg-pubkey-3a2b29ed-<release>`):

  ```sh
  rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n'
  sudo rpm -e gpg-pubkey-3a2b29ed
  sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-unitystack
  ```

- dnf5 (Fedora) and dnf 4.20 (EL10) also keep a keyring per repository
  for `repo_gpgcheck`, which they never update for a primary key they know
  and which `dnf clean all` does not clear. Fedora then silently skips the
  repository (`skip_if_unavailable=1`). Users delete it, on dnf5 with the
  first line, on dnf 4.20 with the second:

  ```sh
  sudo rm -rf /var/cache/libdnf5/euro-office*/pubring
  sudo rm -rf /var/cache/dnf/euro-office*/pubring
  ```

- zypper on Leap asks to trust the new key on the next interactive
  `zypper refresh` (or takes it with `--gpg-auto-import-keys`); Tumbleweed
  needs the `rpm -e` and re-import above.

##### If no published subkey is left

If no published subkey is left to sign with (the spare leaked too, or was
used and no new one was shipped yet), make a new signing subkey, set the
repository variable `LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY` to its fingerprint
for one release (a warning instead of the error that the published key
lacks it), and delete the variable afterwards. Every rpm-based system then
needs the manual steps above, and apt systems the package update by hand.

#### A subkey with an expiry

If a signing subkey ever has an expiry, tag builds warn from 180 days before
it and fail from 90 days before (see [The checks](#the-checks)). Extend it
on the offline machine with `gpg --quick-set-expire $primary <date>
<subkey-fpr>` (or `never`), change the public key as in
[Changing the public key](#changing-the-public-key) (the old binding must
stay), export the CI secret again if it is CI's subkey, and publish a
release before the old date: installed systems go by the expiry in the key
they have, and the checks go by the earlier of the committed and the
published one.

#### The checks

`build/linux/select-signing-subkey.sh` does all of them (the table test
`build/linux/repo/test/select-subkey.sh` covers each rule):

| Where | When | Fails | Warns |
|---|---|---|---|
| `signing-preflight` in `build.yml`, with the secret | `v*` tags, before every build job | the secret holds no or several signing subkeys, or the primary key's secret; it holds another subkey than `unitystack-package-signing.ci-subkey` (and `LINUX_GPG_SIGN_SUBKEY`, if set) designates, or the two disagree; the committed key file holds secret key material, more than one armored block or not exactly one key; the committed key lacks the subkey or binds it differently; it is revoked or expired there or in the published key, or the published key lacks it; the site serves secret key material; the committed key lacks a signature packet of the published key, or has a subkey revocation before a binding; not every released signature could be downloaded; a signature of the newest 10 releases does not verify with the committed key, or was made before every binding of its subkey there; the test signature fails (passphrase); a subkey with an expiry has fewer than 90 days left (`FAIL_DAYS`) | no spare; the committed key lists the published key's subkeys in another order; a subkey with an expiry has fewer than 180 days left (`WARN_DAYS`); the published key states another expiry |
| import step of `sign-linux` and `publish-repo` (`--after-build`) | tags | the same without the released signatures, and an expiring subkey only under 60 days (`FAIL_DAYS` minus `RERUN_DAYS`, 30: a re-run can come up to 30 days after the preflight passed); `publish-repo.sh` also refuses to publish a key file with secret material or several blocks | the same, and from 90 days |
| `signing-key` in `build.yml`, public key only | every push, PR and dispatch | never blocks; error annotations: no valid signing subkey; the designated subkey is not valid, or the file and the variable disagree; the key file errors above; the committed key lacks a signature packet of the published key, or has a revocation before a binding; a released signature fails as above; the subkey CI holds expires within 90 days | no spare; not every released signature could be downloaded; the newest verified signature is by another subkey than the designated one; another subkey order; a valid subkey expires within 180 days; a valid subkey is not in the published key; the primary key expires; the site serves another key (key material, or it lacks signatures of the committed key); `signing-key-check.yml` is disabled |
| `signing-key-check.yml`, public key only | 05:23 UTC on the 1st of every month, and by hand | the errors of `signing-key`; the site serves another key than the committed one (until the release after a key change, too); once live, the site serves no key or no index files; an `InRelease` or `repomd.xml.asc` on the site is signed by a revoked or expired subkey, or one with fewer than 90 days left | as `signing-key`; site signatures by a subkey with fewer than 180 days left |

- *The subkey CI holds*: signing mode sees it in the secret and requires
  it to be the designated one (`build/linux/unitystack-package-signing.ci-subkey`,
  and `LINUX_GPG_SIGN_SUBKEY` if set). The public checks cannot read the
  secret; they name it from the designation, else from the signer of the
  newest signature they verified (the site's `InRelease` and
  `repomd.xml.asc`, or the releases' `SHA256SUMS-linux-<arch>.txt.asc`),
  else it is the only valid signing subkey, and warn when that signer is
  not the designated subkey. They do not need it to find the spare: signing
  mode makes sure CI holds exactly one signing subkey, so with two valid
  ones, one is a spare.
- *The key file*: exactly one public key in one armored block. gpg would
  import a secret key just as well, and the packages and the site would
  then publish it; and it merges several blocks into one key, while rpm 4
  imports only the first block (measured Nov 2026: Rocky 9, AlmaLinux 10,
  Leap 15.6 and Tumbleweed import two concatenated exports with exit 0 and
  keep only the first).
- *Released signatures*: the `SHA256SUMS-linux-<arch>.txt.asc` of the
  newest 10 releases (`build/linux/fetch-released-signatures.sh`; 10 is
  what a repository channel lists). `sign-linux` signs them with the same
  subkey and in the same run as the RPMs. Each must verify with the
  committed key (gpgv), and the committed key must hold a binding of its
  subkey and a self-signature of the primary key made no later than the
  signature, which is what rpm 6 and sqv require. A signature of a subkey
  the committed key revokes is only a notice. If the GitHub API fails while
  they are downloaded, the download step goes on and records it; the
  preflight then fails (it signs nothing it could not check), the public
  checks warn.
- *Published key*: `https://packages.unitystack.eu/keys/unitystack.asc`,
  the key installed systems got (`--check-signatures` reads the index files
  from `https://packages.unitystack.eu/euro-office/`). Every signature
  packet in it must be in the committed key (bindings, revocations,
  self-signatures, compared by their hashed content), and its subkeys must
  come first in the committed key, in the same order. A published key that lacks packets of the
  committed one (after a key change, until the release) is reported as
  different, never as the committed one. Until the host answers, or while it answers 404,
  it is not checked (a notice); another HTTP error or a body that is not a
  key skips the check with a warning. Once the `packages` branch exists the
  watchdog treats the repository as live (`--live`): then an unreachable
  key, or a site without any `InRelease` and `repomd.xml.asc`, is an error,
  so an outage does not pass as healthy.
- *Expiry*, for a subkey that has one: the earlier of what the committed
  and the published key state (a subkey cannot outlive its primary key,
  either). Installed systems reject its signatures from the date in their
  key.
- `signing-key-check.yml` opens one issue, *Linux package signing key needs
  attention*, on errors and on warnings (the script exits 3 for warnings
  only), updates and comments on it while that lasts, and closes it once a
  run reports neither. Errors also fail the run. Issues must be turned on
  for this (see [Repository settings](#repository-settings)); while they
  are off, warnings fail the run as well, and GitHub notifies the user who
  last changed the workflow's cron line.
- GitHub disables the schedule of `signing-key-check.yml` after 60 days
  without activity in this public repository. `signing-key` then warns on
  the next push or PR; enable it again with
  `gh workflow enable signing-key-check.yml -R UnityStack/DesktopEditors`.

The day thresholds only apply to a subkey with an expiry: 90 days leave a
quarter in which it still signs, so a release can re-sign the repository
before apt and dnf reject the old signatures; 180 days warn two quarters
ahead; 30 days are how long GitHub lets a run be re-run, so the jobs after
the build accept 60. `TEST_NOW`, `TEST_KEY_URL` and `TEST_REPO_URL` exist for
the table test only; the script refuses them under GitHub Actions.

#### Fingerprints users see

What users should check is the primary key, `62E1 6713 F445 9962 B020  2B01
038A B9E6 3A2B 29ED`: `gpg --show-keys` shows it first, rpm 4 names the
imported key `gpg-pubkey-3a2b29ed` (its short key ID) and rpm 6 (Fedora 43)
`gpg-pubkey-62e16713f4459962b0202b01038ab9e63a2b29ed` (the whole
fingerprint), and dnf5, dnf 4.20 and zypper show it when they ask to import
the key. Some tools show a subkey instead:

- dnf 4.14 (RHEL, AlmaLinux and Rocky Linux 9) shows the **first** signing
  subkey in the key file, whichever subkey signed: today
  `E94F 0929 2FC4 6A1B B63A  50E4 A4A6 410F 8A26 DCC6`. It stays first as
  long as the key is changed as in
  [Changing the public key](#changing-the-public-key)
  (`merge-public-key.py` keeps the order, and the checks warn when it
  changes).
- `gpg --verify` of a `SHA256SUMS-linux-<arch>.txt.asc` and `rpm -Kv` show
  the subkey that signed it:

| Signing subkey | Fingerprint | Expires | In CI |
|---|---|---|---|
| current | `E94F 0929 2FC4 6A1B B63A  50E4 A4A6 410F 8A26 DCC6` | never | from the first release |
| spare | `3718 42FE 38AD 622F E03D  F246 0933 8103 D3B1 B0A0` | never | only if the current one is revoked |

### Verifying a download

Check that the key's fingerprint is
`62E1 6713 F445 9962 B020  2B01 038A B9E6 3A2B 29ED` before trusting it.
`gpg --verify` names the signing subkey that signed, one of those in
[Fingerprints users see](#fingerprints-users-see):

```sh
gpg --show-keys unitystack-package-signing.asc
gpg --import unitystack-package-signing.asc

# Checksums (all package types). sha256sum warns about the
# signature lines; that is expected. The help packages (_all.deb,
# .noarch.rpm, -any.tar.xz; releases before 9.3.8 only) are listed in
# SHA256SUMS-linux-amd64 only.
gpg --verify SHA256SUMS-linux-amd64.txt.asc
sha256sum --ignore-missing -c SHA256SUMS-linux-amd64.txt.asc

# RPM signature (should print "digests signatures OK")
sudo rpm --import unitystack-package-signing.asc
rpm -K euro-office-*.rpm
```

## Package repositories

`https://packages.unitystack.eu/euro-office/` serves signed package
repositories for apt (Debian, Ubuntu, Linux Mint), dnf (Fedora, RHEL,
AlmaLinux, Rocky Linux) and zypper (openSUSE). Users install once and get
updates through their package manager. The apt repository also carries AppStream (DEP-11) data, so
software centres such as the Ubuntu App Center show the publisher (UnityStack
GmbH), the licence (AGPL-3.0-only AND CC-BY-SA-4.0) and the icon instead of "Unknown
publisher" and "Potentially unsafe".

The `.deb` and `.rpm` from the releases page add the repository themselves
when they are installed (see [Opting out](#opting-out)), the way Chrome's
packages do. The commands below are for users who want to add it first.

`packages.unitystack.eu` is UnityStack's package host, shared with the
repositories of its other products: each product has its own path below it,
and all of them are signed with the one key
`https://packages.unitystack.eu/keys/unitystack.asc`. Clients therefore keep
the key under UnityStack's name, `/usr/share/keyrings/unitystack.asc` (apt)
and `/etc/pki/rpm-gpg/RPM-GPG-KEY-unitystack` (rpm), while the repository
files and ids (`euro-office.sources`, `euro-office.repo`, `[euro-office]`)
name the product. The host is a plain directory listing like other package
hosts; `https://packages.unitystack.eu/euro-office/README.txt` has the
commands below in short.

Until a second UnityStack product ships these files, sharing them is a
promise only: the `.deb` writes its own copy of the key to the keyring on
every install and upgrade, and the `.rpm` carries
`/etc/pki/rpm-gpg/RPM-GPG-KEY-unitystack` as payload. Two products may share
them only while every package of both carries the same key, byte for byte:
with different bytes rpm refuses the second package (a file conflict, also
with `%config(noreplace)`), and an older `.deb` would overwrite a newer key,
undoing a revocation. Before a second product uses the key, move the key
files into a package of their own that every product depends on.

### Checking the key

Everything in the repository is signed with a
[signing subkey](#signing-key) of `unitystack-package-signing.asc`, published
as `https://packages.unitystack.eu/keys/unitystack.asc`. Before trusting
it, check that the primary key fingerprint is
`62E1 6713 F445 9962 B020  2B01 038A B9E6 3A2B 29ED`:

```sh
curl -fsSL https://packages.unitystack.eu/keys/unitystack.asc | gpg --show-keys
```

### apt (Debian 12+, Ubuntu 22.04+, Linux Mint 21+)

```sh
sudo curl -fsSL -o /usr/share/keyrings/unitystack.asc \
  https://packages.unitystack.eu/keys/unitystack.asc
gpg --show-keys /usr/share/keyrings/unitystack.asc       # check the fingerprint
sudo curl -fsSL -o /etc/apt/sources.list.d/euro-office.sources \
  https://packages.unitystack.eu/euro-office/apt/euro-office.sources
sudo apt update
sudo apt install euro-office-euro-office
```

`euro-office.sources` uses `Signed-By: /usr/share/keyrings/unitystack.asc`,
so the key is trusted for the sources that name it only, not for the whole
system.
The packages write the key to the same path on every install and upgrade. The
key holds the spare signing subkey as well, so switching CI to it needs
nothing from users; a change to the key (a revocation, a new spare) reaches
apt users with the next package update (see [Signing key](#signing-key)).

### dnf (Fedora, RHEL 9+, AlmaLinux, Rocky Linux)

RHEL 8 and its rebuilds lack `xcb-util-cursor`; enable EPEL there first
(`sudo dnf install epel-release`). RHEL 9 and 10 need nothing besides their
own repositories.

```sh
curl -fsSL -o unitystack.asc https://packages.unitystack.eu/keys/unitystack.asc
gpg --show-keys unitystack.asc                           # check the fingerprint
sudo rpm --import unitystack.asc
sudo curl -fsSL -o /etc/yum.repos.d/euro-office.repo \
  https://packages.unitystack.eu/euro-office/rpm/euro-office.repo
sudo dnf install euro-office-euro-office
```

If the key was imported before, for example to test `v9.3.6-ce.rc.1`
(whose instructions imported a key without the spare), rpm 4 (RHEL,
AlmaLinux, Rocky Linux, openSUSE) keeps that old copy: `rpm --import` of
the current key exits 0 and changes nothing, so the spare signing subkey
never arrives. If `rpm -q gpg-pubkey-3a2b29ed` lists it, remove it first
with `sudo rpm -e gpg-pubkey-3a2b29ed`, then import the current key as
above. Fedora's rpm 6 adds the new subkey on `rpm --import` without that
(measured Nov 2026 with rc.1's key and the current one: Rocky 9,
AlmaLinux 10, Leap 15.6 and Tumbleweed kept one subkey until the `rpm -e`,
then had both; Fedora 43 had both after the plain import).

The `.repo` sets `gpgcheck=1` (package signatures) and `repo_gpgcheck=1`
(signed `repomd.xml`). dnf keeps the keys for `repo_gpgcheck` in a keyring of
its own, so on the first `dnf` run it still offers to import the key from the
`gpgkey=` URL and shows a fingerprint: dnf5 and dnf 4.20 (EL10) show the
primary key's above, dnf 4.14 (EL9) the first signing subkey's in the key
file, whichever subkey signed: today
`E94F 0929 2FC4 6A1B B63A  50E4 A4A6 410F 8A26 DCC6` (see
[Fingerprints users see](#fingerprints-users-see)).

### zypper (openSUSE)

```sh
curl -fsSL -o unitystack.asc https://packages.unitystack.eu/keys/unitystack.asc
gpg --show-keys unitystack.asc                           # check the fingerprint
sudo rpm --import unitystack.asc
sudo zypper addrepo https://packages.unitystack.eu/euro-office/rpm/euro-office.repo
sudo zypper install euro-office-euro-office
```

The same holds for a key imported before (see [dnf](#dnf-fedora-rhel-9-almalinux-rocky-linux)):
`sudo rpm -e gpg-pubkey-3a2b29ed` first if `rpm -q gpg-pubkey-3a2b29ed`
lists it.

openSUSE uses the same RPM as Fedora: its `Requires` name libraries by
soname and fonts as "Fedora name or openSUSE name" (see `package.patch`).
`v9.3.6-ce.rc.1` predates that and requires Fedora package names
(`boost-filesystem`, `xcb-util-cursor`, ...), so zypper cannot install it.
The `.repo` sets `pkg_gpgcheck=1`: with a signed `repomd.xml`, zypper
otherwise skips the package signature (`zypper lr -d` shows `(r )` instead
of `(rp)`). Do not use `--gpg-auto-import-keys`: it trusts whatever key the
server sends.

### Channels

| Channel | apt suite | rpm repository | Contains |
|---|---|---|---|
| stable | `stable` | `rpm/stable/` (`euro-office.repo`) | final releases (`v9.3.6-ce`, rebuilds such as `v9.3.6-ce.1`) |
| testing | `testing` | `rpm/testing/` (`euro-office-testing.repo`) | stable plus release candidates, betas and alphas (`v9.3.6-ce.rc.2`, ...) |

To follow testing, download `apt/euro-office-testing.sources` or
`rpm/euro-office-testing.repo` instead of the stable file (or change
`Suites: stable` to `testing`, or the `baseurl` to `rpm/testing/`). A package
installed from a prerelease (version containing `~rc`, `~beta` or `~alpha`)
registers the testing channel, a final release the stable one. The registered
file is not changed later; edit it to switch.

Each channel lists the newest 10 releases (by package version). Older ones
stay downloadable from the GitHub releases page.

### Opting out

Before installing the package, create `/etc/default/euro-office` empty or with

```sh
repo_add="false"
```

and the package adds no repository. If you delete the repository file that a
package wrote (`/etc/apt/sources.list.d/euro-office.sources`,
`/etc/yum.repos.d/euro-office.repo` or `/etc/zypp/repos.d/euro-office.repo`),
it is not written again: the first install records that state in
`/etc/default/euro-office`. Purging the `.deb` (`apt purge`) removes the
repository file and that state file if the package wrote them, and the key
unless another apt source still uses it (such as one you added by hand, or
the repository of another UnityStack product); erasing the RPM removes the
`.repo` file and the state file, if the package wrote them, and leaves the
imported key in the rpm database for those other repositories. A defaults
file or repository file you created yourself is left alone, so an opt-out
survives a purge and a reinstall.

### Testers of v9.3.6-ce.rc.1

`v9.3.6-ce.rc.1` was built with the package version `9.3.6-0~ce.rc.1`. Later
tags use `9.3.6-0~ce~rc.2`, `9.3.6-0~ce`, ... so that release candidates sort
before the final release, but rc.1 sorts *above* all of them (`.rc` compares
after `~rc` and after the end of the version). rc.1 also predates the
repository and does not register it, and it is never added to the
repository (`publish-repo.sh` refuses it): in a channel it would be offered as
an upgrade to every later 9.3.6 build. Testers who installed rc.1 add the
testing channel as above and reinstall once (apt would otherwise keep rc.1;
dnf and zypper would upgrade only from `9.3.6-0~ce.1` on):

```sh
# apt
sudo apt remove euro-office-euro-office euro-office-euro-office-help
sudo apt install euro-office-euro-office
# dnf / zypper
sudo dnf remove euro-office-euro-office && sudo dnf install euro-office-euro-office
sudo zypper remove euro-office-euro-office && sudo zypper install euro-office-euro-office
```

rc.1's instructions had rpm users import the key as it was then, without
the spare signing subkey. On rpm 4 (RHEL, AlmaLinux, Rocky Linux,
openSUSE) a later `rpm --import` does not add it, so remove that key
before adding the repository, then import the current one as in
[dnf](#dnf-fedora-rhel-9-almalinux-rocky-linux) or
[zypper](#zypper-opensuse):

```sh
sudo rpm -e gpg-pubkey-3a2b29ed
```

Fedora (rpm 6) needs only the `rpm --import` of the current key.

Settings and documents in the home directory are kept.

### How CI publishes

The `publish-repo` job in `.github/workflows/build.yml` runs on tags after
`publish-release`, in the `signing` environment, one tag at a time. It
downloads the tag's `.deb` and `.rpm` from the GitHub release, imports the
signing subkey like `sign-linux`, runs `build/linux/repo/publish-repo.sh`,
checks the signatures and pushes the result to the orphan branch `packages`,
which GitHub Pages serves at `https://unitystack.github.io/DesktopEditors/`.
Stable tags go to both channels, prereleases to testing only.

The branch holds only metadata, a few hundred kilobytes per release:

```
README.txt, .nojekyll         plain-text instructions: apt, dnf, zypper, the key and its fingerprint
index.html in each directory  its listing, "Index of /euro-office/...", in the form of nginx's autoindex
apt/pool/<tag>/, rpm/<channel>/packages/<tag>/
                              listings only: the package files the indexes name (see below)
keys/unitystack.{asc,gpg}     public key, armored and binary
apt/euro-office{,-testing}.sources
apt/dists/<suite>/            InRelease, Release, Release.gpg; main/binary-{amd64,arm64}/Packages*,
                              main/dep11/ (AppStream), by-hash/
apt/icons/euro-office-256.png AppStream icon
rpm/euro-office{,-testing}.repo
rpm/<channel>/repodata/       repomd.xml, repomd.xml.asc, repomd.xml.key, ...
macos/appcast{,-testing}.xml  Sparkle feeds of the macOS app (build/macos/README.md, "Automatic updates")
.state/                       per-release fragments the indexes and feeds are rebuilt from
```

The nginx of `packages.unitystack.eu` (fluxcd-org-apps) serves the branch
below `/euro-office/` and its `keys/unitystack.asc` as `/keys/unitystack.asc`;
`/` and `/keys/` are listings of their own in the same form, and nothing else
is taken from Pages:

| `https://packages.unitystack.eu`... | Served from |
|---|---|
| `/`, `/keys/` | nginx itself (listings of `euro-office/`, `keys/` and `unitystack.asc`) |
| `/keys/unitystack.asc` | `https://unitystack.github.io/DesktopEditors/keys/unitystack.asc` |
| `/euro-office/<path>` | `https://unitystack.github.io/DesktopEditors/<path>`, except the package paths below |

The packages themselves stay on GitHub Releases. The indexes name them
`apt/pool/<tag>/<asset>` and `rpm/<channel>/packages/<tag>/<asset>`, and nginx
answers those paths below `/euro-office/` with a 302 to
`https://github.com/UnityStack/DesktopEditors/releases/download/<tag>/<asset>`. `<asset>` is GitHub's name for the
uploaded file, which replaces the `~` of the package version with `.`, so
`publish-repo.sh` matches local files to release assets by SHA-256 (the
`digest` of the release API), never by file name.

`publish-repo.sh`, in short:

- Writes this tag's fragments to `.state/`: its apt `Packages` stanzas, its
  AppStream component (from `/usr/share/metainfo/org.euro_office.desktopeditors.metainfo.xml`
  in the `.deb`, or rendered from `build/linux/package/common/linux/metainfo.xml.m4`
  for packages that predate it, such as rc.1) with 64 and 128 px icons, and
  its rpm repodata (`createrepo_c`). Re-running a tag replaces them, so the
  job can be re-run safely.
- Rebuilds every suite from the fragments: `Packages`, DEP-11
  `Components-<arch>.yml` and icon tarballs, `Release` with
  `Acquire-By-Hash: yes` (`apt-ftparchive`), signed as `InRelease` and
  `Release.gpg`. It merges the rpm repodata of the channel's releases with
  `mergerepo_c --all --omit-baseurl` (no old RPM files needed; zypper ignores
  `xml:base`, so the hrefs stay relative) and signs `repomd.xml`.
- Keeps the by-hash files of the last three `Release` generations and the
  repodata files of the last three `repomd.xml` generations, so a client
  that read an old index a moment before the update (or got it from a cache)
  still finds its files. Only a run that changed a suite or channel starts a
  new generation there; a re-run or a publish to the other channel does not
  use one up.
- Refuses a tag whose package version another published tag already has,
  and anything built with the old `0~ce.rc.N` scheme (see
  [Testers of v9.3.6-ce.rc.1](#testers-of-v936-cerc1)).
- Checks that every `.deb` and `.rpm` reads completely (`dpkg-deb`, `rpm -K
  --nosignature`) before indexing it: the indexes vouch for those bytes.
- Builds the new tree in a temporary directory, checks every signature with
  `gpgv` against the published key, and only then replaces the site. A
  failed run leaves `site/` untouched.
- Writes `README.txt` from `templates/README.txt.in`, then a listing,
  `index.html`, into every directory (`autoindex.py`): GitHub Pages lists no
  directories, so each answers as nginx's `autoindex` would, "Index of" the
  path, the entries with date and size, directories first, no other text.
  `apt/pool/` and `rpm/<channel>/packages/` get listings of the tags and
  package files the indexes name, which nginx redirects. An entry keeps its
  date while its content (for a directory: the names in it) stays the same
  (`.state/listing.tsv`), so an unchanged tree gives the same listings.
- Adds the tag's macOS update (`--macos-update`, `--macos-dmg`,
  `--macos-notes`) to `.state/macos/` and writes the Sparkle feeds
  `macos/appcast.xml` and `macos/appcast-testing.xml` from it with
  `build/macos/appcast.py`, which first checks the update's EdDSA signature
  on the DMG of the release (see "Automatic updates (Sparkle)" in
  [build/macos/README.md](../macos/README.md#automatic-updates-sparkle)).
- Writes `.state/format`. A site written by a newer `publish-repo.sh` (a
  higher format) is refused, so re-running `publish-repo` of an older tag
  after the tooling changed cannot rebuild the site with the older script;
  re-run it from a newer tag instead. Bump `STATE_FORMAT` in the script when
  the fragments, templates or generated files change in a way an older
  script must not undo.

To run it locally (the throwaway key is the test harness's, see below):

```sh
SIGN_FPR=<signing subkey fpr> GNUPGHOME=<keyring> \
  build/linux/repo/publish-repo.sh --tag v9.3.6-ce.rc.2 --channel prerelease \
    --packages <dir with the .deb/.rpm> --site <scratch dir>
```

`v9.3.6-ce.rc.1` must never be added to the repository; the tests publish it
only to throwaway sites, with `ALLOW_OLD_SCHEME=1`.

#### Re-runs and replaced assets

`publish-release` uploads the assets a release lacks and skips those it
already has with the same SHA-256. A rebuild never has the same bytes (rpm
signatures differ), and the repository describes the assets by hash, so
"Re-run all jobs" or a dispatch on a published tag fails there instead of
breaking apt and dnf with hash mismatches. Cut a new tag (`v9.3.6-ce.1`)
instead. Only while `publish-repo` has not published the tag yet, run the
workflow on the tag with `replace_assets` checked. "Re-run failed jobs"
reuses the signed artifacts and is always safe.

#### Repository settings

The signing environment hands the key and a `contents: write` token to any
`v*` tag, and every installed package trusts what that key signs. Apply on
`UnityStack/DesktopEditors` (Settings, Rules, Rulesets):

- a tag ruleset on `refs/tags/v*` that restricts creation, update and
  deletion to the release managers,
- a branch ruleset on `packages` that blocks force pushes and deletion and
  restricts updates, with GitHub Actions and the release managers as bypass
  (the first publish creates the branch, so add the ruleset before it or
  right after),
- on the `signing` environment (Settings, Environments), which holds
  `LINUX_GPG_PRIVATE_KEY`: required reviewers (the release managers; they
  are asked once per tag run, at the start, by `signing-preflight`),
  "Prevent self-review" if there is more than one release manager, "Allow
  administrators to bypass configured protection rules" off, and the
  deployment branches and tags rule "Selected branches and tags" with the
  single tag pattern `v*` (the `if:` of `signing-preflight` matches it),
- GitHub Pages (Settings, Pages): source "Deploy from a branch", branch
  `packages`, folder `/ (root)`, and no custom domain: the nginx of
  fluxcd-org-apps serves `packages.unitystack.eu/euro-office/` from
  `https://unitystack.github.io/DesktopEditors/` (see
  [How CI publishes](#how-ci-publishes)). It can be set only once the first
  publish created the branch (see `PACKAGES_PAGES_BOOTSTRAP` below),
- Issues turned on (Settings, General, Features): `signing-key-check.yml`
  reports through one issue. Forks have them off, and so does this one so
  far; without them the watchdog can only fail its run,
- `signing-key-check.yml` enabled (Actions); GitHub disables its schedule
  after 60 days without activity, see [The checks](#the-checks).

The Release files carry no `Valid-Until`: it would need a scheduled re-sign,
that is, the signing key outside tag runs.

Repository variables the jobs read: `LINUX_GPG_SIGN_SUBKEY` (optional, see
[Signing key](#signing-key)), `LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY` (only
when no published subkey is left, see
[If the CI secret leaks](#if-the-ci-secret-leaks)) and
`PACKAGES_PAGES_BOOTSTRAP`. Set the latter to
`true` for the very first publish only: Pages can be enabled for the branch
`packages` only once it exists, so that run's Pages build request fails and
the variable turns the failure into a warning. Afterwards `publish-repo`
fails unless Pages has built the commit it pushed.

### Testing the repository

`build/linux/repo/test/run.sh` (Docker and an authenticated `gh`) first runs
`select-subkey.sh`, the table test of `build/linux/select-signing-subkey.sh`
(both modes, with throwaway keys dated 2010 to 2019 that replay the real
key's history: a subkey bound with an expiry, a release signed with it, the
re-binding without expiry, a spare; the exports that lose the old binding,
one or two secrets in CI, the designation of CI's subkey, key files with
secret material or two armored blocks, an incomplete download of the
released signatures, the subkey order, the revocation and the move to the
spare, the expiry thresholds to the second, `--after-build`, the published
key in both directions, `--released`, `--live` and `--check-signatures`)
and `build/linux/merge-public-key.py`.
It then builds a site from the real assets of `v9.3.6-ce.rc.1` (only the host
architecture's packages are downloaded) with a throwaway signing key of the
same layout and history (`make-key.sh`: subkey 1 bound with an expiry, a
small RPM signed with it, subkey 1 re-bound without expiry, a spare; the
key is merged with `merge-public-key.py` as in
[Changing the public key](#changing-the-public-key) and carries both
bindings, and CI holds and signs with subkey 1), publishes
it twice and checks that nothing changed, runs `check-site.sh` (signatures,
by-hash, hrefs, `README.txt`, and that every listing names exactly its
directory's entries, below `apt/pool/` and `rpm/<channel>/packages/` those
of the indexes) and `channels.sh` (channels, the 10-release window,
retention, the listings' dates, failure paths, with small fake packages),
and `maintainer-scripts.sh`: the `.deb` scripts and the `.rpm` scriptlets
that register the repository, built from `desktop-apps/package` with
`package.patch` and `fork.mk`'s defaults, installed, removed and purged in
debian:13 (with a second product sharing the keyring) and fedora:43. It
serves the site through the real nginx config of `packages.unitystack.eu`
from fluxcd-org-apps (`NGINX_CONF`; only the Pages upstream is swapped for a
local container), checks the listings of `/`, `/keys/` (the size of the
committed key) and of the site's directories, and that a path with a line
feed reaches Pages below `/DesktopEditors/` too, so the clients read the
repository below `/euro-office/` and the key from `/keys/unitystack.asc` as
in production, and runs these clients with signature checks on:

| Client | Checks |
|---|---|
| ubuntu:24.04 | `apt update`, `apt-get install`, AppStream: `appstreamcli get` shows developer and licence |
| ubuntu:22.04, debian:12, debian:13 | `apt update`, `apt-get install` |
| fedora:43 (dnf5), rockylinux:9 (dnf4) | `dnf makecache` with `repo_gpgcheck=1`, `dnf install` with `gpgcheck=1` |
| opensuse/leap:15.6 | `rpm --import` of the key URL, `zypper addrepo` of the `.repo` URL, `zypper refresh`, `zypper install` with `(rp)` signature checks |

`INSTALL=download` only fetches the package (`apt-get install
--download-only`, `dnf download`, `zypper download`, each with `rpm -K`)
instead of installing it with its dependencies. The rc.1 RPMs are signed with
the real key's `E94F...` before its re-binding, the test repository with the
throwaway key, so the rpm clients import both; on fedora:43 the rc.1 install
with `gpgcheck=1` therefore checks that the committed key still carries the
old binding. Each rpm client also runs `rpm -K` on the small RPM signed
before the throwaway subkey's re-binding (and checks that the signature is
that subkey's), and a fedora:43 control shows that the same RPM fails with
the key that has only the new binding. `PACKAGE_KEY` names another key for
the release RPMs than the committed one. For `v9.3.6-ce.rc.1` (Fedora package names, see above) the zypper
client first installs a test-only package that provides exactly the names
openSUSE lacks, and says so.

Each client must fetch the package through the 302 to GitHub (checked in the
nginx log). Name clients to run a subset: `run.sh ubuntu:24.04`.

`build/linux/repo/test/revocation.sh` (Docker only, not part of `run.sh`)
replays [If the CI secret leaks](#if-the-ci-secret-leaks) with a throwaway
key whose revoked form is merged with `merge-public-key.py` as the README
says: fedora:43, Rocky Linux 9, AlmaLinux 10, openSUSE Leap 15.6 and
Tumbleweed must import it on a fresh and on an updated system and verify
the spare's package, and the advisory's remedy for rpm (the key removed and
imported without the revoked subkey) must make each reject the revoked
subkey's package; gpgv and sqv must reject the revoked subkey's signature
and accept the spare's. It prints how each rpm treats the revoked subkey's
package otherwise, and that rpm 4.14 and 4.16 refuse a key with the
revocation in front of the bindings (with one binding or both).

The help `.deb` of `v9.3.6-ce.rc.1` on the release carries 144 trailing bytes
after its last `ar` member (both arch builds produced a help `.deb` of the same
name, and one overwrote the other in `publish-release`; fixed from the next
tag on, see [Signing in CI](#signing-in-ci-fork)). dpkg ignores them;
`apt-ftparchive` rejects the file, so for that tag only `publish-repo.sh`
writes the package's `Packages` entry from `dpkg-deb` and prints a warning.
For any other tag an unparsable `.deb` fails the run.
