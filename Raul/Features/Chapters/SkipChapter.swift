//
//  SkipChapter.swift
//  Up Next
//
//  Created by Holger Krupp on 19.05.26.
//
import SwiftUI

struct SkipChapter: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
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
                        .animation(reduceMotion ? nil : .linear, value: configuration.isOn)
                    
                ).cornerRadius(20)
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Play chapter")
                .accessibilityValue(configuration.isOn ? "On" : "Off")
                .accessibilityHint("Turn off to skip this chapter")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    configuration.isOn.toggle()
                }
        }
    }
    
}
