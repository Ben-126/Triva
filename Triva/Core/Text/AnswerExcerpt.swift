//
//  AnswerExcerpt.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation

// MARK: - Aperçu d'une réponse (partagé avec FavoritesView)

/// Extrait court et lisible d'une réponse de l'assistant, pour une ligne de
/// liste : aperçu de la Bibliothèque (1.9) et extrait des Favoris (1.10).
///
/// Portage du `preview` de `src/app/favorites/page.tsx` (web), qui enchaîne une
/// dizaine de `replace` par expressions régulières puis coupe à 250
/// caractères. Même but, mais en s'appuyant sur les briques déjà testées du
/// projet plutôt qu'en réécrivant leur logique :
/// 1. `ReasoningSegmenter` retire le bloc `<think>` et isole le TL;DR. Le web
///    n'efface que les balises (`/<[^>]+>/g`) : le raisonnement d'un modèle
///    Qwen3 se retrouvait donc dans l'aperçu, en tête et souvent en anglais.
/// 2. `CitationParser` retire les marqueurs `[n]` (côté web : `/\[[\d,]+\]/g`).
/// 3. Les marqueurs de bloc Markdown sont retirés ligne par ligne, puis le
///    Markdown en ligne (gras, liens, code) est résolu par
///    `AttributedString(markdown:)`.
/// 4. `ConversationTitleBuilder` coupe sur une frontière de mot, en grappes de
///    graphèmes (jamais un emoji ni un accent coupé en deux), avec « … ».
///
/// LOGIQUE PURE, `nonisolated` : appelable depuis une vue comme depuis un test
/// non isolé. Ne lève jamais : l'entrée vient d'un modèle de langue, le pire
/// cas est un aperçu imparfait, jamais une erreur.
nonisolated enum AnswerExcerpt {
    /// 250 caractères, comme le web. La ligne de liste en montre de toute façon
    /// moins (`lineLimit`) : la borne sert surtout à ne jamais confier un texte
    /// de plusieurs kilo-octets à la mise en page de chacune des 500 lignes.
    static let defaultMaxLength = 250

    /// Fenêtre réellement analysée, prise AVANT nettoyage. Quatre fois la
    /// longueur finale : Markdown et citations retirés, il en reste presque
    /// toujours plus que `defaultMaxLength`, donc la coupe et son « … » tombent
    /// au bon endroit. Le coût reste borné quelle que soit la longueur de la
    /// réponse — seul `ReasoningSegmenter` parcourt le texte entier, en temps
    /// linéaire.
    static let analysisWindow = 1_000

    /// `nil` si la réponse ne contient aucun texte affichable.
    static func make(from answer: String, maxLength: Int = defaultMaxLength) -> String? {
        let segments = ReasoningSegmenter.segment(answer, isStreaming: false)
        let window = String(preferredText(in: segments).prefix(analysisWindow))
        let plain = inlinePlainText(blockPlainText(removingCitationMarkers(from: window)))
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ConversationTitleBuilder.title(from: plain, maxLength: maxLength)
    }

    /// Le TL;DR du mode Approfondi d'abord : une phrase écrite exprès pour
    /// résumer la réponse, le meilleur aperçu possible. Puis le corps. Le
    /// raisonnement n'est retenu qu'en dernier recours : c'est le cas d'un
    /// `<think>` jamais refermé (`ReasoningPhase.interrupted`), où il est le
    /// seul texte de la réponse — mieux vaut l'aperçu de ce texte que
    /// d'annoncer une réponse vide.
    private static func preferredText(in segments: ReasoningSegments) -> String {
        if let tldr = segments.tldr { return tldr }
        return segments.body.isEmpty ? segments.reasoning : segments.body
    }

    // MARK: Citations

    /// Ne garde que les segments de texte de `CitationParser`.
    ///
    /// `sourceCount: .max` : TOUT marqueur bien formé est retiré, y compris un
    /// `[9]` inventé par le modèle, que le chat laisse visible (écart n° 1 de
    /// `CitationParser`). Dans un aperçu, un numéro sans badge n'apporte rien,
    /// et connaître le vrai nombre de sources obligerait à charger la relation
    /// `sources` de chaque ligne : une requête SQLite par ligne.
    ///
    /// `pendingSuffix` est volontairement abandonné : c'est le `[1` qu'a pu
    /// laisser la coupe de `analysisWindow`.
    ///
    /// L'espace qui précédait un marqueur retiré disparaît devant `.`, `,` ou
    /// `)` (« fait [1]. » → « fait. »), mais pas devant `;`, `:`, `!` ou `?`,
    /// que la typographie française fait précéder d'une espace.
    private static func removingCitationMarkers(from text: String) -> String {
        let parsed = CitationParser.parse(text, sourceCount: .max)
        var result = ""
        var followsCitation = false
        for segment in parsed.segments {
            guard segment.citationIndex == nil else {
                followsCitation = true
                continue
            }
            if followsCitation, let first = segment.text.first, closingPunctuation.contains(first) {
                while result.last == " " { result.removeLast() }
            }
            result += segment.text
            followsCitation = false
        }
        return result
    }

    private static let closingPunctuation: Set<Character> = [".", ",", ")"]

    // MARK: Markdown de bloc

    /// Retire, ligne par ligne, ce que `AttributedString(markdown:)` en mode
    /// « en ligne » laisse intact (vérifié à l'exécution : `## Titre`,
    /// `- puce`, `> cite` et `<br>` ressortent tels quels) : marqueurs de
    /// titre, de liste et de citation, lignes purement structurelles (clôture
    /// de code, filet, séparateur de tableau), barres de tableau et balises
    /// HTML. Le mode Markdown complet retirerait les marqueurs de bloc, mais il
    /// ne garde aucun séparateur entre deux blocs : les mots de deux
    /// paragraphes se retrouveraient collés.
    private static func blockPlainText(_ markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isStructuralLine($0) }
            .map { strippingHTMLTags(strippingBlockMarker($0)).replacingOccurrences(of: "|", with: " ") }
            .joined(separator: "\n")
    }

    /// Clôture de code (```` ``` ````, `~~~`), filet horizontal (`---`, `***`,
    /// `___`, espacés ou non) ou séparateur de tableau (`|---|:---:|`).
    private static func isStructuralLine(_ line: String) -> Bool {
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first else { return false }
        let isRule = "-*_".contains(first) && compact.allSatisfy { $0 == first }
        let isTableSeparator = compact.contains("-") && compact.allSatisfy { "|-:".contains($0) }
        return isRule || isTableSeparator
    }

    /// Un seul marqueur de tête par ligne (citation, puis titre OU liste) :
    /// c'est ce qu'écrit un modèle, et retirer en boucle risquerait d'entamer
    /// une phrase qui commencerait légitimement par un tiret.
    private static func strippingBlockMarker(_ line: String) -> String {
        var rest = Substring(line)
        if rest.first == ">" {
            rest = rest.drop { $0 == ">" || $0 == " " }
        }
        if let afterHeading = droppingHeadingMarker(rest) {
            return String(afterHeading)
        }
        return String(droppingListMarker(rest) ?? rest)
    }

    /// `#` à `######` suivis d'une espace : « #hashtag » n'est pas un titre.
    private static func droppingHeadingMarker(_ line: Substring) -> Substring? {
        let hashCount = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashCount) else { return nil }
        let rest = line.dropFirst(hashCount)
        guard rest.first == " " else { return nil }
        return rest.dropFirst()
    }

    /// Puce (`-`, `*`, `+`) ou numéro (`12.`, `3)`) suivi d'une espace, puis une
    /// éventuelle case de tâche. `*gras*` n'est pas touché : sans espace après
    /// l'astérisque, ce n'est pas une puce.
    private static func droppingListMarker(_ line: Substring) -> Substring? {
        let rest: Substring
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            rest = line.dropFirst(2)
        } else {
            let digitCount = line.prefix { ("0"..."9").contains($0) }.count
            guard (1...9).contains(digitCount) else { return nil }
            let afterDigits = line.dropFirst(digitCount)
            guard let mark = afterDigits.first, mark == "." || mark == ")",
                  afterDigits.dropFirst().first == " " else { return nil }
            rest = afterDigits.dropFirst(2)
        }
        for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) {
            return rest.dropFirst(box.count)
        }
        return rest
    }

    /// Balises simples (`<br>`, `<sup>`, `</b>`) : une lettre doit suivre `<`,
    /// donc « a < b » ou « 3 <5 » restent intacts. Remplacées par une ESPACE et
    /// non supprimées : vérifié à l'exécution, `Ligne<br>suivante` (fréquent
    /// dans les tableaux des modèles) devenait « Lignesuivante ». Les espaces
    /// en trop sont fusionnées par `ConversationTitleBuilder` ; le prix est une
    /// espace de plus dans le rare `m<sup>2</sup>`. Expression construite dans
    /// la fonction et non en propriété statique : elle n'est évaluée que pour
    /// les rares lignes qui contiennent un `<`.
    private static func strippingHTMLTags(_ line: String) -> String {
        guard line.contains("<") else { return line }
        return line.replacing(#/<\/?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?\/?>/#, with: " ")
    }

    // MARK: Markdown en ligne

    /// Gras, italique, code, barré et liens, résolus par le même parseur et
    /// dans le même mode que `MessageBubbleView.attributedText(from:)`, avec le
    /// même repli sur le texte brut si l'analyse échoue. Pré-filtre : sans
    /// aucun caractère de syntaxe en ligne, il n'y a rien à analyser.
    private static func inlinePlainText(_ markdown: String) -> String {
        guard markdown.contains(where: { inlineSyntaxCharacters.contains($0) }) else { return markdown }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(parsed.characters)
    }

    private static let inlineSyntaxCharacters: Set<Character> = ["*", "_", "`", "[", "\\", "&", "~"]
}

// MARK: - Dates (partagé avec FavoritesView)

/// Libellés de date en français, pour les listes et le détail d'un favori.
///
/// ## Pourquoi forcer `fr_FR` plutôt que `Locale.current`
/// Toute l'interface est écrite en dur en français, mais le projet déclare
/// `developmentRegion = en` et aucune localisation française. La langue de
/// l'app, et donc celle de `Locale.current`, risque alors d'être l'anglais
/// même sur un appareil réglé en français : une date formatée avec elle
/// sortirait en « 2 hours ago » au milieu d'écrans en français. Le jour où
/// l'app sera réellement localisée (catalogue de chaînes), cette constante
/// devra redevenir `.autoupdatingCurrent`.
///
/// Le CALENDRIER, lui, reste celui de l'utilisateur (`@Environment(\.calendar)`
/// côté vue) : premier jour de la semaine et fuseau horaire sont des
/// conventions de sa région, pas de la langue de l'interface.
nonisolated enum RelativeDateLabel {
    static let locale = Locale(identifier: "fr_FR")

    /// « Maintenant », « Il y a 5 minutes », « Hier », « Avant-hier »,
    /// « La semaine dernière », « L'année dernière »…
    ///
    /// `AnchoredRelativeFormatStyle` plutôt que `RelativeFormatStyle` : il
    /// formate par rapport à une date FOURNIE et non à l'horloge. La date de
    /// référence est figée une fois par chargement de liste, pour que le
    /// libellé d'une ligne et sa section soient calculés au même instant —
    /// sinon une liste ouverte juste avant minuit pourrait afficher « Hier »
    /// dans la section « Aujourd'hui ». Les tests y gagnent le déterminisme.
    ///
    /// Une date future (horloge de l'appareil reculée depuis) est ramenée à
    /// `now` : « Maintenant » plutôt qu'un « Dans 2 heures » absurde pour une
    /// conversation passée.
    static func text(for date: Date, relativeTo now: Date, calendar: Calendar) -> String {
        Date.AnchoredRelativeFormatStyle(
            anchor: min(date, now),
            presentation: .named,
            unitsStyle: .wide,
            locale: locale,
            calendar: calendar,
            capitalizationContext: .beginningOfSentence
        )
        .format(now)
    }

    /// « 3 octobre 2026 ».
    static func longDate(_ date: Date, calendar: Calendar) -> String {
        Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .format(date)
    }
}
