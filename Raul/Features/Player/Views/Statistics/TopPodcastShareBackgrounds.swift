import SwiftUI

struct SeasonalPodcastShareBackground: View {
    let config: SeasonalBackgroundConfig

    init(month: Int) {
        self.config = SeasonalBackgroundConfig.config(for: month)
    }

    init(config: SeasonalBackgroundConfig) {
        self.config = config
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: config.baseColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.black.opacity(config.centerDimming),
                    Color.black.opacity(config.centerDimming * 0.62),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: 780
            )

            GeometryReader { geometry in
                ZStack {
                    seasonalScene(in: geometry.size)
                }
            }
        }
    }

    @ViewBuilder
    private func seasonalScene(in size: CGSize) -> some View {
        switch config.kind {
        case .winter:
            winterScene(in: size)
        case .frost:
            frostScene(in: size)
        case .spring:
            springScene(in: size)
        case .meadow:
            meadowScene(in: size)
        case .summer:
            summerScene(in: size)
        case .beach:
            beachScene(in: size)
        case .autumn:
            autumnScene(in: size)
        case .harvest:
            harvestScene(in: size)
        case .rain:
            rainScene(in: size)
        case .festive:
            festiveScene(in: size)
        case .fireworks:
            fireworksScene(in: size)
        case .confetti:
            confettiScene(in: size)
        case .easter:
            easterScene(in: size)
        case .crescent:
            crescentScene(in: size)
        case .lanterns:
            lanternScene(in: size)
        case .candles:
            candleScene(in: size)
        case .colorClouds:
            colorCloudScene(in: size)
        case .diyas:
            diyaScene(in: size)
        case .midsummer:
            midsummerScene(in: size)
        case .halloween:
            halloweenScene(in: size)
        case .christmasTrees:
            christmasTreeScene(in: size)
        }
    }

    private func frostScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                snowflake(index: index, in: size)
            }

            ForEach(0..<5, id: \.self) { index in
                frostMountain(index: index, in: size)
            }

            bottomDrift(size: size, color: Color.white.opacity(0.26), height: 0.18, yOffset: 0.10)
        }
    }

    private func winterScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.18, y: 0.14, diameter: 0.16)
                .opacity(0.36)

            ForEach(0..<34, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index % 3 == 0 ? 0.78 : 0.46))
                    .frame(width: snowSize(index), height: snowSize(index))
                    .position(edgePoint(index: index, in: size, topBias: 0.78))
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.42), height: 0.22, yOffset: 0.06)
            bottomDrift(size: size, color: Color.white.opacity(0.24), height: 0.16, yOffset: 0.10)
        }
    }

    private func springScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.84, y: 0.13, diameter: 0.15)
                .opacity(0.34)

            ForEach(0..<18, id: \.self) { index in
                flower(index: index, size: flowerSize(index), color: config.accentColors[index % config.accentColors.count])
                    .position(bottomSidePoint(index: index, in: size))
            }

            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[1].opacity(0.26))
                    .frame(width: max(size.width * 0.006, 4), height: max(size.height * 0.12, 50))
                    .rotationEffect(.degrees(Double(index % 2 == 0 ? -10 : 12)))
                    .position(x: size.width * sideX(index), y: size.height * (0.80 + CGFloat(index % 4) * 0.045))
            }

            bottomDrift(size: size, color: config.accentColors[2].opacity(0.22), height: 0.18, yOffset: 0.08)
        }
    }

    private func meadowScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.18, y: 0.15, diameter: 0.18)
                .opacity(0.30)

            ForEach(0..<26, id: \.self) { index in
                flower(index: index, size: flowerSize(index) * 1.08, color: config.accentColors[index % config.accentColors.count])
                    .position(bottomSidePoint(index: index + 4, in: size))
            }

            ForEach(0..<18, id: \.self) { index in
                grassBlade(index: index, in: size)
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.28), height: 0.19, yOffset: 0.09)
        }
    }

    private func summerScene(in size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(config.accentColors[0].opacity(0.78))
                .frame(width: size.shortSide * 0.18, height: size.shortSide * 0.18)
                .position(x: size.width * 0.82, y: size.height * 0.16)

            ForEach(0..<3, id: \.self) { index in
                summerWave(index: index, in: size)
            }

            bottomDrift(size: size, color: config.accentColors.last?.opacity(0.36) ?? .white.opacity(0.28), height: 0.16, yOffset: 0.11)
        }
    }

    private func beachScene(in size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(config.accentColors[0].opacity(0.84))
                .frame(width: size.shortSide * 0.20, height: size.shortSide * 0.20)
                .position(x: size.width * 0.82, y: size.height * 0.15)

            ForEach(0..<4, id: \.self) { index in
                summerWave(index: index, in: size)
            }

            WaveShape(phase: 0.42)
                .fill(config.accentColors[3].opacity(0.54))
                .frame(width: size.width * 1.16, height: size.height * 0.20)
                .position(x: size.width * 0.50, y: size.height * 0.93)

            ForEach(0..<3, id: \.self) { index in
                beachUmbrella(index: index, in: size)
            }
        }
    }

    private func autumnScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.16, y: 0.15, diameter: 0.17)
                .opacity(0.30)

            ForEach(0..<30, id: \.self) { index in
                LeafShape()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.72))
                    .frame(width: leafSize(index), height: leafSize(index) * 1.42)
                    .rotationEffect(.degrees(Double((index * 37) % 120) - 60))
                    .position(autumnPoint(index: index, in: size))
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.24), height: 0.18, yOffset: 0.09)
        }
    }

    private func harvestScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.83, y: 0.16, diameter: 0.18)
                .opacity(0.32)

            ForEach(0..<26, id: \.self) { index in
                grainStalk(index: index, in: size)
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.26), height: 0.18, yOffset: 0.09)
        }
    }

    private func rainScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                cloud(index: index, size: size)
                    .position(x: size.width * (0.14 + CGFloat(index) * 0.24), y: size.height * (index % 2 == 0 ? 0.13 : 0.20))
                    .opacity(0.32)
            }

            ForEach(0..<28, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.40))
                    .frame(width: max(size.shortSide * 0.006, 4), height: max(size.shortSide * 0.05, 16))
                    .rotationEffect(.degrees(16))
                    .position(edgePoint(index: index, in: size, topBias: 0.72))
            }

            bottomDrift(size: size, color: config.accentColors[0].opacity(0.20), height: 0.16, yOffset: 0.10)
        }
    }

    private func festiveScene(in size: CGSize) -> some View {
        ZStack {
            winterScene(in: size)

            ForEach(0..<18, id: \.self) { index in
                Circle()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.86))
                    .frame(width: lightSize(index), height: lightSize(index))
                    .shadow(color: config.accentColors[index % config.accentColors.count].opacity(0.8), radius: 10)
                    .position(x: size.width * (0.04 + CGFloat(index) / 17 * 0.92), y: size.height * (index % 2 == 0 ? 0.09 : 0.15))
            }
        }
    }

    private func christmasTreeScene(in size: CGSize) -> some View {
        ZStack {
            winterScene(in: size).opacity(0.74)

            ForEach(0..<4, id: \.self) { index in
                christmasTree(index: index, in: size)
            }

            ForEach(0..<20, id: \.self) { index in
                Circle()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.82))
                    .frame(width: lightSize(index), height: lightSize(index))
                    .shadow(color: config.accentColors[index % config.accentColors.count].opacity(0.7), radius: 8)
                    .position(edgePoint(index: index + 45, in: size, topBias: 0.70))
            }
        }
    }

    private func fireworksScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<7, id: \.self) { index in
                burst(index: index, in: size)
            }
            confettiScene(in: size).opacity(0.36)
        }
    }

    private func confettiScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<42, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.74))
                    .frame(width: confettiWidth(index), height: confettiHeight(index))
                    .rotationEffect(.degrees(Double((index * 31) % 160) - 80))
                    .position(edgePoint(index: index, in: size, topBias: 0.68))
            }
            bottomDrift(size: size, color: config.accentColors[0].opacity(0.18), height: 0.16, yOffset: 0.10)
        }
    }

    private func easterScene(in size: CGSize) -> some View {
        ZStack {
            springScene(in: size)
            ForEach(0..<8, id: \.self) { index in
                EggShape()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.72))
                    .frame(width: eggSize(index) * 0.72, height: eggSize(index))
                    .rotationEffect(.degrees(Double((index * 23) % 34) - 17))
                    .position(bottomSidePoint(index: index + 6, in: size))
            }
        }
    }

    private func crescentScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<20, id: \.self) { index in
                star(index: index, in: size)
            }
            CrescentShape()
                .fill(config.accentColors[0].opacity(0.86))
                .frame(width: size.shortSide * 0.18, height: size.shortSide * 0.18)
                .position(x: size.width * 0.84, y: size.height * 0.16)
            bottomDrift(size: size, color: config.accentColors[1].opacity(0.18), height: 0.16, yOffset: 0.10)
        }
    }

    private func lanternScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<7, id: \.self) { index in
                lantern(index: index, in: size)
            }
            ForEach(0..<18, id: \.self) { index in
                star(index: index, in: size).opacity(0.7)
            }
        }
    }

    private func candleScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                star(index: index, in: size).opacity(0.5)
            }
            HStack(alignment: .bottom, spacing: size.shortSide * 0.018) {
                ForEach(0..<9, id: \.self) { index in
                    candle(index: index, height: size.shortSide * (0.14 + CGFloat(index % 3) * 0.025))
                }
            }
            .position(x: size.width * 0.5, y: size.height * 0.86)
        }
    }

    private func colorCloudScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<20, id: \.self) { index in
                Circle()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.40))
                    .frame(width: colorCloudSize(index), height: colorCloudSize(index))
                    .blur(radius: colorCloudSize(index) * 0.18)
                    .position(autumnPoint(index: index, in: size))
            }
        }
    }

    private func diyaScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<22, id: \.self) { index in
                star(index: index, in: size)
            }
            ForEach(0..<7, id: \.self) { index in
                DiyaShape()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.82))
                    .frame(width: size.shortSide * 0.09, height: size.shortSide * 0.052)
                    .position(x: size.width * (0.08 + CGFloat(index) / 6 * 0.84), y: size.height * (index % 2 == 0 ? 0.84 : 0.91))
            }
        }
    }

    private func midsummerScene(in size: CGSize) -> some View {
        ZStack {
            summerScene(in: size)
            ForEach(0..<16, id: \.self) { index in
                flower(index: index, size: flowerSize(index) * 0.95, color: config.accentColors[index % config.accentColors.count])
                    .position(bottomSidePoint(index: index, in: size))
            }
        }
    }

    private func halloweenScene(in size: CGSize) -> some View {
        ZStack {
            autumnScene(in: size)
            Circle()
                .fill(config.accentColors[0].opacity(0.60))
                .frame(width: size.shortSide * 0.17, height: size.shortSide * 0.17)
                .position(x: size.width * 0.84, y: size.height * 0.15)
            ForEach(0..<10, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[2].opacity(0.42))
                    .frame(width: batWidth(index), height: max(batWidth(index) * 0.26, 6))
                    .rotationEffect(.degrees(Double((index * 29) % 50) - 25))
                    .position(edgePoint(index: index + 20, in: size, topBias: 0.92))
            }
        }
    }

    private func flower(index: Int, size: CGFloat, color: Color) -> some View {
        ZStack {
            ForEach(0..<5, id: \.self) { petal in
                Capsule()
                    .fill(color.opacity(0.72))
                    .frame(width: size * 0.36, height: size * 0.72)
                    .offset(y: -size * 0.24)
                    .rotationEffect(.degrees(Double(petal) * 72))
            }
            Circle()
                .fill(config.accentColors[0].opacity(0.92))
                .frame(width: size * 0.26, height: size * 0.26)
        }
    }

    private func cloud(index: Int, size: CGSize) -> some View {
        let cloudWidth = size.shortSide * (0.18 + CGFloat(index % 2) * 0.04)
        return ZStack {
            Capsule()
                .fill(Color.white.opacity(0.36))
                .frame(width: cloudWidth, height: cloudWidth * 0.34)
            Circle()
                .fill(Color.white.opacity(0.34))
                .frame(width: cloudWidth * 0.42, height: cloudWidth * 0.42)
                .offset(x: -cloudWidth * 0.20, y: -cloudWidth * 0.10)
            Circle()
                .fill(Color.white.opacity(0.30))
                .frame(width: cloudWidth * 0.50, height: cloudWidth * 0.50)
                .offset(x: cloudWidth * 0.12, y: -cloudWidth * 0.14)
        }
    }

    private func burst(index: Int, in size: CGSize) -> some View {
        let burstSize = size.shortSide * (0.10 + CGFloat(index % 3) * 0.025)
        let center = edgePoint(index: index + 12, in: size, topBias: 0.88)

        return ZStack {
            ForEach(0..<10, id: \.self) { ray in
                burstRay(index: index, ray: ray, burstSize: burstSize)
            }
            Circle()
                .fill(config.accentColors[index % config.accentColors.count].opacity(0.88))
                .frame(width: burstSize * 0.16, height: burstSize * 0.16)
        }
        .position(center)
    }

    private func burstRay(index: Int, ray: Int, burstSize: CGFloat) -> some View {
        let color = config.accentColors[(index + ray) % config.accentColors.count].opacity(0.78)
        let rayWidth = max(burstSize * 0.07, 3)
        let rayHeight = burstSize * 0.42
        let offset = -burstSize * 0.24
        let rotation = Double(ray) * 36

        return Capsule()
            .fill(color)
            .frame(width: rayWidth, height: rayHeight)
            .offset(y: offset)
            .rotationEffect(.degrees(rotation))
    }

    private func star(index: Int, in size: CGSize) -> some View {
        StarShape(points: index % 3 == 0 ? 8 : 5)
            .fill(config.accentColors[index % config.accentColors.count].opacity(index % 4 == 0 ? 0.76 : 0.48))
            .frame(width: starSize(index), height: starSize(index))
            .position(edgePoint(index: index + 30, in: size, topBias: 0.82))
    }

    private func lantern(index: Int, in size: CGSize) -> some View {
        let lanternWidth = size.shortSide * (0.060 + CGFloat(index % 3) * 0.010)
        let color = config.accentColors[index % config.accentColors.count]
        let x = size.width * (0.10 + CGFloat(index) / 6 * 0.80)
        let y = size.height * (index % 2 == 0 ? 0.12 : 0.21)

        return VStack(spacing: 0) {
            Rectangle()
                .fill(color.opacity(0.58))
                .frame(width: 2, height: size.shortSide * 0.08)
            RoundedRectangle(cornerRadius: lanternWidth * 0.28, style: .continuous)
                .fill(color.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: lanternWidth * 0.28, style: .continuous)
                        .stroke(config.accentColors[0].opacity(0.54), lineWidth: 2)
                )
                .frame(width: lanternWidth, height: lanternWidth * 1.18)
                .shadow(color: color.opacity(0.74), radius: 14)
        }
        .position(x: x, y: y)
    }

    private func candle(index: Int, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            FlameShape()
                .fill(config.accentColors[2].opacity(0.92))
                .frame(width: height * 0.24, height: height * 0.30)
                .shadow(color: config.accentColors[2].opacity(0.72), radius: 10)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(config.accentColors[index % 2].opacity(0.72))
                .frame(width: height * 0.22, height: height)
        }
    }

    private func snowflake(index: Int, in size: CGSize) -> some View {
        let flakeSize = size.shortSide * (0.030 + CGFloat(index % 4) * 0.008)
        return ZStack {
            ForEach(0..<3, id: \.self) { ray in
                Capsule()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.58))
                    .frame(width: max(flakeSize * 0.10, 2), height: flakeSize)
                    .rotationEffect(.degrees(Double(ray) * 60))
            }
        }
        .position(edgePoint(index: index + 9, in: size, topBias: 0.82))
    }

    private func frostMountain(index: Int, in size: CGSize) -> some View {
        let color = config.accentColors[index % config.accentColors.count].opacity(0.22 + Double(index) * 0.045)
        let width = size.width * (0.30 + CGFloat(index % 2) * 0.08)
        let height = size.height * (0.22 + CGFloat(index % 3) * 0.04)
        let x = size.width * (0.08 + CGFloat(index) * 0.22)

        return MountainShape()
            .fill(color)
            .frame(width: width, height: height)
            .position(x: x, y: size.height * 0.86)
    }

    private func grassBlade(index: Int, in size: CGSize) -> some View {
        let height = size.height * (0.10 + CGFloat(index % 5) * 0.014)
        return Capsule()
            .fill(config.accentColors[1].opacity(0.34))
            .frame(width: max(size.shortSide * 0.007, 4), height: height)
            .rotationEffect(.degrees(Double(index % 2 == 0 ? -13 : 15)))
            .position(x: size.width * sideX(index + 3), y: size.height * (0.84 + CGFloat(index % 4) * 0.035))
    }

    private func grainStalk(index: Int, in size: CGSize) -> some View {
        let height = size.height * (0.12 + CGFloat(index % 4) * 0.018)
        return ZStack {
            Capsule()
                .fill(config.accentColors[0].opacity(0.46))
                .frame(width: max(size.shortSide * 0.006, 3), height: height)
            ForEach(0..<3, id: \.self) { grain in
                grainKernel(grain: grain, height: height)
            }
        }
        .rotationEffect(.degrees(Double((index * 17) % 26) - 13))
        .position(x: size.width * (0.04 + CGFloat(index) / 25 * 0.92), y: size.height * (0.82 + CGFloat(index % 4) * 0.035))
    }

    private func grainKernel(grain: Int, height: CGFloat) -> some View {
        let color = config.accentColors[(grain + 1) % config.accentColors.count].opacity(0.62)
        let direction: CGFloat = grain % 2 == 0 ? -1 : 1
        let x = direction * height * 0.08
        let y = -height * (0.18 + CGFloat(grain) * 0.10)
        let rotation = Double(grain % 2 == 0 ? -32 : 32)

        return Capsule()
            .fill(color)
            .frame(width: height * 0.12, height: height * 0.035)
            .offset(x: x, y: y)
            .rotationEffect(.degrees(rotation))
    }

    private func beachUmbrella(index: Int, in size: CGSize) -> some View {
        let umbrellaSize = size.shortSide * (0.10 + CGFloat(index % 2) * 0.025)
        let x = size.width * (0.16 + CGFloat(index) * 0.30)
        let y = size.height * (index % 2 == 0 ? 0.82 : 0.90)
        return ZStack {
            Rectangle()
                .fill(config.accentColors[1].opacity(0.58))
                .frame(width: max(umbrellaSize * 0.05, 3), height: umbrellaSize * 0.72)
                .offset(y: umbrellaSize * 0.24)
            HalfCircleShape()
                .fill(config.accentColors[index % config.accentColors.count].opacity(0.80))
                .frame(width: umbrellaSize, height: umbrellaSize * 0.46)
        }
        .rotationEffect(.degrees(Double(index % 2 == 0 ? -7 : 8)))
        .position(x: x, y: y)
    }

    private func christmasTree(index: Int, in size: CGSize) -> some View {
        let treeSize = size.shortSide * (0.13 + CGFloat(index % 2) * 0.035)
        let x = size.width * (0.10 + CGFloat(index) * 0.25)
        let y = size.height * (index % 2 == 0 ? 0.82 : 0.90)
        return ZStack {
            Rectangle()
                .fill(Color(red: 0.35, green: 0.18, blue: 0.08).opacity(0.66))
                .frame(width: treeSize * 0.13, height: treeSize * 0.28)
                .offset(y: treeSize * 0.34)
            ForEach(0..<3, id: \.self) { layer in
                TriangleShape()
                    .fill(config.accentColors[2].opacity(0.70 + Double(layer) * 0.06))
                    .frame(width: treeSize * (1 - CGFloat(layer) * 0.18), height: treeSize * 0.52)
                    .offset(y: -treeSize * CGFloat(layer) * 0.18)
            }
        }
        .position(x: x, y: y)
    }

    private func bottomDrift(size: CGSize, color: Color, height: CGFloat, yOffset: CGFloat) -> some View {
        WaveShape(phase: 0.18)
            .fill(color)
            .frame(width: size.width * 1.12, height: size.height * height)
            .position(x: size.width * 0.5, y: size.height * (1 - height / 2 + yOffset))
    }

    private func summerWave(index: Int, in size: CGSize) -> some View {
        let color = config.accentColors[(index + 1) % config.accentColors.count].opacity(0.24)
        let height = size.height * (0.12 + CGFloat(index) * 0.015)
        let y = size.height * (0.76 + CGFloat(index) * 0.055)

        return WaveShape(phase: CGFloat(index) * 0.32)
            .fill(color)
            .frame(width: size.width * 1.14, height: height)
            .position(x: size.width * 0.5, y: y)
    }

    private func decorativeOrb(size: CGSize, color: Color, x: CGFloat, y: CGFloat, diameter: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size.shortSide * diameter, height: size.shortSide * diameter)
            .position(x: size.width * x, y: size.height * y)
            .blur(radius: size.shortSide * 0.018)
    }

    private func edgePoint(index: Int, in size: CGSize, topBias: CGFloat) -> CGPoint {
        let xSeed = CGFloat((index * 37) % 100) / 100
        let ySeed = CGFloat((index * 53) % 100) / 100
        let x = index % 5 == 0 ? CGFloat(index % 2 == 0 ? 0.06 : 0.94) : xSeed
        let y = ySeed < topBias ? ySeed * 0.34 : 0.68 + ySeed * 0.30
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private func bottomSidePoint(index: Int, in size: CGSize) -> CGPoint {
        let sideOffset = CGFloat((index * 29) % 100) / 100
        let x = index % 4 == 0 ? 0.07 + sideOffset * 0.08 : index % 4 == 1 ? 0.85 + sideOffset * 0.10 : 0.12 + sideOffset * 0.76
        let y = 0.76 + CGFloat((index * 41) % 100) / 100 * 0.20
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private func autumnPoint(index: Int, in size: CGSize) -> CGPoint {
        let xSeed = CGFloat((index * 43) % 100) / 100
        let ySeed = CGFloat((index * 61) % 100) / 100
        let x = index % 3 == 0 ? 0.05 + xSeed * 0.12 : index % 3 == 1 ? 0.82 + xSeed * 0.12 : xSeed
        let y = index % 4 == 0 ? 0.10 + ySeed * 0.12 : 0.70 + ySeed * 0.26
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private func sideX(_ index: Int) -> CGFloat {
        index % 2 == 0 ? 0.07 + CGFloat((index * 17) % 10) / 180 : 0.90 + CGFloat((index * 19) % 10) / 180
    }

    private func snowSize(_ index: Int) -> CGFloat {
        CGFloat(6 + (index * 7) % 14)
    }

    private func flowerSize(_ index: Int) -> CGFloat {
        CGFloat(30 + (index * 11) % 34)
    }

    private func leafSize(_ index: Int) -> CGFloat {
        CGFloat(28 + (index * 13) % 36)
    }

    private func lightSize(_ index: Int) -> CGFloat {
        CGFloat(12 + (index * 5) % 14)
    }

    private func confettiWidth(_ index: Int) -> CGFloat {
        CGFloat(7 + (index * 7) % 12)
    }

    private func confettiHeight(_ index: Int) -> CGFloat {
        CGFloat(18 + (index * 11) % 24)
    }

    private func eggSize(_ index: Int) -> CGFloat {
        CGFloat(54 + (index * 13) % 34)
    }

    private func starSize(_ index: Int) -> CGFloat {
        CGFloat(12 + (index * 7) % 18)
    }

    private func colorCloudSize(_ index: Int) -> CGFloat {
        CGFloat(70 + (index * 29) % 110)
    }

    private func batWidth(_ index: Int) -> CGFloat {
        CGFloat(32 + (index * 11) % 38)
    }
}

struct SeasonalBackgroundConfig {
    enum Kind {
        case winter
        case spring
        case summer
        case autumn
        case rain
        case festive
        case frost
        case meadow
        case beach
        case harvest
        case fireworks
        case confetti
        case easter
        case crescent
        case lanterns
        case candles
        case colorClouds
        case diyas
        case midsummer
        case halloween
        case christmasTrees
    }

    let kind: Kind
    let baseColors: [Color]
    let accentColors: [Color]
    let centerDimming: Double

    static func occasion(kind: Kind, baseColors: [Color], accentColors: [Color]) -> SeasonalBackgroundConfig {
        SeasonalBackgroundConfig(
            kind: kind,
            baseColors: baseColors,
            accentColors: accentColors,
            centerDimming: 0.30
        )
    }

    static func config(for month: Int) -> SeasonalBackgroundConfig {
        switch month {
        case 1:
            return SeasonalBackgroundConfig(
                kind: .frost,
                baseColors: [Color(red: 0.02, green: 0.08, blue: 0.17), Color(red: 0.08, green: 0.20, blue: 0.32), Color(red: 0.62, green: 0.78, blue: 0.88)],
                accentColors: [Color(red: 0.72, green: 0.92, blue: 1.00), Color(red: 0.92, green: 0.98, blue: 1.00), Color(red: 0.42, green: 0.66, blue: 0.90)],
                centerDimming: 0.24
            )
        case 2:
            return SeasonalBackgroundConfig(
                kind: .winter,
                baseColors: [Color(red: 0.18, green: 0.06, blue: 0.18), Color(red: 0.34, green: 0.12, blue: 0.28), Color(red: 0.76, green: 0.42, blue: 0.62)],
                accentColors: [Color(red: 1.00, green: 0.66, blue: 0.82), Color(red: 0.96, green: 0.88, blue: 0.96), Color(red: 0.66, green: 0.36, blue: 0.72)],
                centerDimming: 0.24
            )
        case 3:
            return SeasonalBackgroundConfig(
                kind: .rain,
                baseColors: [Color(red: 0.08, green: 0.16, blue: 0.20), Color(red: 0.15, green: 0.28, blue: 0.29), Color(red: 0.38, green: 0.56, blue: 0.44)],
                accentColors: [Color(red: 0.61, green: 0.82, blue: 0.74), Color(red: 0.55, green: 0.72, blue: 0.90), Color(red: 0.76, green: 0.88, blue: 0.65)],
                centerDimming: 0.24
            )
        case 4:
            return SeasonalBackgroundConfig(
                kind: .spring,
                baseColors: [Color(red: 0.08, green: 0.18, blue: 0.24), Color(red: 0.16, green: 0.32, blue: 0.34), Color(red: 0.58, green: 0.52, blue: 0.78)],
                accentColors: [Color(red: 0.98, green: 0.82, blue: 0.40), Color(red: 0.52, green: 0.82, blue: 0.74), Color(red: 0.86, green: 0.54, blue: 0.82), Color(red: 0.64, green: 0.70, blue: 1.00)],
                centerDimming: 0.25
            )
        case 5:
            return SeasonalBackgroundConfig(
                kind: .meadow,
                baseColors: [Color(red: 0.04, green: 0.22, blue: 0.14), Color(red: 0.12, green: 0.44, blue: 0.24), Color(red: 0.82, green: 0.68, blue: 0.30)],
                accentColors: [Color(red: 1.00, green: 0.78, blue: 0.24), Color(red: 0.42, green: 0.78, blue: 0.26), Color(red: 0.96, green: 0.36, blue: 0.52), Color(red: 1.00, green: 0.88, blue: 0.92)],
                centerDimming: 0.25
            )
        case 6:
            return SeasonalBackgroundConfig(
                kind: .midsummer,
                baseColors: [Color(red: 0.04, green: 0.22, blue: 0.24), Color(red: 0.14, green: 0.40, blue: 0.32), Color(red: 0.92, green: 0.66, blue: 0.34)],
                accentColors: [Color(red: 1.00, green: 0.84, blue: 0.28), Color(red: 0.48, green: 0.82, blue: 0.34), Color(red: 0.96, green: 0.54, blue: 0.72)],
                centerDimming: 0.26
            )
        case 7:
            return SeasonalBackgroundConfig(
                kind: .summer,
                baseColors: [Color(red: 0.02, green: 0.20, blue: 0.36), Color(red: 0.04, green: 0.46, blue: 0.62), Color(red: 0.96, green: 0.66, blue: 0.34)],
                accentColors: [Color(red: 1.00, green: 0.84, blue: 0.28), Color(red: 0.20, green: 0.70, blue: 0.92), Color(red: 0.48, green: 0.88, blue: 0.88), Color(red: 0.94, green: 0.76, blue: 0.48)],
                centerDimming: 0.27
            )
        case 8:
            return SeasonalBackgroundConfig(
                kind: .beach,
                baseColors: [Color(red: 0.02, green: 0.28, blue: 0.46), Color(red: 0.04, green: 0.58, blue: 0.72), Color(red: 0.98, green: 0.72, blue: 0.40)],
                accentColors: [Color(red: 1.00, green: 0.86, blue: 0.30), Color(red: 0.10, green: 0.62, blue: 0.82), Color(red: 0.52, green: 0.90, blue: 0.92), Color(red: 0.96, green: 0.78, blue: 0.48)],
                centerDimming: 0.28
            )
        case 9:
            return SeasonalBackgroundConfig(
                kind: .harvest,
                baseColors: [Color(red: 0.10, green: 0.18, blue: 0.14), Color(red: 0.30, green: 0.34, blue: 0.18), Color(red: 0.88, green: 0.62, blue: 0.26)],
                accentColors: [Color(red: 0.98, green: 0.74, blue: 0.24), Color(red: 0.66, green: 0.54, blue: 0.22), Color(red: 0.44, green: 0.58, blue: 0.24), Color(red: 0.86, green: 0.50, blue: 0.18)],
                centerDimming: 0.27
            )
        case 10:
            return SeasonalBackgroundConfig(
                kind: .autumn,
                baseColors: [Color(red: 0.12, green: 0.08, blue: 0.10), Color(red: 0.32, green: 0.16, blue: 0.14), Color(red: 0.82, green: 0.38, blue: 0.14)],
                accentColors: [Color(red: 0.94, green: 0.46, blue: 0.12), Color(red: 0.72, green: 0.20, blue: 0.12), Color(red: 0.96, green: 0.68, blue: 0.20), Color(red: 0.46, green: 0.22, blue: 0.12)],
                centerDimming: 0.28
            )
        case 11:
            return SeasonalBackgroundConfig(
                kind: .rain,
                baseColors: [Color(red: 0.06, green: 0.08, blue: 0.11), Color(red: 0.18, green: 0.20, blue: 0.24), Color(red: 0.42, green: 0.36, blue: 0.30)],
                accentColors: [Color(red: 0.52, green: 0.62, blue: 0.68), Color(red: 0.74, green: 0.62, blue: 0.46), Color(red: 0.34, green: 0.42, blue: 0.48)],
                centerDimming: 0.30
            )
        default:
            return SeasonalBackgroundConfig(
                kind: .festive,
                baseColors: [Color(red: 0.04, green: 0.10, blue: 0.13), Color(red: 0.08, green: 0.22, blue: 0.18), Color(red: 0.42, green: 0.10, blue: 0.12)],
                accentColors: [Color(red: 0.96, green: 0.82, blue: 0.36), Color(red: 0.88, green: 0.20, blue: 0.18), Color(red: 0.24, green: 0.66, blue: 0.46), Color(red: 0.86, green: 0.94, blue: 1.00)],
                centerDimming: 0.28
            )
        }
    }
}

private struct WaveShape: Shape {
    let phase: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))

        let step = max(rect.width / 5, 1)
        for index in 0...5 {
            let x = rect.minX + CGFloat(index) * step
            let y = rect.midY + sin(CGFloat(index) * .pi * 0.82 + phase * .pi * 2) * rect.height * 0.18
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.78)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.78),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.22)
        )
        return path
    }
}

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.48, y: rect.minY + rect.height * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct HalfCircleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct EggShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.06),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.30)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.82),
            control2: CGPoint(x: rect.midX + rect.width * 0.25, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY),
            control1: CGPoint(x: rect.midX - rect.width * 0.25, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.82)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.30),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.06)
        )
        return path
    }
}

private struct CrescentShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        path.addEllipse(in: rect.offsetBy(dx: rect.width * 0.28, dy: -rect.height * 0.06).insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04))
        return path
    }
}

private struct StarShape: Shape {
    let points: Int

    func path(in rect: CGRect) -> Path {
        let pointCount = max(points, 4)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.42
        var path = Path()

        for index in 0..<(pointCount * 2) {
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = CGFloat(index) * .pi / CGFloat(pointCount) - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

private struct FlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.38),
            control2: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.38)
        )
        return path
    }
}

private struct DiyaShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

private extension CGSize {
    var shortSide: CGFloat {
        min(width, height)
    }
}
