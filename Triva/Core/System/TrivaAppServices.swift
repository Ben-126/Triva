//
//  TrivaAppServices.swift
//  Triva
//
//  Chantier 2.1 (mission A) : ce que les intents lisent par `@Dependency` (enregistré dans `TrivaApp.init` par
//  `AppDependencyManager.shared.add(dependency:)`). Les stores sont ceux de l'app, jamais recréés.
//

import Foundation

@MainActor
final class TrivaAppServices {
    let stores: TrivaSharedStores
    let routes: SystemRouteCenter

    init(stores: TrivaSharedStores, routes: SystemRouteCenter = .shared) {
        self.stores = stores
        self.routes = routes
    }
}
