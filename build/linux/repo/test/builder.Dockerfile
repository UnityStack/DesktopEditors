# The tools publish-repo.sh needs, as installed on the ubuntu-24.04 runner of
# the publish-repo CI job. rpm (rpmbuild) only builds the fake packages of
# channels.sh; curl (on the runner already) fetches the published key in
# select-signing-subkey.sh.
FROM ubuntu:24.04
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      apt-utils createrepo-c appstream gnupg xz-utils jq python3 m4 rpm ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
