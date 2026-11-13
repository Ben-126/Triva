//
//  CitationView.swift
//  Triva
//
//  Created by ben podrojsky on 02/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Types

/// La citation touchée : son numéro et la source qu'elle désigne.
///
/// Sert de « charge utile » à la présentation (`.popover(item:)`,
/// `.sheet(item:)`) : le détail n'existe que si la source existe, jamais
/// d'état « feuille ouverte mais source introuvable ». `id` = numéro de
/// citation : deux badges `[3]` d'une même réponse montrent la même source.
nonisolated struct CitationSelection: Sendable, Equatable, Identifiable {
    let citationIndex: Int
    let source: SearXNGSearchResult

    var id: Int { citationIndex }
}

/// Forme du détail d'une source, selon la place disponible.
nonisolated enum CitationDetailPresentationStyle: Sendable, Equatable {
    /// Feuille en bas d'écran (iPhone, ou iPad en fenêtre étroite).
    case sheet
    /// Bulle ancrée près du badge (iPad en `regular`, macOS).
    case popover
}


// MARK: - Vue

/// Texte de réponse avec citations `[n]` cliquables (tâche 1.12).
///
/// Port du composant de citation de la version web d'origine, qui affiche
/// au survol une bulle avec le titre et le domaine de la source. Ici : un
/// toucher (iOS) ou un clic (macOS) sur un badge ouvre une fiche avec le
/// titre, le domaine, l'extrait et un bouton d'ouverture.
///
/// ## Ce qu'on lui donne
/// `text` est le CORPS de la réponse (`ReasoningSegments.body`), pas
/// `message.text` brut : segmenter UNE fois par rendu et partager le résultat
/// avec `ThinkBoxView`, qui affiche `.reasoning`. Le TL;DR du mode Approfondi
/// (`.tldr`) n'est rendu par AUCUNE des deux vues : à placer à l'intégration
/// (une phrase au-dessus du corps), sinon il disparaît de l'écran.
/// `isStreaming` (`message.isStreaming`) décide du sort du fragment de
/// marqueur retenu en fin de texte (voir `CitationPresentation.attributedText`).
///
/// ## Feuille sur iPhone, bulle sur iPad et Mac
/// Voir `CitationPresentation.presentationStyle`. La bulle est ancrée au
/// point touché : SwiftUI ne donne pas la position d'un passage dans un
/// `Text`, mais un `SpatialTapGesture` SIMULTANÉ (qui n'empêche pas le lien
/// de recevoir le toucher) relève la position du dernier toucher. Le lien,
/// lui, ne la connaît pas : la présentation est donc différée d'un tour du
/// main actor (`Task`), pour que le geste ait toujours écrit sa position
/// avant que la bulle ne la lise. Sans position (VoiceOver, premier rendu),
/// la bulle s'ancre sur tout le texte.
///
/// ## Accessibilité
/// - Le texte lu remplace chaque badge par « source 3 »
///   (`CitationPresentation.accessibilityText(fromRendered:)`, dérivé du
///   texte affiché sans second rendu Markdown).
/// - Les badges sont de petites cibles au doigt : chaque source citée est
///   aussi une action VoiceOver nommée (« Source 3 : titre »), qui ouvre la
///   même fiche.
///
/// ## Liens de la réponse
/// Les liens Markdown ordinaires passent par l'`openURL` de l'environnement
/// parent (pas `.systemAction`) : un futur navigateur intégré installé à la
/// racine de l'app les recevra sans changer cette vue. Seuls http, https et
/// mailto s'ouvrent (voir `CitationPresentation.isAllowedExternalLink`).
struct CitationView: View {
    let text: String
    let sources: [SearXNGSearchResult]
    let isStreaming: Bool
    /// Sources jamais lues : citation en texte simple (`CitationParser.parse(_:sourceCount:unread:)`).
    var unreadSourceNumbers: Set<Int> = []

    /// Largeur de la bulle : une colonne de lecture confortable, quelle que
    /// soit la taille de la fenêtre. Multiple de la grille.
    private static let popoverWidth: CGFloat = 320

    @State private var selection: CitationSelection?
    /// Dernier point touché sur le texte, dans son repère local. Remis à
    /// `nil` à chaque fermeture : une position périmée ancrerait la bulle
    /// suivante au mauvais endroit, l'ancre sur tout le texte est préférable.
    @State private var lastTapLocation: CGPoint?
    /// L'action d'ouverture du PARENT : `.environment(\.openURL, …)` plus bas
    /// ne s'applique qu'au `Text`, pas à cette propriété.
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Une seule analyse Markdown par rendu : le texte lu par VoiceOver est
    /// dérivé de `rendered`, pas reconstruit.
    var body: some View {
        let parsed = CitationParser.parse(text, sourceCount: sources.count, unread: unreadSourceNumbers)
        let rendered = CitationPresentation.attributedText(for: parsed, isStreaming: isStreaming)
        Text(rendered)
            // Closure littérale : `handler` est une fonction NON isolée dans le
            // SDK, y passer la méthode `handleOpenURL` (main actor) perdrait
            // l'acteur, refusé en Swift 6. La closure hérite du main actor.
            .environment(\.openURL, OpenURLAction { url in handleOpenURL(url) })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                lastTapLocation = value.location
            })
            .accessibilityLabel(CitationPresentation.accessibilityText(fromRendered: rendered))
            .accessibilityIdentifier("citation.text")
            .accessibilityActions {
                ForEach(CitationPresentation.citedSources(in: parsed, sources: sources)) { cited in
                    Button(CitationPresentation.accessibilityActionName(for: cited)) {
                        presentWithoutAnchor(cited)
                    }
                }
            }
            .popover(item: popoverSelection, attachmentAnchor: popoverAnchor) { selected in
                CitationSourceCard(selection: selected, onOpen: openSource)
                    .padding(20)
                    .frame(width: Self.popoverWidth)
            }
            .sheet(item: sheetSelection) { selected in
                ScrollView {
                    CitationSourceCard(selection: selected, onOpen: openSource)
                        .padding(20)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }

    // MARK: Présentation

    private var presentationStyle: CitationDetailPresentationStyle {
        CitationPresentation.presentationStyle(for: horizontalSizeClass)
    }

    /// Deux liaisons sur une seule source de vérité (`selection`) : la forme
    /// active la voit, l'autre voit toujours `nil`. Une fermeture par le
    /// système (toucher hors de la bulle, glissement de la feuille) passe par
    /// le `set` et nettoie tout l'état.
    private var popoverSelection: Binding<CitationSelection?> {
        selectionBinding(for: .popover)
    }

    private var sheetSelection: Binding<CitationSelection?> {
        selectionBinding(for: .sheet)
    }

    private func selectionBinding(for style: CitationDetailPresentationStyle) -> Binding<CitationSelection?> {
        Binding(
            get: { presentationStyle == style ? selection : nil },
            set: { newValue in
                if let newValue {
                    selection = newValue
                } else {
                    dismissSelection()
                }
            }
        )
    }

    /// Petit rectangle centré sur le point touché (2 × 2 pt) plutôt qu'un
    /// rectangle vide, que certains systèmes de positionnement remplacent
    /// par les bornes de la vue.
    private var popoverAnchor: PopoverAttachmentAnchor {
        guard let lastTapLocation else { return .rect(.bounds) }
        return .rect(.rect(CGRect(x: lastTapLocation.x - 1, y: lastTapLocation.y - 1, width: 2, height: 2)))
    }

    // MARK: Actions

    /// Badge touché : on présente au tour suivant du main actor (voir la
    /// doc du type). Tout autre lien autorisé part vers l'`openURL` parent ;
    /// les autres sont ignorés (`.discarded`), jamais confiés au système.
    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        if let index = CitationPresentation.citationIndex(from: url) {
            Task { presentCitation(index: index) }
            return .handled
        }
        guard CitationPresentation.isAllowedExternalLink(url) else { return .discarded }
        openURL(url)
        return .handled
    }

    /// L'indice repasse par `CitationParser.source` : un lien interne forgé
    /// avec un numéro sans source n'ouvre rien.
    private func presentCitation(index: Int) {
        guard let source = CitationParser.source(forCitationIndex: index, in: sources) else { return }
        selection = CitationSelection(citationIndex: index, source: source)
    }

    /// Action VoiceOver : aucun point touché, la bulle s'ancre sur le texte.
    private func presentWithoutAnchor(_ cited: CitationSelection) {
        lastTapLocation = nil
        selection = cited
    }

    private func openSource(_ url: URL) {
        dismissSelection()
        openURL(url)
    }

    private func dismissSelection() {
        selection = nil
        lastTapLocation = nil
    }
}

// MARK: - Fiche source

/// Contenu de la feuille / de la bulle d'une citation : numéro, titre,
/// domaine, extrait, bouton d'ouverture.
///
/// Pas de verre ici : la feuille et la bulle du système en sont déjà, et du
/// verre sur du texte statique est exclu par DESIGN.md. Le seul élément en
/// verre est le bouton, l'action principale de la fiche
/// (`.glassProminent`). Le domaine n'est pas répété quand il sert déjà de
/// titre (pas de texte qui répète un autre).
struct CitationSourceCard: View {
    let selection: CitationSelection
    /// `@MainActor` : appelée depuis le bouton, elle accepte directement une
    /// méthode de vue (`onOpen: openSource`) sans conversion qui perdrait l'acteur.
    let onOpen: @MainActor (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            details
            if let url = CitationPresentation.openableURL(for: selection.source) {
                Button {
                    onOpen(url)
                } label: {
                    Label("Ouvrir la source", systemImage: "arrow.up.right")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Un seul élément VoiceOver pour les textes : « Source 3, titre,
    /// domaine, extrait », puis le bouton, à part.
    private var details: some View {
        let title = CitationPresentation.displayTitle(for: selection.source)
        let host = CitationPresentation.displayHost(for: selection.source)
        let excerpt = CitationPresentation.excerpt(from: selection.source.content)

        return VStack(alignment: .leading, spacing: 8) {
            Text(CitationPresentation.sourceLabel(citationIndex: selection.citationIndex))
                .font(.caption2.weight(.medium))
                .tracking(1.5)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Source \(selection.citationIndex)")

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let host, host != title {
                    Text(verbatim: host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let excerpt {
                Text(verbatim: excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

private extension SearXNGSearchResult {
    static func citationPreview(title: String, url: String, content: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title,
            url: url,
            content: content,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    static let citationPreviewSources: [SearXNGSearchResult] = [
        .citationPreview(
            title: "Tour Eiffel — Wikipédia",
            url: "https://fr.wikipedia.org/wiki/Tour_Eiffel",
            content: "La tour Eiffel est une tour de fer puddlé de 330 mètres de hauteur (avec antennes) située à Paris, à l'extrémité nord-ouest du parc du Champ-de-Mars en bordure de la Seine."
        ),
        .citationPreview(
            title: "Chiffres clés de la tour Eiffel",
            url: "https://www.toureiffel.paris/fr/chiffres-cles",
            content: "Près de 7 millions de visiteurs par an, dont environ 75 % d'étrangers."
        ),
        .citationPreview(
            title: "",
            url: "https://www.lemonde.fr/culture/article/2025/tour-eiffel",
            content: nil
        ),
    ]
}

#Preview("Citations — paragraphe") {
    CitationView(
        text: "La tour Eiffel mesure **330 mètres avec ses antennes[1].** Elle accueille près de 7 millions de visiteurs par an[2], ce qui en fait l'un des monuments payants les plus visités au monde[2][3]. Sa construction a duré un peu plus de deux ans[1].",
        sources: SearXNGSearchResult.citationPreviewSources,
        isStreaming: false
    )
    .padding(20)
}

/// Badges sur certaines lignes seulement : l'espacement entre lignes doit
/// rester régulier (aucune ligne à badge plus haute que les autres).
#Preview("Citations — interlignage, grand texte") {
    CitationView(
        text: "Première phrase sans citation, assez longue pour occuper toute une ligne. Deuxième phrase avec une citation[1]. Troisième phrase, encore sans citation, pour comparer l'espacement. Quatrième phrase avec deux citations[1][2].",
        sources: SearXNGSearchResult.citationPreviewSources,
        isStreaming: false
    )
    .frame(width: 320)
    .padding(20)
    .dynamicTypeSize(.xxxLarge)
}

/// Pendant le streaming, le `[2` final est retenu : il ne doit pas
/// apparaître.
#Preview("Citations — streaming, marqueur tronqué") {
    CitationView(
        text: "Elle accueille près de 7 millions de visiteurs par an[2",
        sources: SearXNGSearchResult.citationPreviewSources,
        isStreaming: true
    )
    .padding(20)
}

/// Flux terminé : le même fragment est relâché en texte brut (« [2 »).
#Preview("Citations — flux terminé, fragment relâché") {
    CitationView(
        text: "Une réponse qui se termine vraiment par [2",
        sources: SearXNGSearchResult.citationPreviewSources,
        isStreaming: false
    )
    .padding(20)
}

/// Sans source attachée, `[1]` reste du texte, et l'indice de tableau en
/// code n'est jamais un badge.
#Preview("Citations — sans source, code, sombre") {
    VStack(alignment: .leading, spacing: 16) {
        CitationView(
            text: "Réponse sans recherche associée : [1] reste du texte.",
            sources: [],
            isStreaming: false
        )
        CitationView(
            text: "En Python, `liste[1]` renvoie le deuxième élément[1].",
            sources: SearXNGSearchResult.citationPreviewSources,
            isStreaming: false
        )
    }
    .padding(20)
    .preferredColorScheme(.dark)
}

#Preview("Fiche source — complète") {
    CitationSourceCard(
        selection: CitationSelection(citationIndex: 1, source: SearXNGSearchResult.citationPreviewSources[0]),
        onOpen: { _ in }
    )
    .padding(20)
    .frame(width: 320)
}

/// Source sans titre ni extrait : le domaine sert de titre, sans être
/// répété dessous.
#Preview("Fiche source — minimale, sombre") {
    CitationSourceCard(
        selection: CitationSelection(citationIndex: 3, source: SearXNGSearchResult.citationPreviewSources[2]),
        onOpen: { _ in }
    )
    .padding(20)
    .frame(width: 320)
    .preferredColorScheme(.dark)
}
