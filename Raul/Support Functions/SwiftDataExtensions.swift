//
//  SwiftDataExtensions.swift
//  Raul
//
//  Created by Holger Krupp on 30.04.25.
//

import SwiftData

extension ModelContext{
    func saveIfNeeded(){
        if self.hasChanges{
                do {
                    try self.save()
                }catch{
                  print(error.localizedDescription)
                }
            }
    }
}
