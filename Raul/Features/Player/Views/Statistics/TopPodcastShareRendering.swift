import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

func topPodcastShareItems(
    from rollups: [PodcastRollup],
    progress: (@MainActor @Sendable (Int) -> Void)? = nil
) async -> [TopPodcastShareItem] {
    var items: [TopPodcastShareItem] = []
    items.reserveCapacity(rollups.count)

    for (index, rollup) in rollups.enumerated() {
        let coverImage: UIImage?
        if let coverURL = rollup.coverURL {
            coverImage = await ImageLoaderAndCache.loadUIImage(from: coverURL)
        } else {
            coverImage = nil
        }

        items.append(
            TopPodcastShareItem(
                rank: index + 1,
                podcastName: rollup.podcastName,
                totalSeconds: rollup.totalSeconds,
                coverImage: coverImage
            )
        )
        await progress?(items.count)
    }

    return items
}

func topPodcastShareTimelineEntries(
    from rollups: [TopPodcastShareTimelineRollup],
    progress: (@MainActor @Sendable (Int) -> Void)? = nil
) async -> [TopPodcastShareTimelineEntry] {
    var entries: [TopPodcastShareTimelineEntry] = []
    entries.reserveCapacity(rollups.count)

    for rollup in rollups {
        let coverImage: UIImage?
        if let coverURL = rollup.coverURL {
            coverImage = await ImageLoaderAndCache.loadUIImage(from: coverURL)
        } else {
            coverImage = nil
        }

        entries.append(
            TopPodcastShareTimelineEntry(
                date: rollup.date,
                podcastName: rollup.podcastName,
                totalSeconds: rollup.totalSeconds,
                coverImage: coverImage,
                coveragePeriod: rollup.coveragePeriod
            )
        )
        await progress?(entries.count)
    }

    return entries
}

@MainActor
func renderTopPodcastShareImage(
    items: [TopPodcastShareItem],
    design: TopPodcastShareDesign,
    periodLabel: String,
    dateRangeLabel: String,
    totalListeningSeconds: Double,
    shareTitle: String,
    background: TopPodcastShareBackground,
    renderSize: CGSize,
    stats: TopPodcastShareStats,
    period: PlaySessionSummaryPeriod,
    periodStart: Date,
    timelineEntries: [TopPodcastShareTimelineEntry],
    usesMonthlyMiniMonthBackgrounds: Bool,
    durationFormatter: @escaping (Double) -> String
) -> UIImage? {
    let renderer = ImageRenderer(
        content: TopPodcastShareCard(
            items: items,
            design: design,
            periodLabel: periodLabel,
            dateRangeLabel: dateRangeLabel,
            totalListeningSeconds: totalListeningSeconds,
            shareTitle: shareTitle,
            background: background,
            renderSize: renderSize,
            stats: stats,
            period: period,
            periodStart: periodStart,
            timelineEntries: timelineEntries,
            usesMonthlyMiniMonthBackgrounds: usesMonthlyMiniMonthBackgrounds,
            durationFormatter: durationFormatter
        )
        .frame(width: renderSize.width, height: renderSize.height)
    )
    renderer.scale = 1
#if canImport(UIKit)
    return renderer.uiImage
#else
    guard let cgImage = renderer.cgImage else { return nil }
    return UIImage(cgImage: cgImage)
#endif
}

private struct TopPodcastShareCard: View {
    let items: [TopPodcastShareItem]
    let design: TopPodcastShareDesign
    let periodLabel: String
    let dateRangeLabel: String
    let totalListeningSeconds: Double
    let shareTitle: String
    let background: TopPodcastShareBackground
    let renderSize: CGSize
    let stats: TopPodcastShareStats
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
    let timelineEntries: [TopPodcastShareTimelineEntry]
    let usesMonthlyMiniMonthBackgrounds: Bool
    let durationFormatter: (Double) -> String

    var body: some View {
        Group {
            switch design {
            case .podium:
                podiumCard
            case .billboard:
                billboardCard
            case .coverGrid:
                coverGridCard
            case .coverCollage:
                coverCollageCard
            case .coverCloud:
                coverCloudCard
            case .horizontalBars:
                horizontalBarsCard
            case .pieChart:
                pieChartCard
            case .statistics:
                statisticsCard
            case .calendar:
                calendarCard
            case .yearCalendar:
                yearCalendarCard
            }
        }
        .foregroundStyle(primaryTextColor)
    }

    private var primaryTextColor: Color {
        background.isLight ? .black : .white
    }

    private var secondaryTextColor: Color {
        primaryTextColor.opacity(background.isLight ? 0.66 : 0.76)
    }

    private var tertiaryTextColor: Color {
        primaryTextColor.opacity(background.isLight ? 0.58 : 0.65)
    }

    private var artworkShadowColor: Color {
        background.isLight ? .black.opacity(0.18) : .black.opacity(0.34)
    }

    private var isLandscape: Bool {
        renderSize.width > renderSize.height
    }

    private var isSquare: Bool {
        abs(renderSize.width - renderSize.height) < 1
    }

    private var layoutScale: CGFloat {
        if isLandscape {
            return 0.64
        }
        if isSquare {
            return 0.76
        }
        return 1
    }

    private var renderAspect: PodcastShareRenderAspect {
        if isLandscape {
            return .landscape
        }
        if isSquare {
            return .square
        }
        return .portrait
    }

    private func scaled(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(value * layoutScale, minimum)
    }

    private func cardPadding(_ value: CGFloat) -> CGFloat {
        max(value * layoutScale, isLandscape ? 34 : 42)
    }

    private var gridColumnCount: Int {
        if isLandscape {
            return 6
        }
        if isSquare {
            return 4
        }
        return 3
    }

    private var gridItemCount: Int {
        if isLandscape {
            return min(items.count, 12)
        }
        if isSquare {
            return min(items.count, 12)
        }
        return min(items.count, 12)
    }

    @ViewBuilder
    private func shareBackground<CurrentBackground: View>(
        @ViewBuilder current: () -> CurrentBackground
    ) -> some View {
        if let occasionConfig = background.occasionConfig {
            SeasonalPodcastShareBackground(config: occasionConfig)
        } else if let month = background.seasonalMonth {
            SeasonalPodcastShareBackground(month: month)
        } else {
            switch background {
            case .current:
                current()
            case .stripes:
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        ForEach(Array(TopPodcastShareBackground.stripeColors.enumerated()), id: \.offset) { _, color in
                            color
                                .frame(height: geometry.size.height / CGFloat(TopPodcastShareBackground.stripeColors.count))
                        }
                    }
                }
            case .rainbowGradient:
                LinearGradient(
                    colors: TopPodcastShareBackground.stripeColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .white:
                Color.white
            case .black:
                Color.black
            default:
                current()
            }
        }
    }

    private var podiumCard: some View {
        let podiumItems = [items[safe: 1], items[safe: 0], items[safe: 2]].compactMap(\.self)

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.09, blue: 0.15),
                        Color(red: 0.04, green: 0.18, blue: 0.22),
                        Color(red: 0.47, green: 0.17, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(34, minimum: 18)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                HStack(alignment: .bottom, spacing: scaled(28, minimum: 14)) {
                    ForEach(podiumItems) { item in
                        PodiumPodcastColumn(
                            item: item,
                            height: scaled(podiumHeight(for: item.rank), minimum: 120),
                            duration: durationFormatter(item.totalSeconds),
                            durationColor: secondaryTextColor,
                            podiumFillColor: primaryTextColor.opacity(item.rank == 1 ? 0.30 : 0.20),
                            podiumStrokeColor: primaryTextColor.opacity(0.18),
                            artworkShadowColor: artworkShadowColor,
                            scale: layoutScale
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: scaled(790, minimum: 300), alignment: .bottom)

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(70))
        }
    }

    private var billboardCard: some View {
        let rowScale: CGFloat = isLandscape ? 0.54 : (isSquare ? 0.64 : 1)
        let rowSpacing: CGFloat = isLandscape ? 6 : (isSquare ? 7 : 14)

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.06, blue: 0.07),
                        Color(red: 0.16, green: 0.12, blue: 0.09),
                        Color(red: 0.64, green: 0.18, blue: 0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(28, minimum: 12)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                VStack(spacing: rowSpacing) {
                    ForEach(items.prefix(10)) { item in
                        BillboardPodcastRow(
                            item: item,
                            duration: durationFormatter(item.totalSeconds),
                            durationColor: secondaryTextColor,
                            rowBackgroundColor: primaryTextColor.opacity(item.rank == 1 ? 0.20 : 0.12),
                            scale: rowScale
                        )
                    }
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(58))
        }
    }

    private var coverGridCard: some View {
        let gridItems = Array(items.prefix(gridItemCount))

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.08, blue: 0.10),
                        Color(red: 0.08, green: 0.20, blue: 0.18),
                        Color(red: 0.56, green: 0.32, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(36, minimum: 18)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                CoverGridLayout(
                    items: gridItems,
                    columns: gridColumnCount,
                    spacing: scaled(22, minimum: 10),
                    shadowColor: artworkShadowColor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer(minLength: 0)

                footer
            }
            .padding(cardPadding(64))
        }
    }

    private var coverCollageCard: some View {
        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.07, blue: 0.10),
                        Color(red: 0.12, green: 0.17, blue: 0.23),
                        Color(red: 0.46, green: 0.22, blue: 0.34)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(26, minimum: 12)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                if isLandscape {
                    landscapeCoverCollageContent
                } else if isSquare {
                    squareCoverCollageContent
                } else {
                    portraitCoverCollageContent
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(60))
        }
    }

    private var portraitCoverCollageContent: some View {
        let heroItem = items.first
        let secondRow = Array(items.dropFirst().prefix(2))
        let thirdRow = Array(items.dropFirst(3).prefix(3))
        let bottomRow = Array(items.dropFirst(6).prefix(4))

        return VStack(spacing: scaled(26, minimum: 12)) {
            if let heroItem {
                PodcastShareArtwork(image: heroItem.coverImage, size: scaled(500, minimum: 260))
                    .shadow(color: artworkShadowColor, radius: 18, y: 14)
                    .frame(maxWidth: .infinity)
            }

            coverCollageRow(secondRow, size: scaled(260, minimum: 120), spacing: scaled(26, minimum: 10))
            coverCollageRow(thirdRow, size: scaled(190, minimum: 92), spacing: scaled(20, minimum: 8))

            if !bottomRow.isEmpty {
                coverCollageRow(bottomRow, size: scaled(145, minimum: 68), spacing: scaled(16, minimum: 7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var squareCoverCollageContent: some View {
        let topItems = Array(items.prefix(2))
        let middleItems = Array(items.dropFirst(2).prefix(3))
        let bottomItems = Array(items.dropFirst(5).prefix(4))

        return VStack(spacing: scaled(22, minimum: 10)) {
            coverCollageRow(topItems, size: scaled(300, minimum: 150), spacing: scaled(28, minimum: 12))
            coverCollageRow(middleItems, size: scaled(205, minimum: 104), spacing: scaled(22, minimum: 9))
            coverCollageRow(bottomItems, size: scaled(150, minimum: 76), spacing: scaled(16, minimum: 7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var landscapeCoverCollageContent: some View {
        CoverCollageLandscapeLayout(items: Array(items.prefix(12)), shadowColor: artworkShadowColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coverCollageRow(_ rowItems: [TopPodcastShareItem], size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(rowItems) { item in
                PodcastShareArtwork(image: item.coverImage, size: size)
                    .shadow(color: artworkShadowColor, radius: 14, y: 10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var coverCloudCard: some View {
        ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.07, blue: 0.10),
                        Color(red: 0.10, green: 0.15, blue: 0.21),
                        Color(red: 0.42, green: 0.18, blue: 0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(26, minimum: 14)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                CoverCloudLayout(items: items, shadowColor: artworkShadowColor)
                    .frame(maxWidth: .infinity, minHeight: scaled(800, minimum: 300))

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(60))
        }
    }

    private var statisticsCard: some View {
        ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.13, blue: 0.11),
                        Color(red: 0.04, green: 0.22, blue: 0.18),
                        Color(red: 0.01, green: 0.08, blue: 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(28, minimum: 12)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                statisticsContent

                Spacer(minLength: 0)

                footer
            }
            .padding(cardPadding(64))
        }
    }

    private var calendarCard: some View {
        ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.10, blue: 0.12),
                        Color(red: 0.09, green: 0.20, blue: 0.20),
                        Color(red: 0.34, green: 0.16, blue: 0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            if isLandscape {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                        shareHeader(title: shareTitle, subtitle: periodLabel)
                        Spacer(minLength: 0)
                        footer
                    }
                    .frame(width: renderSize.width * 0.28, height: renderSize.height - cardPadding(48) * 2, alignment: .topLeading)

                    calendarLayout
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(cardPadding(48))
            } else {
                VStack(alignment: .leading, spacing: isSquare ? 16 : scaled(28, minimum: 12)) {
                    shareHeader(title: shareTitle, subtitle: periodLabel)

                    calendarLayout
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Spacer(minLength: 0)
                    footer
                }
                .padding(cardPadding(isSquare ? 46 : 58))
            }
        }
    }

    private var calendarLayout: some View {
        PodcastShareCalendarLayout(
            period: period,
            periodStart: periodStart,
            entries: timelineEntries,
            renderAspect: renderAspect,
            textColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            cellFillColor: primaryTextColor.opacity(background.isLight ? 0.10 : 0.13),
            emptyCellFillColor: primaryTextColor.opacity(background.isLight ? 0.05 : 0.07),
            borderColor: primaryTextColor.opacity(0.18),
            shadowColor: artworkShadowColor,
            durationFormatter: durationFormatter
        )
    }

    private var yearCalendarCard: some View {
        ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.10, blue: 0.12),
                        Color(red: 0.09, green: 0.20, blue: 0.20),
                        Color(red: 0.34, green: 0.16, blue: 0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            if isLandscape {
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 18) {
                        shareHeader(title: shareTitle, subtitle: periodLabel)
                        Spacer(minLength: 0)
                        footer
                    }
                    .frame(width: renderSize.width * 0.25, height: renderSize.height - cardPadding(42) * 2, alignment: .topLeading)

                    yearDailyCalendarLayout
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(cardPadding(42))
            } else {
                VStack(alignment: .leading, spacing: isSquare ? 14 : scaled(24, minimum: 10)) {
                    shareHeader(title: shareTitle, subtitle: periodLabel)

                    yearDailyCalendarLayout
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Spacer(minLength: 0)
                    footer
                }
                .padding(cardPadding(isSquare ? 42 : 50))
            }
        }
    }

    private var yearDailyCalendarLayout: some View {
        PodcastShareYearDailyCalendarLayout(
            periodStart: periodStart,
            entries: timelineEntries,
            renderAspect: renderAspect,
            textColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            cellFillColor: primaryTextColor.opacity(background.isLight ? 0.10 : 0.13),
            emptyCellFillColor: primaryTextColor.opacity(background.isLight ? 0.05 : 0.07),
            borderColor: primaryTextColor.opacity(0.18),
            usesMonthlyBackgrounds: usesMonthlyMiniMonthBackgrounds
        )
    }

    @ViewBuilder
    private var statisticsContent: some View {
        if isLandscape {
            HStack(alignment: .center, spacing: 34) {
                statisticsHero
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                LazyVGrid(columns: statisticsGridColumns, alignment: .leading, spacing: 18) {
                    wrappedStat(label: "Top Podcast", value: stats.topPodcastName)
                    wrappedStat(label: "Top Podcast Time", value: stats.topPodcastListeningTime)
                    wrappedStat(label: "Podcasts", value: formattedCount(stats.podcastCount))
                    wrappedStat(label: "Sessions", value: formattedCount(stats.listeningSessionCount))
                    wrappedStat(label: "Busiest Day", value: stats.busiestDayLabel)
                    wrappedStat(label: "Busiest Hour", value: stats.busiestHourLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: scaled(24, minimum: 10)) {
                statisticsHero

                LazyVGrid(columns: statisticsGridColumns, alignment: .leading, spacing: scaled(18, minimum: 8)) {
                    wrappedStat(label: "Top Podcast", value: stats.topPodcastName)
                    wrappedStat(label: "Top Podcast Time", value: stats.topPodcastListeningTime)
                    wrappedStat(label: "Podcasts", value: formattedCount(stats.podcastCount))
                    wrappedStat(label: "Sessions", value: formattedCount(stats.listeningSessionCount))
                    wrappedStat(label: "Busiest Day", value: stats.busiestDayLabel)
                    wrappedStat(label: "Busiest Hour", value: stats.busiestHourLabel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var statisticsHero: some View {
        VStack(alignment: .leading, spacing: scaled(8, minimum: 4)) {
            Text(stats.totalListeningTime)
                .font(.system(size: statisticsHeroFontSize, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .monospacedDigit()
            Text("total listening time")
                .font(.system(size: isLandscape ? 30 : scaled(28, minimum: 18), weight: .bold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var horizontalBarsCard: some View {
        let chartItems = Array(items.prefix(horizontalBarItemLimit))
        let chartTotalSeconds = max(totalListeningSeconds, chartItems.reduce(0) { $0 + $1.totalSeconds }, 1)

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.08, blue: 0.11),
                        Color(red: 0.07, green: 0.20, blue: 0.22),
                        Color(red: 0.35, green: 0.18, blue: 0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(34, minimum: 16)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                VStack(spacing: scaled(18, minimum: 8)) {
                    ForEach(chartItems) { item in
                        PodcastShareBarRow(
                            item: item,
                            duration: durationFormatter(item.totalSeconds),
                            totalSeconds: chartTotalSeconds,
                            textColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor,
                            trackColor: primaryTextColor.opacity(background.isLight ? 0.10 : 0.16),
                            barColor: primaryTextColor.opacity(background.isLight ? 0.68 : 0.72),
                            artworkShadowColor: artworkShadowColor,
                            scale: horizontalBarScale
                        )
                    }
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(58))
        }
    }

    private var pieChartCard: some View {
        let chartItems = Array(items.prefix(10))

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.06, blue: 0.10),
                        Color(red: 0.12, green: 0.13, blue: 0.23),
                        Color(red: 0.45, green: 0.20, blue: 0.21)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(34, minimum: 16)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                PodcastSharePieChart(
                    items: chartItems,
                    totalListeningSeconds: totalListeningSeconds,
                    durationFormatter: durationFormatter,
                    textColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    otherColor: primaryTextColor.opacity(background.isLight ? 0.16 : 0.24),
                    legendPlacement: isLandscape ? .trailing : .bottom,
                    scale: layoutScale
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(58))
        }
    }

    private func shareHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: scaled(12, minimum: 6)) {
            Text(title)
                .font(.system(size: scaled(78, minimum: 42), weight: .black, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.system(size: scaled(42, minimum: 24), weight: .bold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func wrappedStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: scaled(7, minimum: 3)) {
            Text(label)
                .font(.system(size: scaled(22, minimum: 14), weight: .medium, design: .rounded))
                .foregroundStyle(tertiaryTextColor)
            Text(value)
                .font(.system(size: scaled(34, minimum: 20), weight: .heavy, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.66)
        }
        .padding(.horizontal, scaled(20, minimum: 10))
        .padding(.vertical, scaled(16, minimum: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(primaryTextColor.opacity(background.isLight ? 0.08 : 0.11))
        )
    }

    private var statisticsGridColumns: [GridItem] {
        let columnCount = isLandscape ? 2 : (isSquare ? 2 : 1)
        let spacing: CGFloat = isLandscape ? 18 : scaled(16, minimum: 8)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private var statisticsHeroFontSize: CGFloat {
        if isLandscape {
            return 112
        }
        return scaled(96, minimum: 44)
    }

    private var horizontalBarItemLimit: Int {
        if isSquare {
            return 7
        }
        if isLandscape {
            return 6
        }
        return 10
    }

    private var horizontalBarScale: CGFloat {
        if isSquare {
            return 0.54
        }
        if isLandscape {
            return 0.50
        }
        return layoutScale
    }

    private func formattedCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: scaled(8, minimum: 4)) {
            HStack {
                Text("Up Next")
                    .font(.system(size: scaled(30, minimum: 18), weight: .bold, design: .rounded))
                Spacer()
                Text(dateRangeLabel)
                    .font(.system(size: scaled(24, minimum: 15), weight: .medium, design: .rounded))
                    .foregroundStyle(tertiaryTextColor)
            }

            Text(totalListeningLine)
                .font(.system(size: scaled(24, minimum: 15), weight: .semibold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var totalListeningLine: String {
        let hours = max(totalListeningSeconds / 3600, 0)
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = hours < 10 ? 1 : 0

        let formattedHours = formatter.string(from: NSNumber(value: hours)) ?? String(format: "%.0f", hours)
        return "\(formattedHours) hours of total listening time in Up Next"
    }

    private func podiumHeight(for rank: Int) -> CGFloat {
        switch rank {
        case 1:
            return 360
        case 2:
            return 280
        default:
            return 220
        }
    }
}

private struct CoverCloudLayout: View {
    let items: [TopPodcastShareItem]
    let shadowColor: Color

    var body: some View {
        GeometryReader { geometry in
            let placements = placements(in: geometry.size)

            ZStack {
                ForEach(placements) { placement in
                    PodcastShareArtwork(image: placement.item.coverImage, size: placement.size)
                        .shadow(color: shadowColor, radius: 14, y: 10)
                        .rotationEffect(.degrees(placement.rotation))
                        .position(x: placement.center.x, y: placement.center.y)
                        .zIndex(placement.zIndex)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func placements(in canvas: CGSize) -> [CoverCloudPlacement] {
        guard canvas.width > 0, canvas.height > 0, !items.isEmpty else { return [] }

        let sortedItems = items.sorted { lhs, rhs in
            if lhs.totalSeconds == rhs.totalSeconds {
                return lhs.rank < rhs.rank
            }
            return lhs.totalSeconds > rhs.totalSeconds
        }
        let maxSeconds = max(sortedItems.map(\.totalSeconds).max() ?? 1, 1)
        let countScale = min(1, max(0.42, sqrt(22 / Double(sortedItems.count))))
        let maxCoverSize = min(canvas.width, canvas.height) * 0.28
        let minCoverSize = max(42, min(canvas.width, canvas.height) * 0.065)

        var occupiedRects: [CGRect] = []
        var result: [CoverCloudPlacement] = []

        for (index, item) in sortedItems.enumerated() {
            let listeningShare = max(item.totalSeconds / maxSeconds, 0.04)
            let scaledSize = (74 + CGFloat(sqrt(listeningShare)) * 210) * CGFloat(countScale)
            let coverSize = min(maxCoverSize, max(minCoverSize, scaledSize))
            let rect = bestRect(
                for: item,
                index: index,
                coverSize: coverSize,
                canvas: canvas,
                occupiedRects: occupiedRects
            )
            let rotation = (deterministicUnit(item.rank * 7901 + index * 177) - 0.5) * 12

            occupiedRects.append(rect.insetBy(dx: -5, dy: -5))
            result.append(
                CoverCloudPlacement(
                    item: item,
                    size: coverSize,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    rotation: Double(rotation),
                    zIndex: Double(sortedItems.count - index)
                )
            )
        }

        return result
    }

    private func bestRect(
        for item: TopPodcastShareItem,
        index: Int,
        coverSize: CGFloat,
        canvas: CGSize,
        occupiedRects: [CGRect]
    ) -> CGRect {
        let defaultRect = CGRect(
            x: max((canvas.width - coverSize) / 2, 0),
            y: max((canvas.height - coverSize) / 2, 0),
            width: coverSize,
            height: coverSize
        )
        guard canvas.width > coverSize, canvas.height > coverSize else { return defaultRect }

        var bestRect = defaultRect
        var bestScore = CGFloat.greatestFiniteMagnitude

        for attempt in 0..<140 {
            let xSeed = item.rank * 9_973 + index * 479 + attempt * 37
            let ySeed = item.rank * 7_919 + index * 683 + attempt * 53
            let centerX = coverSize / 2 + deterministicUnit(xSeed) * (canvas.width - coverSize)
            let centerY = coverSize / 2 + deterministicUnit(ySeed) * (canvas.height - coverSize)
            let candidate = CGRect(
                x: centerX - coverSize / 2,
                y: centerY - coverSize / 2,
                width: coverSize,
                height: coverSize
            )
            let overlap = occupiedRects.reduce(CGFloat.zero) { total, rect in
                total + overlapArea(candidate, rect)
            }
            let centerBias = hypot(
                (centerX - canvas.width / 2) / canvas.width,
                (centerY - canvas.height / 2) / canvas.height
            )
            let score = overlap * 4 + centerBias * coverSize * 0.06 + CGFloat(attempt) * 0.001

            if score < bestScore {
                bestScore = score
                bestRect = candidate
                if overlap == 0, attempt > 10 {
                    break
                }
            }
        }

        return bestRect
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func deterministicUnit(_ seed: Int) -> CGFloat {
        let raw = sin(Double(seed) * 12.9898) * 43_758.5453
        return CGFloat(raw - floor(raw))
    }
}

private struct CoverCloudPlacement: Identifiable {
    let item: TopPodcastShareItem
    let size: CGFloat
    let center: CGPoint
    let rotation: Double
    let zIndex: Double

    var id: Int { item.id }
}

private struct CoverGridLayout: View {
    let items: [TopPodcastShareItem]
    let columns: Int
    let spacing: CGFloat
    let shadowColor: Color

    var body: some View {
        GeometryReader { geometry in
            let columnCount = max(columns, 1)
            let rowCount = max(Int(ceil(Double(items.count) / Double(columnCount))), 1)
            let availableWidth = max(geometry.size.width - CGFloat(columnCount - 1) * spacing, 1)
            let availableHeight = max(geometry.size.height - CGFloat(rowCount - 1) * spacing, 1)
            let coverSize = min(
                availableWidth / CGFloat(columnCount),
                availableHeight / CGFloat(rowCount)
            )
            let gridWidth = coverSize * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1)
            let gridHeight = coverSize * CGFloat(rowCount) + spacing * CGFloat(rowCount - 1)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(coverSize), spacing: spacing), count: columnCount),
                spacing: spacing
            ) {
                ForEach(items) { item in
                    PodcastShareArtwork(image: item.coverImage, size: coverSize)
                        .shadow(color: shadowColor, radius: 14, y: 10)
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct CoverCollageLandscapeLayout: View {
    let items: [TopPodcastShareItem]
    let shadowColor: Color

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            let featuredItems = Array(items.prefix(4))
            let lowerItems = Array(items.dropFirst(4).prefix(8))
            let featuredSpacing = max(canvas.width * 0.018, 18)
            let lowerSpacing = max(canvas.width * 0.012, 12)
            let rowSpacing = max(canvas.height * 0.055, 22)
            let featuredSize = rowCoverSize(
                itemCount: featuredItems.count,
                spacing: featuredSpacing,
                maxWidth: canvas.width,
                maxHeight: canvas.height * (lowerItems.isEmpty ? 0.82 : 0.56)
            )
            let lowerSize = rowCoverSize(
                itemCount: lowerItems.count,
                spacing: lowerSpacing,
                maxWidth: canvas.width,
                maxHeight: canvas.height * 0.32
            )

            VStack(spacing: rowSpacing) {
                artworkRow(featuredItems, size: featuredSize, spacing: featuredSpacing, shadowRadius: 18)

                if !lowerItems.isEmpty {
                    artworkRow(lowerItems, size: lowerSize, spacing: lowerSpacing, shadowRadius: 14)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
        }
    }

    private func rowCoverSize(itemCount: Int, spacing: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard itemCount > 0 else { return 1 }
        let availableWidth = maxWidth - CGFloat(itemCount - 1) * spacing
        return max(1, min(availableWidth / CGFloat(itemCount), maxHeight))
    }

    private func artworkRow(_ rowItems: [TopPodcastShareItem], size: CGFloat, spacing: CGFloat, shadowRadius: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(rowItems) { item in
                PodcastShareArtwork(image: item.coverImage, size: size)
                    .shadow(color: shadowColor, radius: shadowRadius, y: shadowRadius * 0.72)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PodiumPodcastColumn: View {
    let item: TopPodcastShareItem
    let height: CGFloat
    let duration: String
    let durationColor: Color
    let podiumFillColor: Color
    let podiumStrokeColor: Color
    let artworkShadowColor: Color
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 20 * scale) {
            PodcastShareArtwork(image: item.coverImage, size: (item.rank == 1 ? 250 : 210) * scale)
                .shadow(color: artworkShadowColor, radius: 18, y: 16)

            VStack(spacing: 8 * scale) {
                Text(item.podcastName)
                    .font(.system(size: (item.rank == 1 ? 34 : 28) * scale, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                Text(duration)
                    .font(.system(size: 24 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(durationColor)
                    .monospacedDigit()
            }
            .frame(height: 120 * scale, alignment: .top)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(podiumFillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(podiumStrokeColor, lineWidth: 2)
                    )
                Text("#\(item.rank)")
                    .font(.system(size: 72 * scale, weight: .black, design: .rounded))
                    .padding(.top, 34 * scale)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BillboardPodcastRow: View {
    let item: TopPodcastShareItem
    let duration: String
    let durationColor: Color
    let rowBackgroundColor: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 22 * scale) {
            Text("\(item.rank)")
                .font(.system(size: 42 * scale, weight: .black, design: .rounded))
                .monospacedDigit()
                .frame(width: 62 * scale, alignment: .trailing)

            PodcastShareArtwork(image: item.coverImage, size: 82 * scale)

            VStack(alignment: .leading, spacing: 6 * scale) {
                Text(item.podcastName)
                    .font(.system(size: 30 * scale, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                Text(duration)
                    .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(durationColor)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24 * scale)
        .padding(.vertical, 16 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackgroundColor)
        )
    }
}

private struct PodcastShareBarRow: View {
    let item: TopPodcastShareItem
    let duration: String
    let totalSeconds: Double
    let textColor: Color
    let secondaryTextColor: Color
    let trackColor: Color
    let barColor: Color
    let artworkShadowColor: Color
    let scale: CGFloat

    private var progress: CGFloat {
        CGFloat(min(max(item.totalSeconds / max(totalSeconds, 1), 0), 1))
    }

    var body: some View {
        HStack(spacing: 18 * scale) {
            PodcastShareArtwork(image: item.coverImage, size: 76 * scale)
                .shadow(color: artworkShadowColor, radius: 8, y: 5)

            VStack(alignment: .leading, spacing: 10 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
                    Text(item.podcastName)
                        .font(.system(size: 27 * scale, weight: .heavy, design: .rounded))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Spacer(minLength: 0)

                    Text(duration)
                        .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                        .monospacedDigit()
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(trackColor)

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(barColor)
                            .frame(width: max(geometry.size.width * progress, 8))
                    }
                }
                .frame(height: max(28 * scale, 12))
            }
        }
        .padding(16 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(textColor.opacity(0.10))
        )
    }
}

private struct PodcastSharePieChart: View {
    enum LegendPlacement {
        case trailing
        case bottom
    }

    let items: [TopPodcastShareItem]
    let totalListeningSeconds: Double
    let durationFormatter: (Double) -> String
    let textColor: Color
    let secondaryTextColor: Color
    let otherColor: Color
    let legendPlacement: LegendPlacement
    let scale: CGFloat

    private var segments: [PodcastSharePieSegment] {
        let totalSeconds = max(totalListeningSeconds, items.reduce(0) { $0 + $1.totalSeconds }, 1)
        var startAngle = -90.0
        var result: [PodcastSharePieSegment] = []

        for item in items where item.totalSeconds > 0 {
            let sweep = max(item.totalSeconds / totalSeconds * 360, 0)
            guard sweep > 0 else { continue }
            result.append(
                PodcastSharePieSegment(
                    id: item.id,
                    item: item,
                    title: item.podcastName,
                    seconds: item.totalSeconds,
                    startAngle: startAngle,
                    endAngle: startAngle + sweep,
                    color: .clear
                )
            )
            startAngle += sweep
        }

        let displayedSeconds = items.reduce(0) { $0 + $1.totalSeconds }
        let otherSeconds = max(totalSeconds - displayedSeconds, 0)
        if otherSeconds > totalSeconds * 0.002 {
            result.append(
                PodcastSharePieSegment(
                    id: -1,
                    item: nil,
                    title: "Other",
                    seconds: otherSeconds,
                    startAngle: startAngle,
                    endAngle: 270,
                    color: otherColor
                )
            )
        }

        return result
    }

    var body: some View {
        GeometryReader { geometry in
            if legendPlacement == .trailing {
                let chartSize = min(geometry.size.height * 0.92, geometry.size.width * 0.40)
                let leadingInset = max(geometry.size.width * 0.12, 110 * scale)
                let trailingInset = max(geometry.size.width * 0.04, 30 * scale)

                HStack(spacing: 34 * scale) {
                    Spacer(minLength: leadingInset)
                    pie(size: chartSize)
                    legend
                    Spacer(minLength: trailingInset)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                let chartSize = min(geometry.size.height * 0.62, geometry.size.width * 0.88)

                VStack(spacing: 24 * scale) {
                    pie(size: chartSize)
                    legend
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func pie(size: CGFloat) -> some View {
        ZStack {
            ForEach(segments) { segment in
                PodcastSharePieSlice(segment: segment, size: size)
            }

            Circle()
                .stroke(textColor.opacity(0.24), lineWidth: 3)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
    }

    private var legend: some View {
        Group {
            if legendPlacement == .trailing {
                VStack(alignment: .leading, spacing: 15 * scale) {
                    legendRows(limit: 7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 18 * scale), count: 2),
                    alignment: .leading,
                    spacing: 12 * scale
                ) {
                    legendRows(limit: 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func legendRows(limit: Int) -> some View {
        ForEach(segments.prefix(limit)) { segment in
            PodcastSharePieLegendRow(
                segment: segment,
                duration: durationFormatter(segment.seconds),
                textColor: textColor,
                secondaryTextColor: secondaryTextColor,
                otherColor: otherColor,
                scale: scale
            )
        }

        if segments.count > limit {
            Text("+\(segments.count - limit) more")
                .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
        }
    }
}

private struct PodcastSharePieSegment: Identifiable {
    let id: Int
    let item: TopPodcastShareItem?
    let title: String
    let seconds: Double
    let startAngle: Double
    let endAngle: Double
    let color: Color
}

private struct PodcastSharePieSlice: View {
    let segment: PodcastSharePieSegment
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = segment.item?.coverImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(sliceShape)
            } else {
                sliceShape
                    .fill(segment.color)
            }

            sliceShape
                .stroke(.white.opacity(0.30), lineWidth: 3)
        }
        .frame(width: size, height: size)
    }

    private var sliceShape: PodcastSharePieSliceShape {
        PodcastSharePieSliceShape(startAngle: segment.startAngle, endAngle: segment.endAngle)
    }
}

private struct PodcastSharePieLegendRow: View {
    let segment: PodcastSharePieSegment
    let duration: String
    let textColor: Color
    let secondaryTextColor: Color
    let otherColor: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 12 * scale) {
            ZStack {
                if let image = segment.item?.coverImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    otherColor
                }
            }
            .frame(width: 42 * scale, height: 42 * scale)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.system(size: 23 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(duration)
                    .font(.system(size: 19 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
                    .monospacedDigit()
            }
        }
    }
}

private struct PodcastSharePieSliceShape: Shape {
    let startAngle: Double
    let endAngle: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private enum PodcastShareRenderAspect {
    case portrait
    case square
    case landscape
}

private struct PodcastShareCalendarLayout: View {
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
    let entries: [TopPodcastShareTimelineEntry]
    let renderAspect: PodcastShareRenderAspect
    let textColor: Color
    let secondaryTextColor: Color
    let cellFillColor: Color
    let emptyCellFillColor: Color
    let borderColor: Color
    let shadowColor: Color
    let durationFormatter: (Double) -> String

    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        Group {
            switch period {
            case .day:
                PodcastShareClockView(
                    periodStart: periodStart,
                    entries: entries,
                    textColor: textColor,
                    secondaryTextColor: secondaryTextColor,
                    borderColor: borderColor,
                    shadowColor: shadowColor,
                    durationFormatter: durationFormatter
                )
            case .week:
                weekView
            case .month:
                monthView
            case .year:
                yearView
            case .forever:
                EmptyView()
            }
        }
    }

    private var weekdayLabels: [String] {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        let symbols = formatter.veryShortWeekdaySymbols ?? calendar.veryShortWeekdaySymbols
        let firstIndex = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(firstIndex + $0) % 7] }
    }

    private var weekView: some View {
        HStack(spacing: calendarSpacing) {
            ForEach(weekDates, id: \.self) { date in
                PodcastShareWeekDayCell(
                    title: weekdayTitle(for: date),
                    subtitle: dayNumber(for: date),
                    winner: winner(in: dateInterval(start: date, component: .day)),
                    textColor: textColor,
                    secondaryTextColor: secondaryTextColor,
                    fillColor: cellFillColor,
                    emptyFillColor: emptyCellFillColor,
                    borderColor: borderColor,
                    durationFormatter: durationFormatter
                )
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private var monthView: some View {
        VStack(spacing: calendarSpacing) {
            HStack(spacing: calendarSpacing) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: weekdayFontSize, weight: .black, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: calendarSpacing), count: 7),
                spacing: calendarSpacing
            ) {
                ForEach(Array(monthGridDates.enumerated()), id: \.offset) { _, date in
                    if let date {
                        PodcastShareMonthDayCell(
                            title: dayNumber(for: date),
                            winner: winner(in: dateInterval(start: date, component: .day)),
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            fillColor: cellFillColor,
                            emptyFillColor: emptyCellFillColor,
                            borderColor: borderColor,
                            durationFormatter: durationFormatter
                        )
                        .aspectRatio(1, contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(emptyCellFillColor.opacity(0.45))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }

    private var yearView: some View {
        let columnCount = renderAspect == .landscape ? 4 : 3
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: calendarSpacing), count: columnCount),
            spacing: calendarSpacing
        ) {
            ForEach(monthDates, id: \.self) { date in
                PodcastShareYearMonthCell(
                    title: monthTitle(for: date),
                    winner: winner(in: dateInterval(start: date, component: .month)),
                    textColor: textColor,
                    secondaryTextColor: secondaryTextColor,
                    fillColor: cellFillColor,
                    emptyFillColor: emptyCellFillColor,
                    borderColor: borderColor,
                    durationFormatter: durationFormatter
                )
                .aspectRatio(1.12, contentMode: .fit)
            }
        }
    }

    private var weekDates: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: periodStart) }
    }

    private var calendarSpacing: CGFloat {
        switch renderAspect {
        case .portrait:
            return 8
        case .square:
            return 6
        case .landscape:
            return 6
        }
    }

    private var weekdayFontSize: CGFloat {
        switch renderAspect {
        case .portrait:
            return 18
        case .square:
            return 15
        case .landscape:
            return 14
        }
    }

    private var monthDates: [Date] {
        (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: periodStart) }
    }

    private var monthGridDates: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: periodStart) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: periodStart)
        let leadingEmptyCellCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: periodStart)
        }
        let trailingEmptyCellCount = (7 - ((leadingEmptyCellCount + days.count) % 7)) % 7
        return Array(repeating: nil, count: leadingEmptyCellCount) + days.map(Optional.some) + Array(repeating: nil, count: trailingEmptyCellCount)
    }

    private func winner(in interval: DateInterval) -> PodcastShareCalendarWinner? {
        rankedWinners(in: interval, limit: 1).first
    }

    private func rankedWinners(in interval: DateInterval, limit: Int) -> [PodcastShareCalendarWinner] {
        let values = entries.filter { interval.contains($0.date) }
        let grouped = Dictionary(grouping: values, by: \.podcastName)
            .mapValues { groupedEntries in
                groupedEntries.reduce(0) { $0 + $1.totalSeconds }
            }
        return grouped
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .map { item in
                let coverImage = values.first(where: { $0.podcastName == item.key && $0.coverImage != nil })?.coverImage
                return PodcastShareCalendarWinner(podcastName: item.key, totalSeconds: item.value, coverImage: coverImage)
            }
    }

    private func entries(in interval: DateInterval) -> [TopPodcastShareTimelineEntry] {
        entries
            .filter { interval.contains($0.date) }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date {
                    return lhs.totalSeconds > rhs.totalSeconds
                }
                return lhs.date < rhs.date
            }
    }

    private func dateInterval(start: Date, component: Calendar.Component) -> DateInterval {
        let end = calendar.date(byAdding: component, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    private func weekdayTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }

    private func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }

    private func dayNumber(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter.string(from: date)
    }
}

private struct PodcastShareCalendarWinner {
    let podcastName: String
    let totalSeconds: Double
    let coverImage: UIImage?
}

private struct PodcastShareYearDailyCalendarLayout: View {
    let periodStart: Date
    let entries: [TopPodcastShareTimelineEntry]
    let renderAspect: PodcastShareRenderAspect
    let textColor: Color
    let secondaryTextColor: Color
    let cellFillColor: Color
    let emptyCellFillColor: Color
    let borderColor: Color
    let usesMonthlyBackgrounds: Bool

    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        GeometryReader { geometry in
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: monthBlockSpacing), count: monthColumnCount),
                spacing: monthBlockSpacing
            ) {
                ForEach(monthDates, id: \.self) { monthStart in
                    PodcastShareMiniMonthBlock(
                        monthStart: monthStart,
                        days: monthGridDates(for: monthStart),
                        renderAspect: renderAspect,
                        winnerForDay: { date in
                            winner(in: dateInterval(start: date, component: .day))
                        },
                        textColor: textColor,
                        secondaryTextColor: secondaryTextColor,
                        cellFillColor: cellFillColor,
                        emptyCellFillColor: emptyCellFillColor,
                        borderColor: borderColor,
                        usesMonthlyBackgrounds: usesMonthlyBackgrounds
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }

    private var monthColumnCount: Int {
        switch renderAspect {
        case .portrait:
            return 3
        case .square:
            return 4
        case .landscape:
            return 6
        }
    }

    private var monthBlockSpacing: CGFloat {
        switch renderAspect {
        case .portrait:
            return 10
        case .square:
            return 8
        case .landscape:
            return 8
        }
    }

    private var monthDates: [Date] {
        (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: periodStart) }
    }

    private func monthGridDates(for monthStart: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingEmptyCellCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        }
        let occupiedCellCount = leadingEmptyCellCount + days.count
        let trailingEmptyCellCount = max(42 - occupiedCellCount, 0)
        return Array(repeating: nil, count: leadingEmptyCellCount) + days.map(Optional.some) + Array(repeating: nil, count: trailingEmptyCellCount)
    }

    private func winner(in interval: DateInterval) -> PodcastShareCalendarWinner? {
        let values = entries.filter { interval.contains($0.date) }
        let grouped = Dictionary(grouping: values, by: \.podcastName)
            .mapValues { groupedEntries in
                groupedEntries.reduce(0) { $0 + $1.totalSeconds }
            }
        guard let best = grouped.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        let coverImage = values.first(where: { $0.podcastName == best.key && $0.coverImage != nil })?.coverImage
        return PodcastShareCalendarWinner(podcastName: best.key, totalSeconds: best.value, coverImage: coverImage)
    }

    private func dateInterval(start: Date, component: Calendar.Component) -> DateInterval {
        let end = calendar.date(byAdding: component, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }
}

private struct PodcastShareMiniMonthBlock: View {
    let monthStart: Date
    let days: [Date?]
    let renderAspect: PodcastShareRenderAspect
    let winnerForDay: (Date) -> PodcastShareCalendarWinner?
    let textColor: Color
    let secondaryTextColor: Color
    let cellFillColor: Color
    let emptyCellFillColor: Color
    let borderColor: Color
    let usesMonthlyBackgrounds: Bool

    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        ZStack {
            miniMonthBackground

            VStack(alignment: .leading, spacing: blockInnerSpacing) {
                HStack {
                    Text(monthTitle)
                        .font(.system(size: monthTitleFontSize, weight: .black, design: .rounded))
                        .foregroundStyle(usesMonthlyBackgrounds ? .white : textColor)
                        .shadow(color: usesMonthlyBackgrounds ? .black.opacity(0.45) : .clear, radius: 2, y: 1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: dayCellSpacing), count: 7),
                    spacing: dayCellSpacing
                ) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                        if let date {
                            PodcastShareMiniDayCell(
                                day: calendar.component(.day, from: date),
                                winner: winnerForDay(date),
                                renderAspect: renderAspect,
                                textColor: usesMonthlyBackgrounds ? .white : textColor,
                                secondaryTextColor: usesMonthlyBackgrounds ? .white.opacity(0.74) : secondaryTextColor,
                                fillColor: usesMonthlyBackgrounds ? .white.opacity(0.12) : cellFillColor,
                                emptyFillColor: usesMonthlyBackgrounds ? .black.opacity(0.18) : emptyCellFillColor,
                                borderColor: usesMonthlyBackgrounds ? .white.opacity(0.18) : borderColor
                            )
                            .aspectRatio(1, contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(usesMonthlyBackgrounds ? .black.opacity(0.14) : emptyCellFillColor.opacity(0.35))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            .padding(blockPadding)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var miniMonthBackground: some View {
        if usesMonthlyBackgrounds {
            SeasonalPodcastShareBackground(month: calendar.component(.month, from: monthStart))
                .overlay(.black.opacity(0.18))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cellFillColor.opacity(0.55))
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: monthStart)
    }

    private var blockPadding: CGFloat {
        renderAspect == .portrait ? 6 : 5
    }

    private var blockInnerSpacing: CGFloat {
        renderAspect == .portrait ? 4 : 3
    }

    private var dayCellSpacing: CGFloat {
        renderAspect == .portrait ? 2 : 1.5
    }

    private var monthTitleFontSize: CGFloat {
        switch renderAspect {
        case .portrait:
            return 13
        case .square:
            return 11
        case .landscape:
            return 10
        }
    }
}

private struct PodcastShareMiniDayCell: View {
    let day: Int
    let winner: PodcastShareCalendarWinner?
    let renderAspect: PodcastShareRenderAspect
    let textColor: Color
    let secondaryTextColor: Color
    let fillColor: Color
    let emptyFillColor: Color
    let borderColor: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let winner {
                PodcastShareCoverFill(image: winner.coverImage)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(emptyFillColor)
            }

            LinearGradient(
                colors: [.black.opacity(winner == nil ? 0 : 0.58), .black.opacity(0.04), .black.opacity(winner == nil ? 0 : 0.20)],
                startPoint: .top,
                endPoint: .bottom
            )

            Text("\(day)")
                .font(.system(size: dayFontSize, weight: .black, design: .rounded))
                .foregroundStyle(winner == nil ? secondaryTextColor.opacity(0.75) : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(2)
        }
        .background(fillColor)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(borderColor.opacity(0.65), lineWidth: 0.5)
        )
    }

    private var dayFontSize: CGFloat {
        switch renderAspect {
        case .portrait:
            return 7
        case .square:
            return 6
        case .landscape:
            return 5
        }
    }
}

private struct PodcastShareWeekDayCell: View {
    let title: String
    let subtitle: String
    let winner: PodcastShareCalendarWinner?
    let textColor: Color
    let secondaryTextColor: Color
    let fillColor: Color
    let emptyFillColor: Color
    let borderColor: Color
    let durationFormatter: (Double) -> String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let winner {
                PodcastShareCoverFill(image: winner.coverImage)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(emptyFillColor)
            }

            LinearGradient(
                colors: [.black.opacity(winner == nil ? 0 : 0.68), .black.opacity(0.06), .black.opacity(winner == nil ? 0 : 0.52)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(subtitle)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(winner == nil ? textColor : .white)
            .padding(7)

            if let winner {
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    Text(winner.podcastName)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    Text(durationFormatter(winner.totalSeconds))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .monospacedDigit()
                }
                .padding(7)
            } else {
                Text("No plays")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(secondaryTextColor.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(4)
            }
        }
        .background(fillColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

private struct PodcastShareMonthDayCell: View {
    let title: String
    let winner: PodcastShareCalendarWinner?
    let textColor: Color
    let secondaryTextColor: Color
    let fillColor: Color
    let emptyFillColor: Color
    let borderColor: Color
    let durationFormatter: (Double) -> String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let winner {
                PodcastShareCoverFill(image: winner.coverImage)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(emptyFillColor)
            }

            LinearGradient(
                colors: [.black.opacity(winner == nil ? 0 : 0.68), .black.opacity(0.05), .black.opacity(winner == nil ? 0 : 0.50)],
                startPoint: .top,
                endPoint: .bottom
            )

            Text(title)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(winner == nil ? textColor : .white)
                .padding(6)

            if let winner {
                VStack(alignment: .leading, spacing: 1) {
                    Spacer(minLength: 0)
                    Text(winner.podcastName)
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    Text(durationFormatter(winner.totalSeconds))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(6)
            } else {
                Text("No plays")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(secondaryTextColor.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(4)
            }
        }
        .background(fillColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

private struct PodcastShareYearMonthCell: View {
    let title: String
    let winner: PodcastShareCalendarWinner?
    let textColor: Color
    let secondaryTextColor: Color
    let fillColor: Color
    let emptyFillColor: Color
    let borderColor: Color
    let durationFormatter: (Double) -> String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(winner == nil ? emptyFillColor : fillColor)

            if let winner {
                PodcastShareCoverFill(image: winner.coverImage)
                    .opacity(0.92)

                LinearGradient(
                    colors: [.black.opacity(0.74), .black.opacity(0.14), .black.opacity(0.68)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(winner.podcastName)
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.62)
                    Text(durationFormatter(winner.totalSeconds))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .monospacedDigit()
                }
                .padding(9)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(textColor)
                    Spacer()
                    Text("No plays")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(secondaryTextColor.opacity(0.72))
                }
                .padding(9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

private struct PodcastShareCalendarCell: View {
    let title: String
    let subtitle: String?
    let winner: PodcastShareCalendarWinner?
    let textColor: Color
    let secondaryTextColor: Color
    let fillColor: Color
    let emptyFillColor: Color
    let borderColor: Color
    let shadowColor: Color
    let durationFormatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let winner {
                PodcastShareArtwork(image: winner.coverImage, size: 42)
                    .shadow(color: shadowColor, radius: 6, y: 4)
                Text(winner.podcastName)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                Text(durationFormatter(winner.totalSeconds))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .monospacedDigit()
            } else {
                Text("No plays")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(secondaryTextColor.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(winner == nil ? emptyFillColor : fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

private struct PodcastShareClockView: View {
    let periodStart: Date
    let entries: [TopPodcastShareTimelineEntry]
    let textColor: Color
    let secondaryTextColor: Color
    let borderColor: Color
    let shadowColor: Color
    let durationFormatter: (Double) -> String

    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size * 0.40
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let markers = hourWinners(in: periodStart)
            let markerSize = max(min(size * 0.13, 74), 38)

            ZStack {
                Circle()
                    .stroke(borderColor, lineWidth: 3)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                ForEach(0..<24, id: \.self) { hour in
                    clockTick(hour: hour, center: center, radius: radius, size: size)
                }

                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    clockLabel(hour: hour, center: center, radius: radius * 0.78)
                }

                ForEach(markers) { marker in
                    PodcastShareClockMarker(
                        marker: marker,
                        size: markerSize,
                        shadowColor: shadowColor
                    )
                    .position(clockPoint(hour: marker.hour, center: center, radius: radius))
                }

                VStack(spacing: 6) {
                    Text(localizedDateString(for: periodStart))
                        .font(.system(size: max(size * 0.050, 20), weight: .black, design: .rounded))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(markers.isEmpty ? "No plays" : "\(markers.count) active hours")
                        .font(.system(size: max(size * 0.032, 14), weight: .bold, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                }
                .frame(width: radius * 1.05)
                .position(center)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func hourWinners(in dayStart: Date) -> [PodcastShareClockMarkerModel] {
        (0..<24).compactMap { hour in
            guard
                let start = calendar.date(byAdding: .hour, value: hour, to: dayStart),
                let end = calendar.date(byAdding: .hour, value: 1, to: start)
            else { return nil }

            let values = entries.filter { $0.date >= start && $0.date < end }
            let grouped = Dictionary(grouping: values, by: \.podcastName)
                .mapValues { groupedEntries in
                    groupedEntries.reduce(0) { $0 + $1.totalSeconds }
                }
            guard let best = grouped.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
            let image = values.first(where: { $0.podcastName == best.key && $0.coverImage != nil })?.coverImage
            return PodcastShareClockMarkerModel(
                hour: hour,
                podcastName: best.key,
                totalSeconds: best.value,
                coverImage: image,
                label: durationFormatter(best.value)
            )
        }
    }

    private func clockPoint(hour: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (Double(hour) / 24.0 * 360.0 - 90.0) * .pi / 180.0
        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }

    private func clockTick(hour: Int, center: CGPoint, radius: CGFloat, size: CGFloat) -> some View {
        let isMajor = hour.isMultiple(of: 6)
        let point = clockPoint(hour: hour, center: center, radius: radius)
        return Circle()
            .fill(textColor.opacity(isMajor ? 0.78 : 0.34))
            .frame(width: isMajor ? 8 : 4, height: isMajor ? 8 : 4)
            .position(point)
    }

    private func clockLabel(hour: Int, center: CGPoint, radius: CGFloat) -> some View {
        Text(String(format: "%02d", hour))
            .font(.system(size: 16, weight: .black, design: .rounded))
            .foregroundStyle(secondaryTextColor)
            .position(clockPoint(hour: hour, center: center, radius: radius))
    }

    private func localizedDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct PodcastShareClockMarkerModel: Identifiable {
    let hour: Int
    let podcastName: String
    let totalSeconds: Double
    let coverImage: UIImage?
    let label: String

    var id: Int { hour }
}

private struct PodcastShareClockMarker: View {
    let marker: PodcastShareClockMarkerModel
    let size: CGFloat
    let shadowColor: Color

    var body: some View {
        PodcastShareArtwork(image: marker.coverImage, size: size)
            .shadow(color: shadowColor, radius: 8, y: 5)
            .overlay(alignment: .bottomTrailing) {
                Text("\(marker.hour)")
                    .font(.system(size: max(size * 0.24, 10), weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .offset(x: 3, y: 3)
            }
    }
}

private struct PodcastShareCoverFill: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.40, blue: 0.25),
                            Color(red: 0.12, green: 0.55, blue: 0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
        .clipped()
    }
}

private struct PodcastShareArtwork: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.40, blue: 0.25),
                            Color(red: 0.12, green: 0.55, blue: 0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 2)
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
