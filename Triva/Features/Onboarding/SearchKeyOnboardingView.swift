//
//  SearchKeyOnboardingView.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

/// Deuxième étape du premier lancement, après le choix du moteur : proposer une clé de recherche
/// Brave ou Tavily (décision de Ben du 2026-11-11, option (b) du rapport T1).
///
/// POURQUOI : sans clé, Triva cherche sur des instances SearXNG publiques, que personne ne
/// maintient pour Triva : le test réseau T1 les a trouvées lentes ou en panne par moments. Une clé
/// personnelle fait passer les recherches d'abord par Brave ou Tavily (`WebSearchChain`). La
/// personne doit le savoir au moment où elle règle l'app, pas après une recherche vide.
///
/// FACULTATIVE, jamais forcée : aucun champ n'est sur cet écran, aucune saisie n'est exigée.
/// « Commencer » passe l'étape ; « Ajouter une clé » ouvre l'écran des Réglages (`SearchKeysView`,
/// une seule implémentation de la saisie, du test et du Trousseau) dans une feuille, qu'on ferme
/// d'un geste ou de « Fermer ».
///
/// Phrases vérifiées avec le comportement réel : « d'abord par ce service » (`WebSearchChain` met
/// les clés avant SearXNG), « Trousseau de cet appareil » (`SearchKeyStore`) et « ne part que vers ce
/// service » (la clé n'est envoyée qu'à Brave ou Tavily). Aucune promesse de gratuité ni de quota :
/// elles dépendent du fournisseur.
struct SearchKeyOnboardingView: View {
    let onStart: () -> Void

    @State private var isAddingKey = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    Text("Sans clé, Triva cherche sur des instances SearXNG publiques, parfois lentes ou en panne. Avec une clé Brave ou Tavily, tes recherches passent d'abord par ce service : les résultats sont plus fiables.")
                    Text("Ta clé reste dans le Trousseau de cet appareil et ne part que vers ce service. Tu pourras l'ajouter plus tard dans les Réglages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    Button("Commencer", action: onStart)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("onboarding.searchKey.start")
                    Button("Ajouter une clé") {
                        isAddingKey = true
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("onboarding.searchKey.add")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $isAddingKey) {
            keySheet
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Une clé de recherche ?")
                .screenTitleFont()
            Text("Facultatif. Tu peux passer cette étape.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var keySheet: some View {
        NavigationStack {
            SearchKeysView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Explicite : le libellé du système sortirait en anglais.
                        Button("Fermer") { isAddingKey = false }
                            .accessibilityIdentifier("onboarding.searchKey.close")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
    }
}

#Preview("Étape clé de recherche") {
    SearchKeyOnboardingView {}
}

#Preview("AX3") {
    SearchKeyOnboardingView {}
        .dynamicTypeSize(.accessibility3)
}
