<?xml version="1.0" encoding="UTF-8"?>
<!-- Rendered and checked with "appstreamcli validate" by build/linux/package/fork.mk. -->
<!-- build/linux/repo/dep11.py turns it into the apt repository's DEP-11 catalog. -->
<component type="desktop-application">
  <id>M4_APPSTREAM_ID</id>
  <metadata_license>CC0-1.0</metadata_license>
  <!-- As the License fields of the deb and rpm (desktop-apps/package). -->
  <project_license>AGPL-3.0-only AND CC-BY-SA-4.0</project_license>

  <name>M4_COMPANY_NAME</name>
  <summary>Edit documents, spreadsheets, presentations and PDFs</summary>
  <description>
    <p>
      M4_COMPANY_NAME is an office suite for text documents, spreadsheets, presentations,
      PDFs and PDF forms. It opens and saves Microsoft Office and OpenDocument files
      and works offline.
    </p>
ifelse(M4_PUBLISHER_NAME, M4_COMPANY_NAME,, `    <p>
      This is the unofficial Community Edition, built and signed by M4_PUBLISHER_NAME.
      It is not affiliated with the M4_COMPANY_NAME project.
    </p>
')dnl
  </description>

  <!-- developer_name is what the Ubuntu App Center reads, developer is the AppStream 1.0 form -->
  <developer_name>M4_PUBLISHER_NAME</developer_name>
  <developer id="M4_APPSTREAM_DEVELOPER_ID">
    <name>M4_PUBLISHER_NAME</name>
  </developer>
ifelse(M4_SUPPORT_MAIL,,, `  <update_contact>M4_SUPPORT_MAIL</update_contact>
')dnl

  <url type="homepage">M4_PUBLISHER_URL</url>
  <url type="bugtracker">M4_BUGTRACKER_URL</url>
  <url type="vcs-browser">M4_VCS_URL</url>

  <launchable type="desktop-id">M4_DESKTOPEDITORS_EXEC.desktop</launchable>
  <icon type="stock">M4_DESKTOPEDITORS_EXEC</icon>
  <categories>
    <category>Office</category>
  </categories>
  <provides>
    <binary>M4_DESKTOPEDITORS_EXEC</binary>
ifelse(M4_COMPANY_NAME, Euro-Office, `    <binary>desktopeditors</binary>
')dnl
  </provides>

  <content_rating type="oars-1.1"/>

  <releases>
    <release version="M4_RELEASE_VERSION" date="M4_RELEASE_DATE" type="M4_RELEASE_TYPE"/>
  </releases>
</component>
