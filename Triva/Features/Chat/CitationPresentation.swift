//
//  CitationPresentation.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation
import SwiftUI

// Sorti de `CitationView.swift` (mission E1c) : déplacement pur, aucun
// changement de code ni de comportement.

// MARK: - Présentation (logique pure, testable)

/// Tout ce que `CitationView` décide sans dessiner : texte affiché, texte lu
/// par VoiceOver, liens internes, contenu de la fiche source.
///
/// `nonisolated` : logique déterministe sur `CitationParseResult`,
/// `SearXNGSearchResult` et `AttributedString`, tous non isolés et
/// `Sendable`. Même convention que `WeatherWidgetPresentation`.
///
/// ## Pourquoi un seul `Text` construit depuis une `AttributedString`
/// C'est LE point délicat de la tâche 1.12 : le badge doit rester sur la
/// ligne de texte sans en changer l'interlignage.
/// - Une composition de vues (un `Text` par mot plus un bouton par badge dans
///   une disposition en flux) perdrait la coupure de ligne native, la
///   césure, la lecture continue par VoiceOver, et coûterait des centaines de
///   vues relayoutées à chaque token.
/// - `Text + Text` ne permet pas de toucher un seul morceau.
/// - Un seul `Text` dont les badges sont des passages porteurs d'un lien
///   interne (`triva-citation://source/3`) garde la mise en page du système,
///   et `OpenURLAction` intercepte le toucher. C'est aussi la continuité de
///   `MessageBubbleView`, qui rend déjà sa réponse en un seul `Text`.
///
/// ## Le badge ne touche jamais l'interlignage
/// Il est posé sur la ligne de base, en `.footnote` : une police plus petite
/// que le corps a une hauteur de ligne plus petite, elle ne peut donc pas
/// agrandir la ligne qui la contient. Pas de `baselineOffset` (un exposant
/// qui dépasserait l'ascendante du corps agrandirait JUSTE les lignes qui
/// ont un badge), et pas de `backgroundColor` : SwiftUI dessine un rectangle
/// à angles droits, une troisième forme interdite par la règle des deux
/// rayons de DESIGN.md. La couleur d'accent, que SwiftUI donne aux liens,
/// suffit à dire « touchable ».
nonisolated enum CitationPresentation {

    // MARK: Constantes

    /// Schéma des liens internes portés par les badges. Jamais transmis au
    /// système : `CitationView` l'intercepte avant (`OpenURLAction`).
    static let urlScheme = "triva-citation"
    static let urlHost = "source"

    /// Espace fine insécable (U+202F) placée devant un badge collé au mot
    /// précédent. Le prompt demande « 330 mètres[1]. » : sans espace, le
    /// badge se colle au mot. Insécable, elle empêche aussi un `[3]` de
    /// partir seul en début de ligne suivante. Même caractère que celui de la
    /// typographie française devant « ; : ! ? ».
    static let narrowNoBreakSpace = "\u{202F}"

    /// Longueur maximale de l'extrait montré dans la fiche. 280 caractères :
    /// deux à trois phrases, de quoi juger si la source dit bien ce que la
    /// réponse lui attribue, sans transformer une bulle de Mac en article.
    static let maxExcerptLength = 280

    /// Titre de repli quand la source n'a ni titre ni hôte lisible.
    static let untitledSourceTitle = "Source sans titre"

    /// Police du badge : plus petite que le corps (voir le type), `.medium`
    /// pour qu'un chiffre isolé reste lisible à cette taille.
    static let badgeFont: Font = .footnote.weight(.medium)

    /// Caractère sentinelle (zone d'usage privé Unicode, U+E000) qui tient
    /// la place d'une citation pendant l'analyse Markdown. Voir
    /// `mergedRendering`.
    private static let sentinel: Character = "\u{E000}"
    private static let sentinelMarkup = "[\u{E000}]"

    /// Liens d'une réponse que l'app accepte d'ouvrir. La réponse vient d'un
    /// modèle nourri de pages web, donc exposé à l'injection de prompt : un
    /// lien Markdown vers `shortcuts://run-shortcut?…` ou vers le schéma
    /// d'une autre app déclencherait une action d'un simple toucher. On s'en
    /// tient au web et au courriel.
    private static let allowedExternalSchemes: Set<String> = ["http", "https", "mailto"]
    /// Une source SearXNG est une page web : seul le web s'ouvre.
    private static let openableSourceSchemes: Set<String> = ["http", "https"]
    /// Après ces caractères, un badge n'a pas besoin d'espace : « ([1]) ».
    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "«", "“", "‘"]
    /// Ponctuation retirée avant les points de suspension d'un extrait coupé.
    private static let trailingPunctuationBeforeEllipsis: Set<Character> = [",", ";", ":", " "]

    // MARK: Liens internes

    /// `triva-citation://source/3`. `nil` pour un indice qui ne peut pas
    /// désigner une source (0 ou négatif).
    static func url(forCitationIndex index: Int) -> URL? {
        guard index >= 1 else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        components.path = "/\(index)"
        return components.url
    }

    /// Inverse de `url(forCitationIndex:)`. Strict : schéma, hôte, et un
    /// chemin fait d'au plus `CitationParser.maxCitationDigits` chiffres
    /// ASCII. Un lien forgé (écrit par le modèle avec notre schéma) qui
    /// passerait ce filtre ne peut qu'ouvrir la fiche d'une source existante :
    /// `CitationView` repasse l'indice par `CitationParser.source`.
    static func citationIndex(from url: URL) -> Int? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == urlScheme,
            components.host?.lowercased() == urlHost,
            components.path.hasPrefix("/")
        else { return nil }

        let digits = components.path.dropFirst()
        guard
            !digits.isEmpty,
            digits.count <= CitationParser.maxCitationDigits,
            digits.allSatisfy({ $0.isASCII && $0.isNumber }),
            let index = Int(digits),
            index >= 1
        else { return nil }
        return index
    }

    /// Vrai pour un lien de la réponse que l'app peut ouvrir (voir
    /// `allowedExternalSchemes`).
    static func isAllowedExternalLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedExternalSchemes.contains(scheme)
    }

    /// Feuille en `compact`, bulle sinon. `nil` (pas de classe de taille, ce
    /// qui arrive sur macOS — voir `TrivaRootNavigationStyle`) vaut `regular`.
    static func presentationStyle(for horizontalSizeClass: UserInterfaceSizeClass?) -> CitationDetailPresentationStyle {
        horizontalSizeClass == .compact ? .sheet : .popover
    }

    // MARK: Texte affiché et texte lu

    /// Le texte à afficher, citations comprises.
    ///
    /// Contrat de `CitationParseResult.pendingSuffix` honoré : pendant le
    /// streaming, le fragment retenu (`"[1"`) est IGNORÉ ; une fois le flux
    /// terminé, il est ajouté tel quel, en texte brut, sans analyse Markdown.
    static func attributedText(for result: CitationParseResult, isStreaming: Bool) -> AttributedString {
        let placements = citationPlacements(in: result.segments)
        var rendered: AttributedString
        if placements.isEmpty {
            rendered = markdown(result.segments.map(\.text).joined())
        } else {
            rendered = mergedRendering(result.segments, placements: placements)
                ?? segmentwiseRendering(result.segments, placements: placements)
        }
        if !isStreaming, !result.pendingSuffix.isEmpty {
            rendered.append(AttributedString(result.pendingSuffix))
        }
        return rendered
    }

    /// Le même texte, écrit pour VoiceOver : Markdown déjà interprété (pas
    /// d'astérisques lues « étoile »), chaque badge lu « source 3 ».
    ///
    /// Dérivé du texte DÉJÀ rendu, en une passe sur ses segments d'attributs :
    /// la vue est réévaluée à chaque token pendant le streaming, une seconde
    /// analyse Markdown de toute la réponse y doublerait le coût. Un badge se
    /// reconnaît à son lien interne ; l'espace fine qui le précède devient une
    /// virgule à l'oral (« mètres, source 1 »). Limite assumée : deux badges
    /// IDENTIQUES collés (`[2][2]`) ont les mêmes attributs, leurs segments
    /// fusionnent, et cette source répétée n'est lue qu'une fois.
    static func accessibilityText(fromRendered rendered: AttributedString) -> String {
        var spoken = ""
        for run in rendered.runs {
            let runText = String(rendered[run.range].characters)
            guard let link = run.link, let index = citationIndex(from: link) else {
                spoken += runText
                continue
            }
            spoken += (runText.hasPrefix(narrowNoBreakSpace) ? ", " : "") + "source \(index)"
        }
        return spoken
    }

    /// Analyse Markdown identique à `MessageBubbleView` :
    /// `.inlineOnlyPreservingWhitespace` (gras, italique, code, liens) en
    /// gardant les sauts de ligne. Le repli sur le texte brut est le même
    /// aussi : une erreur d'analyse ne dit rien d'actionnable, afficher le
    /// texte tel quel est la seule réponse utile.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Une citation à rendre, dans l'ordre du texte. `nonisolated` OBLIGATOIRE :
    /// un type imbriqué n'hérite pas de celui de son parent, il serait isolé
    /// au main actor (initialiseur compris) alors que `citationPlacements(in:)`,
    /// non isolée, le construit. Même convention que dans `ReasoningSegmenter`.
    private nonisolated struct CitationPlacement {
        let index: Int
        let needsLeadingSpace: Bool
    }

    /// Une espace devant le badge seulement s'il est collé à quelque chose :
    /// rien en tête de texte, rien après un blanc ou une ponctuation
    /// ouvrante, une espace entre deux badges (« [1] [2] »).
    private static func citationPlacements(in segments: [CitationSegment]) -> [CitationPlacement] {
        var placements: [CitationPlacement] = []
        var previous: CitationSegment?
        for segment in segments {
            if let index = segment.citationIndex {
                placements.append(CitationPlacement(index: index, needsLeadingSpace: needsLeadingSpace(after: previous)))
            }
            previous = segment
        }
        return placements
    }

    private static func needsLeadingSpace(after previous: CitationSegment?) -> Bool {
        guard let previous else { return false }
        guard previous.citationIndex == nil else { return true }
        guard let last = previous.text.last else { return false }
        return !last.isWhitespace && !openingPunctuation.contains(last)
    }

    /// Rendu nominal : UNE analyse Markdown sur tout le texte.
    ///
    /// Analyser chaque segment à part casserait le Markdown qui enjambe une
    /// citation — et le prompt place les citations en fin de phrase, donc
    /// souvent DANS un passage en gras : « **330 mètres[1].** » deviendrait
    /// deux segments avec des `**` orphelins affichés tels quels. On remplace
    /// donc chaque citation par `[` + sentinelle + `]`, on analyse tout, puis
    /// on substitue le badge à chaque sentinelle retrouvée. Garder les
    /// crochets autour de la sentinelle n'est pas un détail : les règles
    /// d'emphase de CommonMark regardent si le caractère voisin est une
    /// ponctuation, et `[` en est une — le gras se ferme exactement comme
    /// avec la citation d'origine.
    ///
    /// Une citation que l'analyse a rangée dans du CODE (`liste[1]` entre
    /// backticks, fréquent dans une réponse de programmation) redevient le
    /// texte `[1]`, en code : ce n'est pas une citation, c'est un indice de
    /// tableau, et le badge renverrait à une source sans rapport.
    ///
    /// Renvoie `nil` si le nombre de sentinelles retrouvées ne correspond
    /// pas (texte contenant déjà la séquence sentinelle, cas pathologique) :
    /// l'appelant bascule alors sur le rendu segment par segment.
    private static func mergedRendering(
        _ segments: [CitationSegment],
        placements: [CitationPlacement]
    ) -> AttributedString? {
        let markup = segments.map { $0.citationIndex == nil ? $0.text : sentinelMarkup }.joined()
        let parsed = markdown(markup)
        let ranges = sentinelRanges(in: parsed)
        guard ranges.count == placements.count else { return nil }

        var rendered = AttributedString()
        var cursor = parsed.startIndex
        for (range, placement) in zip(ranges, placements) {
            rendered.append(parsed[cursor..<range.lowerBound])
            if let codeAttributes = codeAttributes(of: parsed[range]) {
                rendered.append(AttributedString("[\(placement.index)]", attributes: codeAttributes))
            } else {
                rendered.append(badge(citationIndex: placement.index, needsLeadingSpace: placement.needsLeadingSpace))
            }
            cursor = range.upperBound
        }
        rendered.append(parsed[cursor..<parsed.endIndex])
        return rendered
    }

    /// Repli : chaque segment de texte analysé seul. Perd le Markdown qui
    /// enjambe une citation, mais ne peut pas échouer.
    private static func segmentwiseRendering(
        _ segments: [CitationSegment],
        placements: [CitationPlacement]
    ) -> AttributedString {
        var rendered = AttributedString()
        var remainingPlacements = placements.makeIterator()
        for segment in segments {
            if segment.citationIndex != nil, let placement = remainingPlacements.next() {
                rendered.append(badge(citationIndex: placement.index, needsLeadingSpace: placement.needsLeadingSpace))
            } else {
                rendered.append(markdown(segment.text))
            }
        }
        return rendered
    }

    /// Positions de chaque `[` + sentinelle + `]` dans le texte analysé, dans
    /// l'ordre. Une passe sur les caractères, sans réexamen.
    private static func sentinelRanges(in text: AttributedString) -> [Range<AttributedString.Index>] {
        let characters = text.characters
        var ranges: [Range<AttributedString.Index>] = []
        var previous: AttributedString.Index?
        var index = characters.startIndex

        while index < characters.endIndex {
            let next = characters.index(after: index)
            if characters[index] == sentinel,
               let opening = previous, characters[opening] == "[",
               next < characters.endIndex, characters[next] == "]" {
                let end = characters.index(after: next)
                ranges.append(opening..<end)
                previous = next
                index = end
            } else {
                previous = index
                index = next
            }
        }
        return ranges
    }

    /// Attributs du passage s'il est en code, `nil` sinon.
    private static func codeAttributes(of slice: AttributedSubstring) -> AttributeContainer? {
        guard let run = slice.runs.first(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else {
            return nil
        }
        return run.attributes
    }

    private static func badge(citationIndex: Int, needsLeadingSpace: Bool) -> AttributedString {
        var badge = AttributedString((needsLeadingSpace ? narrowNoBreakSpace : "") + "[\(citationIndex)]")
        badge.link = url(forCitationIndex: citationIndex)
        badge.font = badgeFont
        return badge
    }

    // MARK: Fiche source

    /// Sources réellement citées, dédoublonnées, dans l'ordre de première
    /// apparition — l'ordre de lecture, utile aux actions VoiceOver.
    static func citedSources(in result: CitationParseResult, sources: [SearXNGSearchResult]) -> [CitationSelection] {
        var seenIndices: Set<Int> = []
        var cited: [CitationSelection] = []
        for index in result.citationIndices {
            guard
                seenIndices.insert(index).inserted,
                let source = CitationParser.source(forCitationIndex: index, in: sources)
            else { continue }
            cited.append(CitationSelection(citationIndex: index, source: source))
        }
        return cited
    }

    /// Titre de la fiche : le titre de la source, sinon son hôte, sinon un
    /// libellé neutre. Jamais une chaîne vide (une fiche sans titre aurait
    /// l'air cassée).
    static func displayTitle(for source: SearXNGSearchResult) -> String {
        let title = collapsedWhitespace(source.title)
        if !title.isEmpty { return title }
        return displayHost(for: source) ?? untitledSourceTitle
    }

    /// « lemonde.fr » : hôte en minuscules, sans `www.`. Délègue à
    /// `SourceRanker.normalizedHost(of:)` pour ne pas dupliquer une règle
    /// qui doit rester la même partout (même rendu que le web, `getHostname`
    /// dans `Citation.tsx`).
    static func displayHost(for source: SearXNGSearchResult) -> String? {
        SourceRanker.normalizedHost(of: source.url)
    }

    /// Extrait lisible du résumé SearXNG (`content`) : blancs ramenés à une
    /// espace, coupé à `maxLength` caractères sur une fin de mot (si elle
    /// n'emporte pas plus de la moitié du texte), suivi de « … ». `nil` si
    /// rien d'utile ne reste : la fiche n'affiche alors pas de bloc vide.
    static func excerpt(from content: String?, maxLength: Int = maxExcerptLength) -> String? {
        guard let content, maxLength > 0 else { return nil }
        let collapsed = collapsedWhitespace(content)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }

        let head = collapsed.prefix(maxLength)
        var cut = head
        if let lastSpace = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: lastSpace) >= maxLength / 2 {
            cut = head[..<lastSpace]
        }
        while let last = cut.last, trailingPunctuationBeforeEllipsis.contains(last) {
            cut = cut.dropLast()
        }
        return String(cut) + "…"
    }

    /// URL ouvrable par le bouton de la fiche : http(s) avec un hôte, sinon
    /// `nil` et pas de bouton. L'URL vient d'un résultat SearXNG, donc d'une
    /// donnée externe : on ne la passe jamais telle quelle au système.
    static func openableURL(for source: SearXNGSearchResult) -> URL? {
        let trimmed = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            openableSourceSchemes.contains(scheme),
            let host = components.host,
            !host.isEmpty
        else { return nil }
        return components.url
    }

    /// Label de section de la fiche, style « ESSAIE » de la DA.
    static func sourceLabel(citationIndex: Int) -> String {
        "SOURCE \(citationIndex)"
    }

    /// Nom d'une action VoiceOver : « Source 3 : titre ».
    static func accessibilityActionName(for selection: CitationSelection) -> String {
        "Source \(selection.citationIndex) : \(displayTitle(for: selection.source))"
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
