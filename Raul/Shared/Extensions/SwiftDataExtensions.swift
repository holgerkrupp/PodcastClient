//
//  SwiftDataExtensions.swift
//  Raul
//
//  Created by Holger Krupp on 30.04.25.
//

import Foundation
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

    /// Returns the model for `id` only while its row still exists in the store.
    ///
    /// `model(for:)` hands back an object for any well-formed identifier, even
    /// when the row has since been removed by a cascade delete, a duplicate
    /// cleanup or a CloudKit import. Reading or writing a property on such an
    /// object traps inside SwiftData, so every re-acquisition that spans an
    /// `await` goes through this instead.
    func existingModel<T: PersistentModel>(for id: PersistentIdentifier) -> T? {
        var descriptor = FetchDescriptor<T>(
            predicate: #Predicate { $0.persistentModelID == id }
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    /// The batch form of `existingModel(for:)`, keyed by identifier.
    ///
    /// Identifiers that no longer have a row are simply absent from the result.
    /// Resolving a page of cached identifiers this way costs one query instead
    /// of one per identifier.
    func existingModels<T: PersistentModel>(
        for ids: [PersistentIdentifier]
    ) -> [PersistentIdentifier: T] {
        let uniqueIDs = Array(Set(ids))
        guard uniqueIDs.isEmpty == false else { return [:] }

        let descriptor = FetchDescriptor<T>(
            predicate: #Predicate { uniqueIDs.contains($0.persistentModelID) }
        )
        let models = (try? fetch(descriptor)) ?? []

        return models.reduce(into: [:]) { result, model in
            result[model.persistentModelID] = model
        }
    }
}
