# Private podcast access test matrix

The automated matrix uses fake hosts, tokens, and credentials. It does not
depend on a subscriber URL that may later be revoked.

| Acceptance case | Automated coverage |
| --- | --- |
| Existing device with a valid private URL | `PodcastPrivateFeedTests.testAccessResolverSupportsPrivateURLBasicAndBearerCredentials` and the local HTTP fixture tests |
| HTTP Basic email and reserved/special characters | `testBasicAuthenticationDecodesReservedCharactersFromURLUserInfo` and `testHTTPClientFetchesTheSameFixtureThroughEveryAccessMode` |
| 403 without an authentication challenge | `testResolverDoesNotShowAuthenticationPromptFor403WithoutChallenge` confirms the URL error path is used instead of showing credential UI |
| Bearer access | `testAccessResolverSupportsPrivateURLBasicAndBearerCredentials` and local fixture coverage |
| Fresh device with missing credential | `SubscriptionManifestSyncTests.testRestoreKeepsPrivateSubscriptionWhenCredentialIsMissing` and `StableIdentityTests.testPremiumSubscriptionWaitsForCredentialThenRebootstraps` |
| Credential becomes available | `testRestoreUsesInjectedCredentialStoreWhenPrivateCredentialIsAvailable` and the one-time rebootstrap assertions |
| Keychain unavailable | `PodcastPrivateFeedTests.testUnavailableCredentialStoreProducesRecoverableCredentialRequiredState` |
| Expired provider session, cancellation, renewal, and sign-out | `testProviderLifecycleCoversExpiredRefreshCancellationRenewalAndRevocation` |
| 401/403 recovery without abandonment | `PodcastReleasePredictorTests.testAuthenticationFailuresNeverMarkPodcastFeedUnavailable` |
| Token rotation and stable identity | `testCredentialRotationUsesTheLatestCredentialWithoutChangingProfileIdentity` and `testHTTPClientRequestOverloadRebuildsRotatedAuthorization` |
| Background-download association after token rotation | `testDownloadAssociationSurvivesPrivateURLTokenRotation` |
| Background-download 401/403 recovery | `testProtectedDownloadAuthFailuresPreserveExplicitRetryAssociation`; the download delegate preserves the profile/destination and waits for an explicit retry with current credentials |
| Cross-origin redirect protection | `testRedirectsDoNotForwardCredentialsAcrossOrigins` |
| Protected artwork/transcript/resource paths | `testProtectedArtworkCacheScopeIsSeparateFromPublicArtwork` and access-layer fixture coverage |
| Public-feed query preservation/regression | `testPublicFeedQueryIsPreservedAndNotClassifiedAsPrivate` |
| Current-user credential isolation and bootstrap | `testCredentialStoreScopesSecretsByCurrentUser` and `SubscriptionManifestSyncTests.testRestoreScopesPremiumCredentialByCurrentUser` |
| Current-user scope switch after client initialization | `testDefaultResolverFollowsCurrentUserScopeAfterInitialization` verifies a default resolver follows the active scope without changing the resolver used by an in-flight request |
| Secure credential survives app reinstall | `sh Scripts/validate-private-podcast-reinstall.sh` runs signed iOS simulator write, app uninstall, reinstall, and read phases with a fake credential |
| Device-only Keychain policy and access-group resolution | The signed phase of `sh Scripts/validate-private-podcast-reinstall.sh` verifies `AfterFirstUnlockThisDeviceOnly`, non-synchronizable storage, and a resolved signing access group |
| Apple-platform shared access boundary | `sh Scripts/validate-private-podcast-access.sh all` type-checks the reusable access layer against iOS, macOS, watchOS, and tvOS SDKs |
| tvOS fresh-device bootstrap | `testPremiumBootstrapPlannerDistinguishesMissingReadyAndPublicStates` covers the shared manifest planner with fake credentials; `UpNextTV` builds for tvOS and launches in the signed tvOS simulator, while the no-iCloud-account path safely reports no subscriptions without opening an unscoped credential store |

The signed iPhone 15 Pro Keychain policy gate passes. Physical reinstall,
locked-background, process-termination, iCloud-Keychain-disabled, and
Apple TV current-user tests remain release-device gates for the paired iPad,
Watch, and Apple TV targets. They cannot be represented as passing automated
simulator tests and must be completed on signed hardware.
