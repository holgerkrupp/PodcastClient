//
//  SleepTimerView.swift
//  Raul
//
//  Created by Holger Krupp on 16.09.25.
//

import SwiftUI


struct SleepTimerView: View {
    let player = Player.shared
    
    var body: some View {
        
        Stepper(
            value: Binding(
                get: {
                    guard let remaining = player.remainingTime else { return 0 }
                    return Int(ceil(remaining / 300)) // steps of 5 min
                },
                set: { newValue in
                    if newValue > 0 {
                        player.setSleepTimer(minutes: newValue * 5)
                    } else {
                        player.cancelSleepTimer()
                    }
                }
            ),
            in: 0...48,
            step: 1
        ) {
            if let remaining = player.remainingTime {
                Text(Duration.seconds(remaining).formatted(.units(width: .narrow)))
            } else {
                Text("Off")
            }
        }
       
    }
}
