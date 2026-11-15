#!/bin/sh

set -e

# Registers the signed apt repository once, like Chrome does: if no apt source
# points at it yet and the admin did not opt out, write a deb822 .sources file
# and record repo_add="false" in the defaults file, so a removed .sources file
# is not recreated by later upgrades.
#
# Opt-out before installing: an empty defaults file, or one containing
#   repo_add="false"
#
# The key is not dpkg payload: it is (re)written on every configure while the
# repository is in use, and it survives "remove" (purge deletes it unless
# another apt source uses it). Rewriting it is how apt users get a changed
# key (a revocation, a new spare subkey): with a package update that is
# still signed by a subkey they have (build/linux/README.md, "Signing
# key"). It is UnityStack's key, not this product's: the repositories of
# UnityStack's other products are to use the same keyring file, which needs
# the same key in all their packages (see fork.mk).

PACKAGE="M4_PACKAGE_NAME"
REPO_URI="M4_REPO_URL/apt"
DEFAULTS="/etc/default/M4_REPO_NAME"
SOURCES="/etc/apt/sources.list.d/M4_REPO_NAME.sources"
KEYRING="/usr/share/keyrings/M4_REPO_KEY_NAME.asc"

# Prereleases come from the testing suite (stable + prereleases).
case "M4_PACKAGE_VERSION" in
  *~rc*|*~beta*|*~alpha*) SUITE=testing ;;
  *) SUITE=stable ;;
esac

repo_add_setting() {
  # Prints "false" when the admin opted out or the repository was added before.
  if [ -f "$DEFAULTS" ] && [ ! -s "$DEFAULTS" ]; then
    echo false
  elif [ -f "$DEFAULTS" ]; then
    sed -n 's/^[[:space:]]*repo_add=//p' "$DEFAULTS" | tail -n 1 | tr -d "\"' "
  fi
}

repo_in_use() {
  grep -rqsF "${REPO_URI#*://}" /etc/apt/sources.list /etc/apt/sources.list.d/
}

write_key() {
  mkdir -p "$(dirname "$KEYRING")"
  cat > "$KEYRING.dpkg-tmp" <<'EOF'
undivert(M4_REPO_KEY)dnl
EOF
  chmod 0644 "$KEYRING.dpkg-tmp"
  mv -f "$KEYRING.dpkg-tmp" "$KEYRING"
}

write_sources() {
  cat > "$SOURCES.dpkg-tmp" <<EOF
# Written by the $PACKAGE package. Remove this file to stop
# updates; it is not recreated (set repo_add="false" in $DEFAULTS).
Types: deb
URIs: $REPO_URI
Suites: $SUITE
Components: main
Architectures: amd64 arm64
Signed-By: $KEYRING
EOF
  chmod 0644 "$SOURCES.dpkg-tmp"
  mv -f "$SOURCES.dpkg-tmp" "$SOURCES"
}

record_repo_added() {
  # An empty file is the admin's opt-out and stays as it is. postrm purge
  # removes the file only if it carries the "Written by" line below.
  if [ ! -e "$DEFAULTS" ]; then
    mkdir -p "$(dirname "$DEFAULTS")"
    cat > "$DEFAULTS" <<EOF
# Written by the $PACKAGE package.
# repo_add="false": the package does not (re)create its repository file
# ($SOURCES). Delete this file to have the next install or upgrade add
# the repository again.
repo_add="false"
EOF
  elif [ -s "$DEFAULTS" ]; then
    if grep -q '^[[:space:]]*repo_add=' "$DEFAULTS"; then
      sed -i 's/^\([[:space:]]*\)repo_add=.*/\1repo_add="false"/' "$DEFAULTS"
    else
      echo 'repo_add="false"' >> "$DEFAULTS"
    fi
  fi
}

case "$1" in
  configure)
    if [ -d /etc/apt/sources.list.d ]; then
      if [ "$(repo_add_setting)" != "false" ]; then
        if ! repo_in_use; then
          write_sources
        fi
        record_repo_added
      fi
      # Opted out and no source uses the repository: write nothing.
      if repo_in_use || [ -e "$KEYRING" ]; then
        write_key
      fi
    fi
  ;;

  abort-upgrade|abort-remove|abort-deconfigure)
  ;;

  *)
    echo "postinst called with unknown argument: $1" >&2
    exit 1
  ;;
esac

#DEBHELPER#

exit 0
