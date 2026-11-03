# ==============================================================================
# FORK ADDITIONS TO desktop-apps/package/Makefile
#
# Read after the upstream Makefile:
#
#   make -f Makefile -f fork.mk deb rpm tar ...
#
# so every variable defined there (PACKAGE_NAME, M4_PARAMS, DEB, RPM, ...) is
# usable here. This file only adds prerequisites and rules for files that do
# not exist upstream; edits of upstream files live in build/linux/package.patch.
# Both are applied by build/.docker/packages.bake.Dockerfile.
#
# What it adds:
#   - deb postinst: registers the signed apt repository once (opt-out through
#     /etc/default/$(REPO_NAME)), the rpm counterpart is %post in common.spec
#   - the repository key as rpm payload (/etc/pki/rpm-gpg/RPM-GPG-KEY-*)
#   - AppStream metainfo in /usr/share/metainfo (deb, rpm and tar)
# ==============================================================================

# Package repository (served by packages.euro-office.org, built by
# build/linux/repo/publish-repo.sh). Clients use $(REPO_URL)/apt and
# $(REPO_URL)/rpm/<channel>/; REPO_NAME names every file the packages write:
#   /etc/apt/sources.list.d/$(REPO_NAME).sources  /usr/share/keyrings/$(REPO_NAME).asc
#   /etc/yum.repos.d/$(REPO_NAME).repo            /etc/zypp/repos.d/$(REPO_NAME).repo
#   /etc/default/$(REPO_NAME)                     (opt-out / "already added" state)
REPO_URL ?= https://packages.euro-office.org
REPO_NAME ?= euro-office

# Armored public key of the repository. The Dockerfile copies
# build/linux/unitystack-package-signing.asc here, so the key exists once in
# the repo and a change to the key (a revocation, a new spare subkey) only
# touches that file.
REPO_KEY ?= common/linux/$(REPO_NAME).asc

# AppStream component: euro-office.org reversed, '-' -> '_' (AppStream ids
# must not contain '-').
APPSTREAM_ID ?= org.euro_office.desktopeditors
APPSTREAM_DEVELOPER_ID ?= eu.unitystack
VCS_URL ?= https://github.com/UnityStack/DesktopEditors
BUGTRACKER_URL ?= $(VCS_URL)/issues
RELEASE_DATE ?= $(shell date -u +%F)

# Prereleases (BUILD_NUMBER 0~ce~rc.2, 0~rc.1, ...) are "development"
# releases in AppStream; the packages pick the testing suite/channel by the
# same rule at install time.
RELEASE_TYPE := $(if $(findstring ~rc,$(BUILD_NUMBER))$(findstring ~beta,$(BUILD_NUMBER))$(findstring ~alpha,$(BUILD_NUMBER)),development,stable)

METAINFO = build/main/usr/share/metainfo/$(APPSTREAM_ID).metainfo.xml
# build/rpm/ holds rpm-only payload; common.spec copies it next to build/main.
RPM_GPG_KEY = build/rpm/etc/pki/rpm-gpg/RPM-GPG-KEY-$(REPO_NAME)

# M4_PARAMS is a recursive variable that M4_DEB_PARAMS expands, so the deb
# templates see these too.
M4_PARAMS += -D M4_REPO_URL='$(REPO_URL)'
M4_PARAMS += -D M4_REPO_NAME='$(REPO_NAME)'
M4_PARAMS += -D M4_REPO_KEY='$(REPO_KEY)'
M4_PARAMS += -D M4_APPSTREAM_ID='$(APPSTREAM_ID)'
M4_PARAMS += -D M4_APPSTREAM_DEVELOPER_ID='$(APPSTREAM_DEVELOPER_ID)'
M4_PARAMS += -D M4_VCS_URL='$(VCS_URL)'
M4_PARAMS += -D M4_BUGTRACKER_URL='$(BUGTRACKER_URL)'
M4_PARAMS += -D M4_RELEASE_VERSION='$(PRODUCT_VERSION)'
M4_PARAMS += -D M4_RELEASE_DATE='$(RELEASE_DATE)'
M4_PARAMS += -D M4_RELEASE_TYPE='$(RELEASE_TYPE)'

RPM_PARAMS += --define '_repo_url $(REPO_URL)'
RPM_PARAMS += --define '_repo_name $(REPO_NAME)'

build : $(METAINFO)

# Validated here, before the slow packaging steps; errors fail the build,
# warnings and pedantic hints do not.
$(METAINFO) : common/linux/metainfo.xml.m4
	mkdir -p $(@D) && m4 $(M4_PARAMS) $< > $@
	appstreamcli validate --no-net $@ || { rm -f $@; exit 1; }

# The upstream pattern rule (deb/build/debian/% : deb/template/%.m4) renders
# postinst; this only adds the key it embeds as a prerequisite.
$(DEB) : deb/build/debian/postinst
deb/build/debian/postinst : $(REPO_KEY)

$(RPM) $(RPM_SUSE) : $(RPM_GPG_KEY)

$(RPM_GPG_KEY) : $(REPO_KEY)
	install -m 644 -D $< $@
