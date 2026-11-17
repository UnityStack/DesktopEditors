/*
 * UnityStack start-page overlay: a per-provider hint in the "Connect to cloud" dialog.
 *
 * The upstream start page (desktop-apps/common/loginpage) has no config.json field for
 * hint text or links. Native GetExternalClouds() passes each provider's config.json to
 * the page unchanged, so a provider can carry a custom field that this script reads from
 * window.config.portals.providers[<id>]:
 *
 *   "connectHint": {
 *       "text":     { "en": "...", "de": "..." },
 *       "linkText": { "en": "...", "de": "..." },
 *       "url":      "https://..."
 *   }
 *
 * Text is picked by the UI language (utils.Lang.id, then its two-letter prefix, then en).
 * The link uses target="popup", which the app opens in the system browser, like the
 * links on the About page. Only https links are rendered.
 *
 * build/loginpage/inject.js inlines this file into the deployed index.html; see
 * build/.docker/desktop-composer.bake.Dockerfile (stage desktop-js-unitystack).
 * It is inlined verbatim, so it must not contain a closing script tag or an HTML
 * comment opener (inject.js refuses both).
 */
(function () {
    'use strict';

    var DIALOG_CLASS = 'dlg-connect-to';
    var HINT_CLASS = 'provider-hint';

    function localized(map) {
        if (typeof map === 'string') return map;
        if (!map || typeof map !== 'object') return '';
        var lang = String((window.utils && utils.Lang && utils.Lang.id) || '');
        return map[lang] || map[lang.slice(0, 2)] || map.en || '';
    }

    function hintFor(provider) {
        var providers = window.config && config.portals && config.portals.providers;
        var item = providers && Object.prototype.hasOwnProperty.call(providers, provider) && providers[provider];
        return item && item.connectHint;
    }

    function render(dialog, select) {
        var old = dialog.querySelector('.' + HINT_CLASS);
        if (old) old.parentNode.removeChild(old);

        var hint = hintFor(select.value);
        var text = hint && localized(hint.text);
        var anchor = dialog.querySelector('#panel-portal .error-box');
        if (!text || !anchor) return;

        var p = document.createElement('p');
        p.className = 'text-sub ' + HINT_CLASS;
        p.style.margin = '8px 0 0';
        p.appendChild(document.createTextNode(text));

        if (typeof hint.url === 'string' && /^https:\/\//i.test(hint.url)) {
            var a = document.createElement('a');
            a.className = 'link';
            a.target = 'popup';
            a.href = hint.url;
            a.draggable = false;
            a.textContent = localized(hint.linkText) || hint.url;
            p.appendChild(document.createTextNode(' '));
            p.appendChild(a);
        }

        anchor.parentNode.insertBefore(p, anchor.nextSibling);
    }

    function attach(dialog) {
        var select = dialog.querySelector('select');
        if (!select || dialog.getAttribute('data-provider-hint')) return;
        dialog.setAttribute('data-provider-hint', 'on');

        var update = function () { render(dialog, select); };
        // dialogconnect.js fires change through jQuery (.trigger), which skips native listeners
        if (window.jQuery) jQuery(select).on('change', update);
        else select.addEventListener('change', update);
        update();
    }

    // DialogConnect.show() builds the dialog, fills and selects the provider list in one
    // synchronous run, so by the time this observer runs the select holds its final value.
    new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
            var added = records[i].addedNodes;
            for (var j = 0; j < added.length; j++) {
                var node = added[j];
                if (node.nodeType === 1 && node.classList.contains(DIALOG_CLASS)) attach(node);
            }
        }
    }).observe(document.body, { childList: true, subtree: true });
})();
