//
//  LinkRouting.swift
//  Triva
//
//  Mission C3 (navigateur intégré, demande de Ben).
//

import Foundation

/// Où va un lien. Logique pure, testable sans interface.
nonisolated enum LinkRouting {
    enum Route: Equatable, Sendable {
        /// Navigateur intégré de l'app.
        case inApp
        /// Le système décide (`mailto:`, `tel:`, schémas d'autres apps…) : reste externe.
        case system
    }

    /// Seules les pages web (`http`, `https`, avec un hôte) s'ouvrent dans l'app : le navigateur
    /// intégré refuse tout autre schéma, et un `mailto:` doit ouvrir l'app Mail.
    static func route(for url: URL) -> Route {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return .system }
        return .inApp
    }
}
