#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"de.holgerkrupp.PodcastClient.watchkitapp.UpNextWatchComplications";

/// The "AccentColor" asset catalog color resource.
static NSString * const ACColorNameAccentColor AC_SWIFT_PRIVATE = @"AccentColor";

/// The "backgroundColor" asset catalog color resource.
static NSString * const ACColorNameBackgroundColor AC_SWIFT_PRIVATE = @"backgroundColor";

/// The "6Colors" asset catalog image resource.
static NSString * const ACImageName6Colors AC_SWIFT_PRIVATE = @"6Colors";

/// The "LaunchMark" asset catalog image resource.
static NSString * const ACImageNameLaunchMark AC_SWIFT_PRIVATE = @"LaunchMark";

/// The "blue" asset catalog image resource.
static NSString * const ACImageNameBlue AC_SWIFT_PRIVATE = @"blue";

/// The "green" asset catalog image resource.
static NSString * const ACImageNameGreen AC_SWIFT_PRIVATE = @"green";

/// The "orange" asset catalog image resource.
static NSString * const ACImageNameOrange AC_SWIFT_PRIVATE = @"orange";

/// The "pride" asset catalog image resource.
static NSString * const ACImageNamePride AC_SWIFT_PRIVATE = @"pride";

/// The "progress" asset catalog image resource.
static NSString * const ACImageNameProgress AC_SWIFT_PRIVATE = @"progress";

/// The "purple" asset catalog image resource.
static NSString * const ACImageNamePurple AC_SWIFT_PRIVATE = @"purple";

/// The "red" asset catalog image resource.
static NSString * const ACImageNameRed AC_SWIFT_PRIVATE = @"red";

/// The "trans" asset catalog image resource.
static NSString * const ACImageNameTrans AC_SWIFT_PRIVATE = @"trans";

/// The "yellow" asset catalog image resource.
static NSString * const ACImageNameYellow AC_SWIFT_PRIVATE = @"yellow";

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
