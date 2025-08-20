//
//  SwiftDataExtensions.swift
//  Raul
//
//  Created by Holger Krupp on 30.04.25.
//

import SwiftData


extension ModelContext{
    func saveIfNeeded(){
        // print("save if needed - \(self.hasChanges)")
        if self.hasChanges{
                do {
                    try self.save()
                }catch{
                  // print(error.localizedDescription)
                }
            }
    }
}
