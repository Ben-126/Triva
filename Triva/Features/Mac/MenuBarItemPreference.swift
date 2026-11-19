//
//  MenuBarItemPreference.swift
//  Triva
//
//  Chantier 2.2 (M7) : réglage « Afficher Triva dans la barre des menus ».
//

import Foundation

/// Clé et valeur par défaut du réglage. Désactivé par défaut : l'icône n'apparaît dans la barre des menus que si
/// l'utilisateur le demande (HIG : la barre des menus est à lui).
nonisolated enum MenuBarItemPreference {
    static let defaultsKey = "menuBarItemEnabled"
    static let defaultValue = false

    static func isEnabled(in userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: defaultsKey) as? Bool ?? defaultValue
    }
}
