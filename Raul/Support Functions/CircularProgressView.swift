//
//  CircularProgressView.swift
//  Raul
//
//  Created by Holger Krupp on 22.08.25.
//
import SwiftUI

struct CircularProgressView: View {
    var value: Double    // current progress
    var total: Double    // total progress

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1) // clamp between 0 and 1
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 3)
              

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accent, lineWidth: 3)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: progress)
        }

    }
}
