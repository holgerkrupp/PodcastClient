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
         /*   Rectangle()
                .stroke(
                    Color.secondary,
                    lineWidth: 3
                )
          */
          Rectangle()
            // 2
                .trim(from: 0, to: progress)
                .stroke(
                    style: StrokeStyle(
                        lineWidth: 3,
                        lineCap: .round
                    )
                )
            //   .rotationEffect(.degrees(-90))
            Image(systemName: "chevron.right")
                .resizable()
                .scaledToFit()
                .padding(3)
        }
        .aspectRatio(1.0, contentMode: .fit)
    
    }
}

#Preview {
    SkipNextView(progress: 0.4)
}


struct SkipBackView: View {

    
    var body: some View {
       
        ZStack {
            /*            Rectangle()
                .stroke(
                    Color.secondary,
                    lineWidth: 3
                )
*/

            Image(systemName: "chevron.left")
                .resizable()
                .scaledToFit()
                .padding(3)
        }
        .aspectRatio(1.0, contentMode: .fit)
        
    }
}

#Preview {
    SkipBackView()
}



struct SkipChapter: ToggleStyle {
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Rectangle()
                .foregroundColor(configuration.isOn ? .accent : .secondary)
                .frame(width: 51, height: 31, alignment: .center)
                .overlay(
                    Circle()
                        .foregroundColor(.white)
                        .padding(.all, 3)
                        .overlay(
                            Image(systemName: configuration.isOn ? "play.fill" : "play.slash.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .font(Font.title.weight(.black))
                                .frame(width: 10, height: 10, alignment: .center)
                                .foregroundColor(configuration.isOn ? .accent  : .accent)
                        )
                        .offset(x: configuration.isOn ? 11 : -11, y: 0)
                        .animation(.linear, value: 0.2)
                    
                ).cornerRadius(20)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
    
}
