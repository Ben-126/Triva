//
//  ChatEmptyStateView.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

/// Écran vide de la Recherche : un titre court et des exemples de questions, touchables
/// (décision de Ben, 2026-11-11, QA Q3 finding 17). Avant, il n'y avait que le badge puis du
/// vide jusqu'à la barre de saisie : sobre, mais inachevé (HIG writing : « Provide clear next
/// steps on any blank screens »).
///
/// Porté de `TrivaHomeReferenceView` (titre, label « ESSAIE », boutons en verre), avec trois
/// écarts voulus :
/// - pas de « Bonjour » au-dessus du titre : une ligne de plus qui ne dit rien (DESIGN.md bannit
///   le remplissage) ;
/// - de VRAIES questions plutôt que des intentions (« Explique-moi un concept ») : elles partent
///   telles quelles, et montrent le pouvoir de l'app, la recherche web (décision de Ben,
///   2026-11-11). Elles dépendent de la présence d'une clé de recherche (`SearchKeyAvailability`) :
///   AVEC une clé, quatre questions d'actualité et de comparaison, que seule une recherche web
///   fiable sait traiter ; SANS clé, deux questions de culture générale, car les instances
///   SearXNG publiques sont presque toujours en panne et la seule source fiable est alors
///   Wikipédia ;
/// - empilées plutôt qu'en défilement horizontal : une question entière se lit sans glisser, et
///   passe à la ligne à AX3 au lieu d'être coupée.
struct ChatEmptyStateView: View {
    let onSelect: (String) -> Void
    @State private var availability: SearchKeyAvailability

    init(availability: SearchKeyAvailability = SearchKeyAvailability(), onSelect: @escaping (String) -> Void) {
        _availability = State(initialValue: availability)
        self.onSelect = onSelect
    }

    /// Exemples AVEC une clé de recherche : l'actualité, le cinéma, les nouveautés d'iOS 27 et une
    /// comparaison, des questions qui exigent le web du jour.
    static let examplesWithSearchKey = [
        "Qu'est-ce qui fait l'actualité aujourd'hui ?",
        "Quels films sortent au cinéma cette semaine ?",
        "Quelles sont les nouveautés d'iOS 27 ?",
        "Compare les voitures électriques les plus vendues en France",
    ]

    /// Exemples SANS clé : des questions de culture générale, que Wikipédia suffit à sourcer.
    static let examplesWithoutSearchKey = [
        "Pourquoi la tour Eiffel a-t-elle été construite ?",
        "Comment se forme un trou noir ?",
    ]

    /// Le choix de la liste, pur et testable.
    static func examples(hasSearchKey: Bool) -> [String] {
        hasSearchKey ? examplesWithSearchKey : examplesWithoutSearchKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Que veux-tu savoir ?")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 12) {
                HistorySectionHeader(title: "Essaie")

                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.examples(hasSearchKey: availability.hasKey), id: \.self) { example in
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
        .onReceive(NotificationCenter.default.publisher(for: SearchKeyStore.didChangeNotification)) { _ in
            availability.invalidate()
        }
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
