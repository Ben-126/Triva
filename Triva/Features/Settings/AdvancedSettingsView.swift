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
/// Elle porte la liste d'instances SearXNG et l'interrupteur du filtre adulte, dont la valeur dit d'un
/// coup d'œil si elle a été modifiée. Composants système (`Form`), comme les autres Réglages.
///
/// Poussée dans la pile des Réglages : pas de `NavigationStack` ici (une pile imbriquée dans une
/// autre donne une double barre et des liens cassés). Sur Mac comme sur iPad, c'est la même pile
/// que `SearchKeysView`.
struct AdvancedSettingsView: View {
    let instanceStore: CustomInstanceStore

    /// Filtre adulte des recherches (décision Q5, révisée le 2026-11-14) : activé par défaut.
    @AppStorage(SafeSearchPolicy.defaultsKey) private var safeSearchEnabled = SafeSearchPolicy.enabledByDefault

    /// Mise à jour automatique de la liste d'instances (mission C3, M13) : activée par défaut.
    @AppStorage(InstanceAutoUpdatePolicy.defaultsKey) private var autoUpdateInstances = InstanceAutoUpdatePolicy.enabledByDefault

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
                Toggle(InstanceAutoUpdateText.toggle, isOn: $autoUpdateInstances)
                    .accessibilityIdentifier("settings.autoUpdateInstances")
            } footer: {
                // Validé par Ben le 2026-11-18 (texte légal)
                Text(InstanceAutoUpdateText.footer)
            }

            Section {
                Toggle("Filtrer les contenus pour adultes", isOn: $safeSearchEnabled)
                    .accessibilityIdentifier("settings.safeSearch")
            } footer: {
                // Validé par Ben le 2026-11-18 (texte légal)
                Text("Masque les résultats et images pour adultes dans les recherches.")
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
