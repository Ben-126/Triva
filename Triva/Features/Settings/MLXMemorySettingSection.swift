//
//  MLXMemorySettingSection.swift
//  Triva
//
//  Mission K1 (2026-11-24).
//

import SwiftUI

/// Réglage « Autoriser plusieurs modèles en mémoire » de l'écran « Modèles MLX ».
///
/// Éteint (par défaut), Triva ne garde qu'UN modèle MLX en mémoire à la fois, essai compris : essayer un autre
/// modèle libère celui qui répond d'habitude, rechargé à la question suivante (voir `MLXProviderPool`). Allumé,
/// l'essai garde l'autre modèle en mémoire en plus. Composants système seulement, dans le `Form` de l'écran
/// (DESIGN.md : pas de verre dans un `Form`).
struct MLXMemorySettingSection: View {
    @Bindable var store: MLXModelSelectionStore

    /// Textes exposés pour les tests. À valider par Ben.
    static let title = "Autoriser plusieurs modèles en mémoire"
    static let footer =
        "Éteint, Triva ne garde qu'un modèle en mémoire à la fois : en essayer un autre libère celui qui répond "
        + "d'habitude, rechargé à ta question suivante. Allumé, les deux restent en mémoire pendant l'essai, "
        + "ce qui peut ralentir ton appareil si la mémoire est juste."

    var body: some View {
        Section {
            Toggle(Self.title, isOn: $store.allowsMultipleModels)
                .accessibilityIdentifier("settings.mlxMultipleModels")
        } footer: {
            Text(Self.footer)
        }
    }
}

#Preview("Réglage éteint") {
    Form {
        MLXMemorySettingSection(store: MLXModelSelectionStore(userDefaults: UserDefaults(suiteName: "preview.mlxMemory") ?? .standard))
    }
    .formStyle(.grouped)
}
