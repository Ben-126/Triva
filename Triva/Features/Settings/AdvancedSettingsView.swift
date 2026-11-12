//
//  AdvancedSettingsView.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

/// Page « Avancé » des Réglages (Réglages > Recherche > Avancé), poussée par une ligne à chevron
/// standard, comme Général > Informations dans les Réglages d'Apple (décision de Ben,
/// 2026-11-12). Avant, c'était un groupe repliable (`DisclosureGroup`) : un clic de plus pour
/// l'ouvrir, et une ligne de réglage glissée dans la section « Recherche ».
///
/// Elle porte aujourd'hui une seule ligne, la liste d'instances SearXNG, dont la valeur dit d'un
/// coup d'œil si elle a été modifiée. Composants système (`Form`), comme les autres Réglages.
///
/// Poussée dans la pile des Réglages : pas de `NavigationStack` ici (une pile imbriquée dans une
/// autre donne une double barre et des liens cassés). Sur Mac comme sur iPad, c'est la même pile
/// que `SearchKeysView`.
struct AdvancedSettingsView: View {
    let instanceStore: CustomInstanceStore

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsRoute.searxngInstances) {
                    LabeledContent(
                        "Instances SearXNG",
                        value: instanceStore.isCustomized ? "Personnalisées" : "Par défaut"
                    )
                }
                .accessibilityIdentifier("settings.searxngInstances")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Avancé")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview("Avancé") {
    NavigationStack {
        AdvancedSettingsView(instanceStore: CustomInstanceStore())
    }
}
