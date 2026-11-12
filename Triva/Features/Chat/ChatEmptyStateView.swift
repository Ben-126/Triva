//
//  ChatEmptyStateView.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

/// Écran vide de la Recherche : un titre court et trois exemples de questions, touchables
/// (décision de Ben, 2026-11-11, QA Q3 finding 17). Avant, il n'y avait que le badge puis du
/// vide jusqu'à la barre de saisie : sobre, mais inachevé (HIG writing : « Provide clear next
/// steps on any blank screens »).
///
/// Porté de `TrivaHomeReferenceView` (titre, label « ESSAIE », boutons en verre), avec trois
/// écarts voulus :
/// - pas de « Bonjour » au-dessus du titre : une ligne de plus qui ne dit rien (DESIGN.md bannit
///   le remplissage) ;
/// - de VRAIES questions plutôt que des intentions (« Explique-moi un concept ») : chacune montre
///   ce que Triva sait faire (une recherche sourcée, un calcul, la météo) et part telle quelle ;
/// - empilées plutôt qu'en défilement horizontal : une question entière se lit sans glisser, et
///   passe à la ligne à AX3 au lieu d'être coupée.
struct ChatEmptyStateView: View {
    let onSelect: (String) -> Void

    /// Une recherche web sourcée, le widget de calcul, le widget météo. Questions courtes et
    /// neutres : rien qui « fasse IA » ni ne vante l'app.
    static let examples = [
        "Quelle est la hauteur de la tour Eiffel ?",
        "Combien font 1284 × 37 ?",
        "Quel temps fait-il à Lyon ?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Que veux-tu savoir ?")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 12) {
                HistorySectionHeader(title: "Essaie")

                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.examples, id: \.self) { example in
                            Button {
                                onSelect(example)
                            } label: {
                                Text(example)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.subheadline)
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("chat.example")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Écran vide") {
    ChatEmptyStateView(onSelect: { _ in })
        .padding(20)
}

#Preview("Écran vide — sombre, AX3") {
    ChatEmptyStateView(onSelect: { _ in })
        .padding(20)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
