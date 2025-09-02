//
//  VideoSizePicker.swift
//  Raul
//
//  Created by Holger Krupp on 02.09.25.
//


import SwiftUI

struct VideoSizePicker: View {
    @Binding var videoSize: CGSize
    
    enum VideoSizeOption: String, CaseIterable, Identifiable {
        case square = "Square"
        case portrait = "Portrait"
        case widescreen = "Widescreen"
        
        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .square: return CGSize(width: 720, height: 720)
            case .portrait: return CGSize(width: 720, height: 1280)
            case .widescreen: return CGSize(width: 1280, height: 720)
            }
        }
        var symbolName: String {
            switch self {
            case .square: return "square"
            case .portrait: return "rectangle.portrait"
            case .widescreen: return "rectangle"
            }
        }
    }
    
    @State private var selectedOption: VideoSizeOption = .square
    
    var body: some View {
        Picker("Video Size", selection: $selectedOption) {
            ForEach(VideoSizeOption.allCases) { option in
               
                    Label(option.rawValue, systemImage: option.symbolName)
                        .labelStyle(.iconOnly)
                    
                .tag(option)
               
                
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .onChange(of: selectedOption) {
            videoSize = selectedOption.size
        }
    }
}

#Preview {
    @Previewable @State var videoSize = CGSize(width: 720, height: 720)
        VideoSizePicker(videoSize: $videoSize)
    }

