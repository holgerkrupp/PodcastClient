//
//  SleepTimerView.swift
//  Raul
//
//  Created by Holger Krupp on 16.09.25.
//

import SwiftUI


struct SleepTimerView: View {
    @Bindable private var player = Player.shared
    @State private var customMinutes = 30

    private let durationPresets = [15, 30, 45, 60, 90, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let remaining = player.remainingTime {
                Label {
                    Text("Active: \(Duration.seconds(remaining).formatted(.units(width: .wide))) left")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(.tint)
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityElement(children: .combine)
            }

            Text("Quick durations")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                spacing: 8
            ) {
                ForEach(durationPresets, id: \.self) { minutes in
                    Button {
                        player.setSleepTimer(minutes: minutes)
                    } label: {
                        Text(Duration.seconds(Double(minutes) * 60).formatted(.units(width: .narrow)))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Set sleep timer for \(minutes) minutes")
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Stepper(value: $customMinutes, in: 1...240) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom duration")
                        Text("\(customMinutes) minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Start") {
                    player.setSleepTimer(minutes: customMinutes)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("Up to four hours. Overnight mode is not available because background timers cannot guarantee an exact stop time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if let remaining = player.remainingTime {
                customMinutes = min(max(Int(ceil(remaining / 60)), 1), 240)
            }
        }
    }
}
