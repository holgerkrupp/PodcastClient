//
//  SkipNextView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 14.01.24.
//

import SwiftUI

struct SkipNextView: View {
    let progress: Double
    var foregroundColor:Color = Color.pink
    
    var body: some View {
        ZStack {
            Rectangle()
                .stroke(
                    Color.pink.opacity(0.5),
                    lineWidth: 5
                )
            Rectangle()
            // 2
                .trim(from: 0, to: progress)
                .stroke(
                    foregroundColor,
                    style: StrokeStyle(
                        lineWidth: 5,
                        lineCap: .round
                    )
                )
            //   .rotationEffect(.degrees(-90))
            Image(systemName: "chevron.right")
                .resizable()
                .scaledToFit()
                .padding(5)
                .foregroundColor(foregroundColor)
        }
        .aspectRatio(1.0, contentMode: .fit)
    
    }
}

#Preview {
    SkipNextView(progress: 0.4)
}


struct SkipBackView: View {

    var foregroundColor:Color = Color.pink
    
    var body: some View {
        ZStack {
            Rectangle()
                .stroke(
                    Color.pink.opacity(0.5),
                    lineWidth: 5
                )


            Image(systemName: "chevron.left")
                .resizable()
                .scaledToFit()
                .padding(5)
                .foregroundColor(foregroundColor)
        }
        .aspectRatio(1.0, contentMode: .fit)
        
    }
}

#Preview {
    SkipBackView()
}
