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

Private URL and HTTP Basic credentials may opt into iCloud Keychain
synchronization when the provider permits it. Bearer tokens default to
device-only storage because their provider refresh/revocation policy must be
known before synchronizing them.

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
