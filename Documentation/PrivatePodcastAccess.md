# Private podcast access

Up Next treats a private podcast feed as an access-controlled resource rather
than as an ordinary public URL.

## Access profiles

`PodcastAccessProfile` contains only non-secret metadata:

- a stable access-profile ID
- the access kind (`privateURL`, HTTP Basic, or Bearer)
- the credential-free resource URL/origin
- whether the credential is allowed to synchronize through iCloud Keychain

The private URL, Basic password, and Bearer token are encoded only in the
Keychain credential record for that profile. Tests use
`InMemoryPodcastCredentialStore` and never require real credentials.
The Keychain query intentionally does not force a cross-target access group:
the signed executable's default Keychain access group owns its local secret.
This prevents a widget, extension, Watch companion, or Apple TV user profile
from reading the app's credentials unless a future, explicitly reviewed
entitlement and adapter grants that access.

The sync policy is deliberately explicit. Private URL and HTTP Basic
credentials are eligible for a future provider allow-list, but the current
allow-list is empty; all current private credentials and Bearer tokens use
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Only the non-secret
subscription/access-profile metadata is synchronized. A new device therefore
keeps the subscription and reports that credentials are required until the
user re-enters or reconnects access.

Store-split and manifest restore use the same `PodcastBootstrapDecision`
planner. A restore result explicitly separates feeds ready to fetch from
credential-free feed identities awaiting login; an empty fetch list is not
interpreted as a missing or deleted subscription. The credential-required
state contains only the stable profile ID and sanitized feed URL.

On a shared system device, a current-user integration can wrap the local
credential store in `ScopedPodcastCredentialStore`. It hashes the system
user/profile identifier before namespacing the Keychain account, so two users
can have different credentials for the same synchronized feed without putting
the user identifier or secret into UserState/CloudKit records. The ordinary
unscoped store remains the default for iOS, iPadOS, macOS, and watchOS. The
production boundary is `PodcastCredentialStoreProvider`; the current account
scope is installed at sign-in/bootstrap time with
`configure(currentUserScopeID:backing:)`, and all default access, importer, and
manifest paths resolve through that provider.

Long-lived default clients do not capture that namespace permanently. The
resolver used by HTTP feed requests and downloads is resolved when each
operation starts, while an individual request keeps one resolver for its
redirect chain. A user switch therefore cannot make a later request reuse the
previous user's credential, and an in-flight request cannot change identity
halfway through a redirect sequence.

## Request boundary

`PodcastHTTPClient` is the common request path for feed discovery, parsing,
status checks, and feed helper downloads. `PodcastAccessResolver` adds a
private URL, Basic header, or Bearer header only for the profile's authorized
origin. Redirects are re-evaluated; a cross-origin redirect is followed
without the original credentials.

Feed identities and synchronized manifests use the credential-free normalized
URL plus the access-profile ID. Diagnostic URL rendering replaces user info
and query values with redacted values. Default OPML export omits private feeds
because exporting their URL would export the credential.

HTTP 401/403 responses are treated as recoverable authentication failures.
They do not contribute to feed-abandonment heuristics, and background refresh
backs off until credentials are repaired or the user explicitly retries.
Background episode downloads follow the same rule: an authorization failure
preserves the persisted profile and destination, while an explicit retry
rebuilds the request from the current credential instead of reusing stale
resume headers.
Feed discovery presents the Basic credential form only when the server's
authentication challenge advertises Basic; a 403 without a challenge remains
a normal load error and does not open an authentication window.

## Refresh recovery and repair

Existing subscription refreshes resolve access in this order: the local
profile reference and its Keychain item, then the narrowly scoped legacy HTTP
Basic profile identifiers derived from the same feed URL (trailing slash and
HTTP/HTTPS spelling variants). A recovered profile is rebound to the current
credential-free URL and the ordinary centralized request path sends the
authenticated request. It never searches unrelated Keychain entries or
forwards credentials across origins. HTTP-to-HTTPS on the same host is
permitted; an automatic HTTPS-to-HTTP downgrade is not.

Incomplete older manifests or user-state records may omit access metadata.
Those missing fields are treated as unknown and do not erase a local profile
reference. Credential changes update the authoritative `SubscriptionSync`
profile fields even when the subscription was already active, without changing
its original `subscribedAt` date. Profile references remain non-secret; the
Keychain item is never reconstructed from synchronized metadata.

When access is rejected or unavailable, the podcast remains in the library and
background refresh backs off. Podcast Detail offers **Fix Authentication**;
Podcast Settings also keeps credential management available when authentication
metadata is incomplete. The editor validates a proposed credential against a
valid feed before saving it, checks the returned feed title against the
existing podcast, and leaves existing credentials in place on validation
failure. Successful validation saves the credential in Keychain, updates the
local and authoritative profile reference, clears the retry state, and starts a
refresh. A network failure is reported separately from an authentication
rejection.

When a response advertises `WWW-Authenticate: Basic`, the repair form selects
username and password by default. If the server instead advertises Bearer, the
form selects a token; when metadata is absent or the server's request changes,
the user can choose Basic, private RSS URL, or Bearer explicitly.

The app distinguishes a missing Keychain item from a Keychain lookup failure,
and from a server-observed rejected credential (`needsLogin`). A credential
being present is not proof that the server accepts it. Only a 401 or an
explicit authentication-required resolver result marks the feed as requiring
login; a generic 403 is not treated as a Basic challenge.

Credentials are device-only today. Subscription records and manifests carry
only profile identifiers and access kind. A newly connected device can restore
the subscription and show the authentication repair action, but the user must
enter the secret again because the secret was intentionally never synchronized.

## Platform boundary

The private access layer is compiled into the iOS/iPadOS/macOS app targets.
The project also contains an `UpNextTV` tvOS bootstrap target. It obtains the
current iCloud user record before opening the scoped credential namespace,
restores the synchronized subscription manifest, and reports either ready
feeds or a recoverable credentials-required state. If the Apple TV account is
unavailable, it uses an unavailable credential store rather than falling back
to an unscoped secret namespace. The tvOS target is intentionally focused on
premium subscription recovery; the full phone playback/search surface is not
duplicated there.

The reusable access boundary has a platform gate:
`Scripts/validate-private-podcast-access.sh` type-checks the credential,
request, redirect, and scoped-store layer against the iOS, macOS, watchOS, and
tvOS SDKs without pulling in the phone UI or the full SwiftData graph.
`Scripts/validate-tvos-premium-access.sh` remains a tvOS-only compatibility
entry point. The `UpNextTV` application target also builds and launches in the
tvOS simulator with CloudKit entitlements; an unauthenticated simulator
deterministically shows the no-subscriptions state without opening a secret
namespace.
The signed iOS simulator reinstall gate in
`Scripts/validate-private-podcast-reinstall.sh` verifies that a device-local
credential survives app removal and reinstallation while synchronized
subscription metadata remains credential-free.

The signed iOS simulator gate and a signed iPhone 15 Pro Keychain policy gate
pass. Physical Apple TV validation is still required for Apple TV reinstall,
locked-background, process-termination, iCloud-Keychain-disabled, and
production access-group behavior; the paired iPad and Watch targets also need
their release-device checks.

The current automated and manual-gate coverage is recorded in
`Documentation/PrivatePodcastAccessTestMatrix.md`.

## ZEIT Podcast Abo

As of 2026-10-01, ZEIT advertises premium podcast access through the ZEIT
Podcast Abo and its ZEIT, Spotify, and Apple Podcasts surfaces. The repository
does not ship a ZEIT account scraper, cookie importer, or unsupported login.
ZEIT is represented as a provider hint for a subscriber-provided private RSS
link; if ZEIT exposes an official third-party feed or authorization API in the
future, it can be added behind the provider adapter boundary.

Sources checked 2026-10-01:

- [ZEIT Podcast Abo](https://premium.zeit.de/zeit-podcast)
- [ZEIT Abo overview and pricing](https://premium.zeit.de/abo-kosten)
