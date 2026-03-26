#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"de.holgerkrupp.PodcastClient";

/// The "AccentColor" asset catalog color resource.
static NSString * const ACColorNameAccentColor AC_SWIFT_PRIVATE = @"AccentColor";

/// The "backgroundColor" asset catalog color resource.
static NSString * const ACColorNameBackgroundColor AC_SWIFT_PRIVATE = @"backgroundColor";

/// The "custom.cloud.badge.play" asset catalog image resource.
static NSString * const ACImageNameCustomCloudBadgePlay AC_SWIFT_PRIVATE = @"custom.cloud.badge.play";

/// The "custom.play.circle.badge.checkmark" asset catalog image resource.
static NSString * const ACImageNameCustomPlayCircleBadgeCheckmark AC_SWIFT_PRIVATE = @"custom.play.circle.badge.checkmark";

/// The "custom.quote.bubble.rectangle.portrait" asset catalog image resource.
static NSString * const ACImageNameCustomQuoteBubbleRectanglePortrait AC_SWIFT_PRIVATE = @"custom.quote.bubble.rectangle.portrait";

/// The "custom.quote.bubble.slash" asset catalog image resource.
static NSString * const ACImageNameCustomQuoteBubbleSlash AC_SWIFT_PRIVATE = @"custom.quote.bubble.slash";

/// The "extremelysuccessfullogo" asset catalog image resource.
static NSString * const ACImageNameExtremelysuccessfullogo AC_SWIFT_PRIVATE = @"extremelysuccessfullogo";

/// The "githublogo" asset catalog image resource.
static NSString * const ACImageNameGithublogo AC_SWIFT_PRIVATE = @"githublogo";

/// The "mastodon" asset catalog image resource.
static NSString * const ACImageNameMastodon AC_SWIFT_PRIVATE = @"mastodon";

/// The "mastodon.clean" asset catalog image resource.
static NSString * const ACImageNameMastodonClean AC_SWIFT_PRIVATE = @"mastodon.clean";

/// The "mastodon.clean.fill" asset catalog image resource.
static NSString * const ACImageNameMastodonCleanFill AC_SWIFT_PRIVATE = @"mastodon.clean.fill";

/// The "mastodon.fill" asset catalog image resource.
static NSString * const ACImageNameMastodonFill AC_SWIFT_PRIVATE = @"mastodon.fill";

#undef AC_SWIFT_PRIVATE
