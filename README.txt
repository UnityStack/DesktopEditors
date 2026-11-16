# Euro-Office Community Edition, apt and rpm repositories.
# Unofficial community build by UnityStack GmbH, not affiliated with the Euro-Office project.
#
# Signing key: https://packages.unitystack.eu/keys/unitystack.asc
# Check that its fingerprint is 62E1 6713 F445 9962 B020  2B01 038A B9E6 3A2B 29ED:
#   curl -fsSL https://packages.unitystack.eu/keys/unitystack.asc | gpg --show-keys
#
# Release candidates are in the testing channel: use euro-office-testing.sources
# or euro-office-testing.repo instead.

# Debian, Ubuntu (apt):
sudo curl -fsSL -o /usr/share/keyrings/unitystack.asc https://packages.unitystack.eu/keys/unitystack.asc
sudo tee /etc/apt/sources.list.d/euro-office.sources > /dev/null <<'END'
Types: deb
URIs: https://packages.unitystack.eu/euro-office/apt
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/unitystack.asc
END
sudo apt update
sudo apt install euro-office-euro-office

# Fedora, RHEL, Rocky Linux (dnf):
sudo rpm --import https://packages.unitystack.eu/keys/unitystack.asc
sudo curl -fsSL -o /etc/yum.repos.d/euro-office.repo https://packages.unitystack.eu/euro-office/rpm/euro-office.repo
sudo dnf install euro-office-euro-office

# openSUSE (zypper):
sudo rpm --import https://packages.unitystack.eu/keys/unitystack.asc
sudo zypper addrepo https://packages.unitystack.eu/euro-office/rpm/euro-office.repo
sudo zypper install euro-office-euro-office
