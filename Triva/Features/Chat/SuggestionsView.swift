//
//  SuggestionsView.swift
//  Triva
//
//  Created by ben podrojsky on 02/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Présentation (logique pure, testable)

/// Position d'une puce dans la disposition en flux (macOS) : le cadre de
/// chaque puce, dans l'ordre des suggestions, et la taille totale occupée.
///
/// Type nommé plutôt qu'un tuple : c'est le résultat d'une fonction pure
/// testée (`SuggestionsPresentation.flowArrangement`), que
/// `SuggestionsFlowLayout` ne fait qu'appliquer.
nonisolated struct SuggestionsFlowArrangement: Sendable, Equatable {
    let frames: [CGRect]
    let size: CGSize
}

/// Règles d'affichage des questions de suivi (tâche 1.7), isolées de la vue
/// pour être vérifiables sans lancer d'interface.
///
/// `nonisolated` : logique déterministe sur des `String`, des `CGSize` et des
/// `CGFloat`, sans aucun état. Sous `-default-isolation=MainActor`, elle
/// hériterait sinon du main actor — même convention que
/// `WeatherWidgetPresentation`.
nonisolated enum SuggestionsPresentation {

    /// Libellé de section, même rôle et même style que « ESSAIE » dans
    /// `TrivaHomeReferenceView` (label 11 pt, majuscules, tracking 1,5,
    /// `.tertiary`). Une forme courte et familière, dans le ton tutoyé de la
    /// DA, plutôt qu'une traduction littérale du « Related » de la version web d'origine.
    static let sectionTitle = "À CREUSER"

    /// Ce que VoiceOver lit pour l'en-tête de section : « À CREUSER » est
    /// clair à l'œil à côté des puces, moins à l'oreille sans contexte.
    static let sectionAccessibilityLabel = "Questions de suivi"

    /// Conséquence d'un toucher sur une puce, lue après le libellé : une
    /// suggestion pose une NOUVELLE question, ce que rien n'indique à
    /// l'oreille.
    static let chipAccessibilityHint = "Pose cette question"

    /// Les suggestions réellement affichées, dans l'ordre reçu.
    ///
    /// `SuggestionsService.sanitize` nettoie déjà sa propre sortie, mais la
    /// vue doit tenir seule : elle peut recevoir une liste relue depuis
    /// l'historique, ou construite ailleurs. Trois règles, chacune avec une
    /// raison concrète :
    /// - blancs internes ramenés à une espace, blancs de bord retirés : une
    ///   puce tient sur UNE ligne, un saut de ligne glissé dans un élément
    ///   JSON la couperait en deux. Le texte nettoyé est aussi celui envoyé
    ///   à `onSelect` — ce que l'utilisateur lit est exactement ce qui part ;
    /// - entrées vides écartées : une puce vide serait un bouton sans nom ;
    /// - doublons écartés sans tenir compte de la casse, première occurrence
    ///   gardée. Ce n'est pas qu'esthétique : `ForEach(id: \.self)` exige des
    ///   identifiants uniques, deux chaînes identiques y produiraient un
    ///   comportement indéfini.
    ///
    /// Aucun plafond de nombre ni de longueur ici : c'est le rôle du service
    /// (3 à 5 questions, 160 caractères). La vue n'écarte pas en silence ce
    /// qu'un appelant a délibérément passé.
    static func visibleSuggestions(_ suggestions: [String]) -> [String] {
        var seenKeys: Set<String> = []
        var visible: [String] = []

        for suggestion in suggestions {
            let normalized = suggestion
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !normalized.isEmpty else { continue }
            guard seenKeys.insert(normalized.lowercased()).inserted else { continue }
            visible.append(normalized)
        }

        return visible
    }

    /// Disposition en flux, ligne par ligne, de gauche à droite (macOS).
    ///
    /// Algorithme glouton : une puce part sur la ligne suivante dès qu'elle
    /// ne tient plus dans la largeur restante. Les règles qui comptent :
    /// - une puce plus large que la largeur disponible est RAMENÉE à cette
    ///   largeur (la vue tronque alors son texte, l'infobulle le donne en
    ///   entier) au lieu de déborder de la bulle de chat ;
    /// - une largeur infinie (proposition non contrainte) met tout sur une
    ///   seule ligne : c'est la taille idéale du flux ;
    /// - une ligne prend la hauteur de sa puce la plus haute.
    ///
    /// Les tailles viennent de SwiftUI et sont donc saines ; les valeurs
    /// négatives ou `nan` sont tout de même ramenées à zéro (`max(0, …)`
    /// renvoie 0 face à `nan`) — jamais de cadre aberrant, jamais de crash.
    static func flowArrangement(itemSizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> SuggestionsFlowArrangement {
        let availableWidth = max(0, maxWidth)
        let gap = max(0, spacing)
        var frames: [CGRect] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for size in itemSizes {
            let width = max(0, min(size.width, availableWidth))
            let height = max(0, size.height)

            // `cursorX > 0` : la ligne a déjà au moins une puce. Une puce
            // seule sur sa ligne n'en change jamais, même trop large.
            if cursorX > 0, cursorX + width > availableWidth {
                cursorY += rowHeight + gap
                cursorX = 0
                rowHeight = 0
            }

            frames.append(CGRect(x: cursorX, y: cursorY, width: width, height: height))
            widestRow = max(widestRow, cursorX + width)
            cursorX += width + gap
            rowHeight = max(rowHeight, height)
        }

        let totalHeight = frames.isEmpty ? 0 : cursorY + rowHeight
        return SuggestionsFlowArrangement(frames: frames, size: CGSize(width: widestRow, height: totalHeight))
    }
}

// MARK: - Disposition en flux (macOS)

/// Applique `SuggestionsPresentation.flowArrangement` : toute la géométrie
/// est dans la fonction pure, ce type ne fait que mesurer et placer.
///
/// `nonisolated` est OBLIGATOIRE ici, pas une convention : dans le SDK,
/// `Layout` est déclaré `@preconcurrency public protocol Layout: Sendable,
/// Animatable`, sans `@MainActor`. Laissé à l'isolation par défaut du projet,
/// ce type serait isolé au main actor, et ses méthodes ne pourraient pas
/// satisfaire les exigences non isolées d'un protocole qui hérite de
/// `Sendable` (aucune conformité isolée n'est possible dans ce cas).
/// `LayoutSubview.sizeThatFits` et `place` sont eux aussi non isolés.
///
/// Chaque puce est mesurée à sa taille idéale (`.unspecified`), puis placée
/// avec son cadre en guise de proposition : une puce ramenée à la largeur
/// disponible reçoit donc cette largeur et tronque son texte.
nonisolated struct SuggestionsFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrangement(maxWidth: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrangement(maxWidth: CGFloat, subviews: Subviews) -> SuggestionsFlowArrangement {
        SuggestionsPresentation.flowArrangement(
            itemSizes: subviews.map { $0.sizeThatFits(.unspecified) },
            maxWidth: maxWidth,
            spacing: spacing
        )
    }
}

// MARK: - Vue

/// Questions de suivi proposées sous une réponse (tâche 1.7) : des puces
/// cliquables, chacune relançant une recherche via `onSelect`.
///
/// Port de la section « Related » de la version web d'origine,
/// refaite selon `DESIGN.md` : mêmes puces en verre que la section « ESSAIE »
/// de `TrivaHomeReferenceView`, qui fait foi.
///
/// ## Rien ne s'affiche si la liste est vide
/// `SuggestionsService.generateSuggestions` renvoie `[]` dès que le moteur
/// échoue ou répond mal : c'est son repli documenté. Ici, une liste vide (ou
/// réduite à des blancs) ne produit AUCUNE vue — ni en-tête orphelin, ni
/// message « aucune suggestion », qui serait du remplissage pour une
/// fonctionnalité d'agrément.
///
/// ## iOS : défilement horizontal ; macOS : flux
/// - **iOS / iPadOS** : copie conforme de la référence —
///   `ScrollView(.horizontal)`. Le balayage horizontal est un geste naturel
///   au doigt, et une seule ligne garde la réponse compacte sur iPhone.
/// - **macOS** : disposition en flux (`SuggestionsFlowLayout`). Une molette
///   de souris ne fait défiler que verticalement, et aucun indicateur ne
///   signale qu'une ligne horizontale continue : les puces hors champ
///   n'y seraient jamais découvertes. La fenêtre Mac est large, le flux
///   montre en général les 3 à 5 suggestions d'un coup sur une ou deux
///   lignes. Une puce trop longue y est tronquée (une seule ligne, la forme
///   capsule ne supporte pas bien deux lignes) et son texte complet s'affiche
///   en infobulle au survol.
///
/// ## Intégration (étape suivante, pas ici)
/// - À poser SOUS la bulle assistant, comme FRÈRE, jamais dedans : des puces
///   en verre dans la bulle en verre feraient du verre sur du verre.
/// - Hors du `GlassEffectContainer` des bulles de `ChatView` (par exemple à
///   côté du bandeau d'erreur) : cette vue ouvre son propre conteneur pour
///   ses puces, comme la référence, et deux conteneurs imbriqués seraient
///   faux.
/// - Même règle que la version web d'origine : seulement sous la DERNIÈRE réponse, une fois sa
///   génération terminée. Pendant une génération, l'appelant masque la vue
///   ou applique `.disabled(true)`, que SwiftUI propage aux boutons.
struct SuggestionsView: View {
    let suggestions: [String]
    /// Reçoit la suggestion telle qu'affichée (nettoyée, voir
    /// `SuggestionsPresentation.visibleSuggestions`), à envoyer comme une
    /// nouvelle question.
    ///
    /// `@MainActor` dans le type : l'action n'est appelée que depuis un
    /// bouton, donc sur le main actor, et l'intégration peut y passer une
    /// méthode du ViewModel (isolé au main actor) sans conversion qui
    /// perdrait l'acteur, refusée en mode Swift 6. Une closure non isolée
    /// reste acceptée.
    let onSelect: @MainActor (String) -> Void

    var body: some View {
        let visibleSuggestions = SuggestionsPresentation.visibleSuggestions(suggestions)
        if !visibleSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader
                chips(for: visibleSuggestions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// `.caption2.weight(.medium)` plutôt que le `.system(size: 11)` de la
    /// référence : sur iOS c'est la même taille (11 pt) à la taille de texte
    /// par défaut, mais un style de texte suit Dynamic Type, une taille fixe
    /// non. Sur Mac, qui n'a pas Dynamic Type, `.caption2` vaut 10 pt : la
    /// taille de légende du système, alignée sur le reste de la fenêtre.
    private var sectionHeader: some View {
        Text(SuggestionsPresentation.sectionTitle)
            .font(.caption2.weight(.medium))
            .tracking(1.5)
            .foregroundStyle(.tertiary)
            .accessibilityLabel(SuggestionsPresentation.sectionAccessibilityLabel)
            .accessibilityAddTraits(.isHeader)
    }

    /// Un seul `GlassEffectContainer` pour toutes les puces, frères de verre
    /// (DESIGN.md). Espacement de 8 entre puces, comme la référence.
    @ViewBuilder
    private func chips(for suggestions: [String]) -> some View {
        #if os(macOS)
        GlassEffectContainer(spacing: 8) {
            SuggestionsFlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    chip(suggestion)
                }
            }
        }
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        chip(suggestion)
                    }
                }
            }
        }
        // Les puces défilent jusqu'au bord de l'écran au lieu d'être coupées net à 20 pt de lui
        // (QA Q3, finding 34), comme Découvrir (`DiscoverView`).
        .scrollClipDisabled()
        #endif
    }

    /// `.buttonStyle(.glass)` : action secondaire (DESIGN.md), jamais
    /// `.glassProminent`, réservé à l'action principale d'un écran.
    /// `.help` seulement sur macOS : c'est l'infobulle qui rend lisible une
    /// puce tronquée par le flux ; sur iOS elle doublerait l'indice VoiceOver.
    private func chip(_ suggestion: String) -> some View {
        Button {
            onSelect(suggestion)
        } label: {
            Text(verbatim: suggestion)
                .lineLimit(1)
        }
        .font(.subheadline)
        .buttonStyle(.glass)
        .accessibilityHint(SuggestionsPresentation.chipAccessibilityHint)
        #if os(macOS)
        .help(suggestion)
        #endif
    }
}

// MARK: - Previews

#Preview("Suggestions — clair") {
    SuggestionsView(
        suggestions: [
            "Quelle est la hauteur de la tour Eiffel avec ses antennes ?",
            "Qui a conçu la tour Eiffel ?",
            "Combien de visiteurs par an ?",
        ],
        onSelect: { _ in }
    )
    .padding(20)
}

#Preview("Suggestions — sombre") {
    SuggestionsView(
        suggestions: [
            "Compare les deux processeurs",
            "Lequel consomme le moins ?",
            "Quel est le prix de lancement ?",
            "Disponible en France ?",
        ],
        onSelect: { _ in }
    )
    .padding(20)
    .preferredColorScheme(.dark)
}

/// Doublons (casse différente), blancs et saut de ligne glissé dans un
/// élément : seules deux puces doivent apparaître, chacune sur une ligne.
#Preview("Suggestions — entrée brute à nettoyer") {
    SuggestionsView(
        suggestions: [
            "  Quelle est la population de Lyon ?  ",
            "quelle est la population de Lyon ?",
            "   ",
            "Et celle de\nMarseille ?",
        ],
        onSelect: { _ in }
    )
    .padding(20)
}

#Preview("Suggestions — très grand texte, fenêtre étroite") {
    SuggestionsView(
        suggestions: [
            "Quelles sont les principales différences entre les modes de réponse rapide et approfondi ?",
            "Pourquoi ?",
            "Avec quelles sources ?",
        ],
        onSelect: { _ in }
    )
    .frame(width: 320)
    .padding(20)
    .dynamicTypeSize(.accessibility3)
}

/// État vide : la vue ne produit rien. Le texte ci-dessous n'existe que dans
/// la preview, pour montrer qu'aucune section n'apparaît entre les deux.
#Preview("Suggestions — liste vide") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Réponse terminée.")
        SuggestionsView(suggestions: [], onSelect: { _ in })
        Text("Fin du fil.")
            .foregroundStyle(.secondary)
    }
    .padding(20)
}
