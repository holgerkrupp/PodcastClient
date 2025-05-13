//
//  CodableArray.swift
//  Raul
//
//  Created by Holger Krupp on 10.05.25.
//


struct CodableArray<T: Codable & Equatable>: Codable, Equatable {
    var elements: [T]

    init(_ elements: [T]) {
        self.elements = elements
    }
}