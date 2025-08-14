//
//  LogoView.swift
//  Raul
//
//  Created by Holger Krupp on 03.06.25.
//


import SwiftUI

struct LogoView: View {
    var body: some View {
        HStack(spacing: 16) {
            // App icon with rocket and bar chart
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.2))
                    .background(.ultraThinMaterial)
                    .frame(width: 80, height: 80)
                    .shadow(color: .white.opacity(0.6), radius: 2, x: -2, y: -2)
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 2, y: 2)

                VStack(spacing: 4) {
                    Image(systemName: "rocket.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundColor(.white.opacity(0.8))
                        .shadow(color: .white.opacity(0.6), radius: 1, x: -1, y: -1)
                        .shadow(color: .black.opacity(0.1), radius: 1, x: 1, y: 1)

                    HStack(alignment: .bottom, spacing: 4) {
                        Capsule()
                            .frame(width: 6, height: 10)
                        Capsule()
                            .frame(width: 6, height: 16)
                        Capsule()
                            .frame(width: 6, height: 24)
                    }
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(color: .white.opacity(0.6), radius: 1, x: -1, y: -1)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 1, y: 1)
                }
            }

            // Text stack
            VStack(alignment: .leading, spacing: 2) {
                Text("extremely")
                Text("successful")
                Text("apps")
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white.opacity(0.85))
            .shadow(color: .white.opacity(0.6), radius: 1, x: -1, y: -1)
            .shadow(color: .black.opacity(0.1), radius: 1, x: 1, y: 1)
        }
        .padding()
        .background(Color.green.opacity(0.05)) // Optional: soft background
    }
}

#Preview {
    LogoView()
}
