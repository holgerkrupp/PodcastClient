# Network tracking protection

Up Next stores the global `networkTrackingProtection.enabled.v1` preference in its App Group defaults. A missing key means enabled, including for existing installs and independent watch/share-extension launches. The phone copies the effective value into the watch sync snapshot; older snapshots decode as protected. New requests observe the current value. Existing playback and download tasks can continue with the request they already started.

The version 1 URL policy preserves source/library URLs and changes only request URLs. It removes the recognized `utm_*`, click-ID, and campaign parameters from unsigned HTTP(S) requests, preserving all other percent-encoded query pairs in their original order. URLs carrying recognized HMAC, CloudFront, S3, or Google signing markers are left intact. URL user-info, private-feed tokens, unknown query fields, HTTP methods, conditional validators, range headers, and request timeouts are retained. The policy unwraps the supported OP3 `/e/<encoded absolute URL>` form offline, up to three levels. It does not contact OP3 while preparing the request.

The Podtrac `/redirect.mp3/` and `/pts/redirect.mp3/` forms encode the target host/path without preserving whether the origin used HTTP or HTTPS. For a well-formed public DNS hostname, Up Next reconstructs a direct **HTTPS-only** publisher URL and removes Podtrac's `ptm_*` redirect parameters offline. Unsafe or unrecognized forms are blocked with an actionable error; the app never contacts Podtrac to discover a destination. Generic CDN and media hosts are never rewritten based on their names.

## Covered paths

- Feed refresh, parser lookups, chapters, transcript fetches, and controlled shownote enrichment use `PodcastHTTPClient` or the policy session, which prepares first requests and controllable redirects.
- Discovery, search, share import, artwork, and watch direct transfers use policy-controlled sessions. Cookies are disabled where these clients do not rely on cookie authentication; `Referer` is removed and app-controlled requests use a stable, non-unique user agent.
- Shownotes render with a restrictive content security policy. Remote images, media, frames, scripts, forms, stylesheets, and connections are blocked inside the WebView; inline/data images and inline styling remain available. User-activated links still open in the system browser, outside this policy.
- Playback and AVFoundation metadata paths receive a cleaned URL and stable user agent when the app controls asset creation.

## Limits and release checks

AVFoundation can issue playback, HLS, cookie, and redirect requests that the app cannot fully intercept through its public asset API. Its playback session identifier may still be sent. Background `URLSession` downloads follow redirects automatically and do not provide the redirect delegate hook needed to clean each hop. Known OP3 and verified Podtrac links are unwrapped before these requests, but this is not a guarantee against every unknown redirecting tracker. Changing the preference affects new tasks; active playback/download tasks are allowed to finish.

Background downloads associate the original episode URL and local destination with the URLSession task identifier. Delegate callbacks use this identifier rather than the sanitized wire URL; pending task associations are restored on launch. The UI reports request failures and offers Retry when no byte progress has been reported for 90 seconds. Retry starts a fresh transfer rather than reusing potentially stale privacy/authentication headers. These associations are local app state and must never be emitted to telemetry or diagnostic logs.

The local diagnostic counters store only purpose/outcome totals in App Group defaults. They never store URLs, query values, credentials, feed IDs, or device identifiers. Do not describe this feature as anonymous downloading: origin servers can still observe IP address, timing, byte ranges, and publisher-side identifiers.

Before release, run the issue's local redirect fixture across GET/HEAD, validators, ranges, and cross-origin authorization; exercise background pause/resume and app suspension on devices; and capture device traffic for iOS, macOS, watchOS, and the share extension. Record the observed AVFoundation/HLS and background-redirect limits with that capture. Simulator unit tests do not satisfy the device traffic gate.
