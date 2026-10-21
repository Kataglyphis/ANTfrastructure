<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# The Flutter web shell

What a family Flutter web app shows before Flutter starts: a loading screen and the cookie
notice. OmniAccelerANT and jotrockenmitlocken copy these files into `web/`, and each declares
them in its `.antfrastructure-shared.manifest`, so `sync-shared-config.sh --check` (the
`shared-config` lint gate) fails on any drift. To change one, edit it here and run
`sync-shared-config.sh --repo-root <app> --write` in each app ([`shared/config/README.md`](../config/README.md)).

| File | Does |
| --- | --- |
| `css/loading_animation.css` | The loading screen: full-viewport and centred, smaller on a phone, a dark variant, no animated gradient under `prefers-reduced-motion`, and a `.fade-out` state |
| `css/cookie.css` | The notice: one row on a desktop, text above a full-width button below 600 px |
| `javascript/utils.js` | `setMessage`: German text for `de*`, English otherwise |
| `javascript/cookies.js` | Shows the notice until its button sets `cookie-consent=true` for 400 days (`Max-Age`, `path=/`); `Secure` only on https, since a plain-http LAN page drops a Secure cookie |
| `javascript/init.js` | Fills both messages. It is a file, so the page needs no inline script |

What `index.html` must carry, besides its own title, metadata and CSP:

```html
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" type="text/css" href="css/cookie.css">
<link rel="stylesheet" type="text/css" href="css/loading_animation.css">
<style>:root { --kPrimaryColor: rgb(105, 240, 174); }</style>
...
<section id="cookie-notice"><div class="container"><div id="message"></div><button id="cookie-consent">Okay</button></div></section>
<div id="background-animation"></div>
<div class="loading"><div class="loader"></div><div id="loading-message"></div></div>
<script src="javascript/utils.js"></script>
<script src="javascript/cookies.js"></script>
<script src="javascript/init.js"></script>
<script src="flutter_bootstrap.js" async></script>
```

Without the viewport tag a phone lays the loading screen out 980 px wide. The app removes the
overlay itself: `main()` calls ANThology's `dismissBootOverlay()` (`lib/Boot/boot_overlay.dart`)
before `runApp`. It adds `.fade-out` and removes `.loading` and `#background-animation` 500 ms
later. A JavaScript timer could not know when Flutter is ready, and on a slow link it removed the
overlay too early. `flutter_integration_smoke_test.sh` checks this markup and that each file is
served.
