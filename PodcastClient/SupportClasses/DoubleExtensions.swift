//
//  DoubleExtensions.swift
//  PodcastClient
//
//  Created by Holger Krupp on 08.01.24.
//

import Foundation

extension Double{
    var secondsToHoursMinutesSeconds : String? {
        
            let (hr,  minf) = modf (self / 3600)
            let (min, secf) = modf (60 * minf)
            let rh = hr
            let rm = min
            let rs = 60 * secf
            
            var returnstring = String()
            if rh != 0 {
                returnstring = NSString(format: "%02.0f:%02.0f:%02.0f", rh,rm,rs) as String
            }else {
                returnstring = NSString(format: "%02.0f:%02.0f", rm,rs) as String
            }
            return returnstring
        
    }
}

