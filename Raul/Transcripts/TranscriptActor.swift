//
//  TranscriptActor.swift
//  Raul
//
//  Created by Holger Krupp on 03.07.25.
//

import Foundation


actor TranscriptActor {
    
    func createLinesFromString(_ input: String) {
        let lines = TranscriptDecoder(input).transcriptLines
    }
    
    
    
}
