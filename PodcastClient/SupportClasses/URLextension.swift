//
//  URLextension.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.01.24.
//

import Foundation

struct URLstatus{
    var statusCode: Int?
    var newURL: URL?
    var lastModified:Date?
    var lastRequest:Date
}


extension URL{
    func status() async throws -> URLstatus?{
        
        
                    let session = URLSession.shared
                    var request = URLRequest(url: self)
                    request.httpMethod = "HEAD"
                    if let appName = Bundle.main.applicationName{
                        request.setValue(appName, forHTTPHeaderField: "User-Agent")
                    }
                    do{
                        let (_, response) = try await session.data(for: request)
                     
                        var status = URLstatus(lastRequest: Date())
                        status.statusCode = (response as? HTTPURLResponse)?.statusCode
                        status.lastModified =  Date.dateFromRFC1123(dateString: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified") ?? "")
                        status.newURL = URL(string: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? "")
                        print("LM: \(status.lastModified?.formatted()) - \((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified"))")
                       
                    }catch{
                        print(error)
                        return nil
                    }

            
            return nil
        }
    
}
