# ==============================================================================
# MODULE DOCKERFILE
# This file is not meant to be built standalone. It is consumed by the 
# docker-bake.hcl file in this monorepo.
# ==============================================================================

# UnityStack: inline the provider hint (build/loginpage/provider-hint.js) into the start
# page built by desktop-js. inject.js fails the build if the page changed shape upstream.
# desktop-js is a bake named context (docker-bake.hcl), not a tagged image.
# hadolint ignore=DL3006
FROM desktop-js AS desktop-js-unitystack
    COPY build/loginpage/inject.js build/loginpage/provider-hint.js /overlay/
    RUN node /overlay/inject.js /app/loginpage/deploy/index.html /overlay/provider-hint.js

FROM scratch AS desktop-common
    ARG BUILD_ROOT

    COPY --from=sdkjs-desktop ${BUILD_ROOT} /editors/
    # Desktop only loads the main editors, never the mobile ones
    COPY --from=web-apps --exclude=web-apps/apps/*/mobile ${BUILD_ROOT} /editors/

    COPY --from=desktop-js-unitystack /app/loginpage/deploy/index.html /index.html
    COPY --from=desktop-js /app/loginpage/deploy/noconnect.html /editors/webext/noconnect.html

    COPY desktop-apps/common/converter/* /converter/
    # Support only Nextcloud, openWorkspace and OpenCloud for now. OpenCloud comes from
    # build/providers, not from desktop-apps' providers/opencloud: it needs the bridge's editorPage.
    COPY desktop-apps/common/loginpage/providers/nextcloud /providers/nextcloud
    COPY build/providers/openworkspace /providers/openworkspace
    COPY build/providers/opencloud /providers/opencloud
    COPY desktop-apps/common/templates /converter/templates

    COPY desktop-sdk/ChromiumBasedEditors/resources/ /editors/sdkjs/common/Images/

    COPY build/configs/core/DoctRenderer.config.desktop /converter/DoctRenderer.config
    
    COPY document-templates/new /converter/empty

    COPY dictionaries/ /dictionaries
    

    COPY core-fonts/opensans   /fonts
    COPY core-fonts/asana      /fonts/asana
    COPY core-fonts/caladea    /fonts/caladea
    COPY core-fonts/crosextra  /fonts/crosextra
    COPY core-fonts/openoffice /fonts/openoffice
    COPY core-fonts/ASC.ttf    /fonts/ASC.ttf

    # Create sdkjs-plugins dir in scratch image
    WORKDIR /editors/sdkjs-plugins
