//
//  AppTips.swift
//  Up Next
//
//  Tips follow the HIG "Offering help" guidance: only for features that are
//  hard to discover, one or two actionable sentences, a filled symbol that
//  differs from the control's own icon, and invalidated as soon as the person
//  performs the action the tip describes.
//

import SwiftUI
import TipKit

/// Touch and hold on Play Next / Play Last opens a playlist picker; nothing on
/// screen hints at it, and it only matters once there is more than one playlist.
struct ChoosePlaylistTip: Tip {
    @Parameter
    static var manualPlaylistCount: Int = 0

    var title: Text {
        Text("Add to Another Playlist")
    }

    var message: Text? {
        Text("Touch and hold Play Next or Play Last to choose which playlist gets the episode.")
    }

    var image: Image? {
        Image(systemName: "list.bullet.rectangle.fill")
    }

    var rules: [Rule] {
        [
            #Rule(Self.$manualPlaylistCount) { $0 > 1 }
        ]
    }

    var options: [TipOption] {
        [
            MaxDisplayCount(3)
        ]
    }
}

/// The furthest-position button is icon-only and only appears after seeking
/// backwards, so its purpose isn't obvious the first time it shows up.
struct FurthestPositionTip: Tip {
    var title: Text {
        Text("Return to Where You Were")
    }

    var message: Text? {
        Text("Tap to jump ahead to the furthest point you've listened to in this episode.")
    }

    var image: Image? {
        Image(systemName: "arrow.uturn.forward.circle.fill")
    }

    var options: [TipOption] {
        [
            MaxDisplayCount(2)
        ]
    }
}

/// The clip waveform pans and pinch-zooms, which the static waveform doesn't suggest.
struct ClipWaveformGesturesTip: Tip {
    var title: Text {
        Text("Find the Exact Moment")
    }

    var message: Text? {
        Text("Drag the waveform to move through the episode, and pinch to zoom in for a precise cut.")
    }

    var image: Image? {
        Image(systemName: "hand.pinch.fill")
    }

    var options: [TipOption] {
        [
            // Only visible while someone is actively making a clip, so it
            // shouldn't wait behind the app-wide weekly tip frequency.
            Tips.IgnoresDisplayFrequency(true),
            MaxDisplayCount(3)
        ]
    }
}
