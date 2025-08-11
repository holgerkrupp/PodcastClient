//
//  SettingsView.swift
//  Raul
//
//  Created by Holger Krupp on 20.05.25.
//

import SwiftUI
import Foundation

struct SettingsView: View {
    
    

    
    var body: some View {
        VStack{
            NotificationSettingsView()
                
            Button("Delete all files in Documents Directory") {
                deleteAllFiles(in: .documentDirectory)
            }
            Button("Delete all files in Cahes Directory") {
                deleteAllFiles(in: .cachesDirectory)
            }
            
        //    PodcastSettingsView()
        }
    }
    
    

    func deleteAllFiles(in folder: FileManager.SearchPathDirectory, excluding excludedFileName: String = "log.txt") {
        let fileManager = FileManager.default

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Could not locate the Documents directory.")
            return
        }

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)

            for fileURL in fileURLs {
                if fileURL.lastPathComponent == excludedFileName {
                    continue // Skip the excluded file
                }

                do {
                    try fileManager.removeItem(at: fileURL)
                    print("Deleted file: \(fileURL.lastPathComponent)")
                } catch {
                    print("Failed to delete file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            print("Error accessing contents of Documents folder: \(error.localizedDescription)")
        }
    }

}

#Preview {
    SettingsView()
}
