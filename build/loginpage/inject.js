#!/usr/bin/env node
// Inlines build/loginpage/provider-hint.js into the deployed start page.
//
//   node inject.js <deploy/index.html> <provider-hint.js>
//
// Runs in the desktop-js-unitystack stage of build/.docker/desktop-composer.bake.Dockerfile,
// on the index.html that desktop-apps' grunt build produced. It fails the build when that
// page no longer looks the way provider-hint.js expects, so an upstream change surfaces here
// instead of as a silently missing hint.
'use strict';

const fs = require('fs');

const [htmlPath, scriptPath] = process.argv.slice(2);
if (!htmlPath || !scriptPath) {
    console.error('usage: node inject.js <index.html> <provider-hint.js>');
    process.exit(2);
}

function fail(msg) {
    console.error(`[provider-hint] ${msg}`);
    console.error('[provider-hint] the upstream start page changed shape; update build/loginpage/ to match');
    process.exit(1);
}

const html = fs.readFileSync(htmlPath, 'utf8');
const script = fs.readFileSync(scriptPath, 'utf8');

if (/<\/script|<!--/i.test(script)) fail(`${scriptPath} must not contain "</script" or "<!--"`);
if (html.includes('data-provider-hint')) fail(`${htmlPath} already contains the provider hint`);

// What provider-hint.js relies on, as it appears in the minified, inlined build:
// the Connect dialog markup from dialogconnect.js and the provider map from panelconnect.js.
const expected = [
    'dlg-connect-to',          // dialog class (MutationObserver target)
    'id="panel-portal"',       // panel the hint goes into
    'class="error-box"',       // the hint is placed right after it
    "class='combobox'",        // provider <select>
    'config.portals.providers' // provider map holding connectHint
];
for (const needle of expected) {
    if (!html.includes(needle)) fail(`${htmlPath} no longer contains ${JSON.stringify(needle)}`);
}

const tail = /<\/body>\s*<\/html>\s*$/i.exec(html);
if (!tail) fail(`${htmlPath} does not end with </body></html>`);

fs.writeFileSync(htmlPath, html.slice(0, tail.index) + '<script>' + script + '</script>' + html.slice(tail.index));
console.log(`[provider-hint] inlined ${scriptPath} (${script.length} bytes) into ${htmlPath}`);
