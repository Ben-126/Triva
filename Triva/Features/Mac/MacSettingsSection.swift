//
//  MacSettingsSection.swift
//  Triva
//
//  Chantier 2.2 (M7) : section des Réglages propre au Mac.
//

#if os(macOS)
import SwiftUI

/// Section « Mac » des Réglages : l'icône de la barre des menus, à la demande de l'utilisateur.
struct MacSettingsSection: View {
    @AppStorage(MenuBarItemPreference.defaultsKey) private var showsMenuBarItem = MenuBarItemPreference.defaultValue

    var body: some View {
        Section("Mac") {
            Toggle("Afficher Triva dans la barre des menus", isOn: $showsMenuBarItem)
                .accessibilityIdentifier("settings.menuBarItem")
        }
    }
}
#endif
