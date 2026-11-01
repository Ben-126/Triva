//
//  AttachmentChunker.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation
import NaturalLanguage

/// Un fragment de pièce jointe, unité de recherche et de citation.
nonisolated struct AttachmentChunk: Sendable, Equatable {
    /// Position dans la pièce jointe (0, 1, 2…), dans l'ordre du texte.
    let index: Int
    /// Texte du fragment, recouvrement compris, sans blancs de bord.
    let text: String
    /// Pages couvertes (à partir de 1), recouvrement compris ; `nil` pour un
    /// fichier texte, qui n'a pas de pagination.
    let pageRange: ClosedRange<Int>?
}

/// Découpage d'un texte extrait en fragments recouvrants — port de
/// `splitText` (`src/lib/utils/splitText.ts`, web), appelé par `manager.ts`
/// avec `splitText(content, 512, 128)`.
///
/// DIVERGENCES ASSUMÉES avec le web :
/// - Unité de mesure : le `Character` Swift (un graphème complet), pas le
///   jeton `cl100k` de `js-tiktoken`. Aucun tokenizer BPE n'existe dans les
///   frameworks Apple, et compter en graphèmes est précisément ce qui rend
///   impossible de couper un caractère composé en deux.
/// - Frontières : hiérarchie « bloc (ligne vide) → phrase (`NLTokenizer`) →
///   mot (blanc, puis `NLTokenizer` pour les écritures sans espaces) →
///   graphème », là où le web découpe sur une regex de ponctuation. Le
///   niveau suivant n'intervient QUE pour un morceau trop long pour un
///   fragment : un paragraphe qui tient n'est jamais coupé.
/// - Blocs détectés à la main plutôt que via `NLTokenizer(unit: .paragraph)`,
///   qui coupe à CHAQUE retour à la ligne (vérifié sur macOS 27) : pour un
///   texte justifié à 80 colonnes ou un PDF, chaque ligne deviendrait un
///   « paragraphe ». Seule une ligne vide sépare deux blocs.
/// - BUG DU WEB NON REPRODUIT : si un segment dépasse à lui seul `maxTokens`,
///   la boucle de `splitText` n'avance plus (`chunkEnd` reste égal à
///   `chunkStart`) et tourne indéfiniment. Ici, chaque unité est d'abord
///   ramenée sous la taille utile d'un fragment, ce qui garantit qu'au moins
///   une unité entre dans chaque fragment : la progression est structurelle.
///
/// TAILLE PAR DÉFAUT, et pourquoi elle est liée à la recherche :
/// `NaturalLanguageSimilarityScorer` tronque chaque candidat à 1 000
/// caractères (`maxCharactersPerText`). Un fragment plus long ne serait donc
/// comparé que sur son début : sa fin serait invisible pour la recherche.
/// `maxCharacters` borne le fragment ENTIER, recouvrement compris, et le
/// défaut de 800 garde une marge sous ce plafond. Si ce plafond du scorer
/// baisse un jour, ce défaut doit baisser avec lui.
///
/// RECOUVREMENT : 150 caractères (≈ 19 %, proche des 25 % du web avec
/// 128/512). Il ne démarre JAMAIS au milieu d'un mot : il reprend la fin du
/// fragment précédent à partir d'un début de phrase si l'une tient dans la
/// fenêtre, sinon d'un début de mot, sinon il est omis. C'est là que la
/// version de `ScrapeService.splitIntoChunks` coupait arbitrairement
/// (`offsetBy: -overlap`, en plein mot).
nonisolated struct AttachmentChunker: Sendable {
    static let defaultMaxCharacters = 800
    static let defaultOverlapCharacters = 150

    let maxCharacters: Int
    let overlapCharacters: Int

    /// Paramètres ramenés dans un domaine sûr plutôt que refusés : taille au
    /// moins 1, recouvrement entre 0 et la MOITIÉ de la taille. Sans ce
    /// plafond, un recouvrement proche de la taille laisserait si peu de
    /// place au texte nouveau que chaque fragment répéterait presque tout le
    /// précédent — le coût de la recherche (linéaire en caractères indexés)
    /// exploserait pour rien.
    init(
        maxCharacters: Int = AttachmentChunker.defaultMaxCharacters,
        overlapCharacters: Int = AttachmentChunker.defaultOverlapCharacters
    ) {
        let clampedMaximum = max(1, maxCharacters)
        self.maxCharacters = clampedMaximum
        self.overlapCharacters = min(max(0, overlapCharacters), clampedMaximum / 2)
    }

    /// Texte sans pagination (fichier texte, tests).
    func chunks(for text: String) -> [AttachmentChunk] {
        chunks(for: [ExtractedTextSection(pageNumber: nil, text: text)])
    }

    /// Sections (une par page pour un PDF) assemblées en un seul texte, pour
    /// qu'un paragraphe à cheval sur deux pages puisse tenir dans un même
    /// fragment ; la page de chaque fragment est retrouvée ensuite
    /// (`SectionLayout.pageRange`). Un texte vide ou blanc donne `[]`.
    ///
    /// SYNCHRONE et linéaire en taille de texte ; appelée hors du main actor
    /// par `AttachmentPreparer`, dans la même tâche que l'extraction.
    func chunks(for sections: [ExtractedTextSection]) -> [AttachmentChunk] {
        let layout = SectionLayout(sections: sections)
        guard !layout.text.isEmpty else { return [] }

        let pass = ChunkingPass(text: layout.text)
        // Chaque unité doit tenir dans un fragment MÊME précédée du plus long
        // recouvrement possible : c'est la garantie de progression.
        let units = pass.units(maxCharacters: maxCharacters - overlapCharacters)
        return assemble(units, pass: pass, layout: layout)
    }

    // MARK: - Assemblage

    /// Remplissage glouton : chaque fragment reprend un recouvrement pris dans
    /// le CONTENU du précédent (jamais dans son propre recouvrement, sinon les
    /// reprises s'empileraient d'un fragment à l'autre), puis accumule des
    /// unités entières tant que le total reste sous `maxCharacters`.
    private func assemble(_ units: [ChunkUnit], pass: ChunkingPass, layout: SectionLayout) -> [AttachmentChunk] {
        var chunks: [AttachmentChunk] = []
        var cursor = 0
        var previousContent: Range<String.Index>?

        while cursor < units.count {
            var overlapStart = previousContent.flatMap { pass.overlapStart(in: $0, maxCharacters: overlapCharacters) }
            let overlapCount = overlapStart.map { pass.text[$0..<units[cursor].range.lowerBound].count } ?? 0

            var end = Self.contentEnd(of: units, from: cursor, budget: maxCharacters - overlapCount)
            if end == cursor {
                // Inatteignable par construction (unité ≤ taille − recouvrement
                // maximal) ; filet qui préfère sacrifier le recouvrement plutôt
                // que dépasser la taille ou boucler sans avancer.
                overlapStart = nil
                end = max(cursor + 1, Self.contentEnd(of: units, from: cursor, budget: maxCharacters))
            }

            let content = units[cursor].range.lowerBound..<units[end - 1].range.upperBound
            let chunkRange = (overlapStart ?? content.lowerBound)..<content.upperBound
            if let chunk = makeChunk(covering: chunkRange, index: chunks.count, in: pass.text, layout: layout) {
                chunks.append(chunk)
            }

            previousContent = content
            cursor = end
        }

        return chunks
    }

    /// Indice (exclusif) de la dernière unité qui tient dans `budget`.
    private static func contentEnd(of units: [ChunkUnit], from start: Int, budget: Int) -> Int {
        var end = start
        var used = 0
        while end < units.count, used + units[end].characterCount <= budget {
            used += units[end].characterCount
            end += 1
        }
        return end
    }

    private func makeChunk(
        covering range: Range<String.Index>,
        index: Int,
        in text: String,
        layout: SectionLayout
    ) -> AttachmentChunk? {
        guard let trimmed = Self.trimmedRange(range, in: text) else { return nil }
        return AttachmentChunk(index: index, text: String(text[trimmed]), pageRange: layout.pageRange(covering: trimmed))
    }

    /// Sous-plage sans blancs de bord, ou `nil` si elle n'est faite que de
    /// blancs. Travaille sur des `Character` : les bornes restent alignées
    /// sur des graphèmes.
    private static func trimmedRange(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace {
            lower = text.index(after: lower)
        }
        while upper > lower, text[text.index(before: upper)].isWhitespace {
            upper = text.index(before: upper)
        }
        return lower < upper ? lower..<upper : nil
    }
}

// MARK: - Unités de découpage

/// Morceau contigu du texte, déjà ramené sous la taille utile d'un fragment.
/// Le compte de caractères est mémorisé : le recalculer à chaque essai
/// d'assemblage rendrait le découpage quadratique.
nonisolated private struct ChunkUnit {
    let range: Range<String.Index>
    let characterCount: Int
}

/// Niveaux de frontière, du plus naturel au plus brutal.
nonisolated private enum SplitLevel {
    /// Phrases selon `NLTokenizer`, qui coupe aussi à chaque retour à la
    /// ligne (règle Unicode UAX #29, vérifiée) : une ligne de CSV ou de PDF
    /// est donc une phrase à part entière.
    case sentence
    /// Débuts de mot précédés d'un blanc : la définition la plus sûre pour
    /// les écritures à espaces. Une URL n'y est jamais coupée, alors que
    /// `NLTokenizer` la découpe en `https`, `ex`, `com`… (vérifié).
    case whitespace
    /// Mots selon `NLTokenizer`, pour les écritures sans espaces (japonais,
    /// chinois), où le niveau précédent ne trouve aucune frontière.
    case word
    /// Dernier recours pour un « mot » plus long qu'un fragment (URL
    /// géante, base64) : coupe franche, mais sur une frontière de graphème.
    case character

    var finer: SplitLevel? {
        switch self {
        case .sentence: return .whitespace
        case .whitespace: return .word
        case .word: return .character
        case .character: return nil
        }
    }
}

/// Contexte d'UN découpage. `NLTokenizer` est une classe non `Sendable` :
/// les deux tokenizers sont créés, utilisés et abandonnés pendant l'appel
/// synchrone de `AttachmentChunker.chunks(for:)`, sans jamais traverser de
/// frontière d'isolation (même raisonnement que `detectLanguage` dans
/// `NaturalLanguageSimilarityScorer`). Leur `string` est posé UNE fois sur le
/// texte entier : toutes les plages manipulées sont des index de ce texte.
nonisolated private struct ChunkingPass {
    let text: String
    private let sentenceTokenizer: NLTokenizer
    private let wordTokenizer: NLTokenizer

    init(text: String) {
        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        let words = NLTokenizer(unit: .word)
        words.string = text

        self.text = text
        sentenceTokenizer = sentences
        wordTokenizer = words
    }

    /// Blocs, puis raffinement de chaque bloc trop long.
    func units(maxCharacters: Int) -> [ChunkUnit] {
        let whole = text.startIndex..<text.endIndex
        return pieces(of: whole, cutAt: blockStarts()).flatMap {
            refine($0, level: .sentence, maxCharacters: maxCharacters)
        }
    }

    /// Point de départ du recouvrement : le PREMIER début de phrase situé
    /// dans les `maxCharacters` derniers caractères du contenu précédent,
    /// sinon le premier début de mot, sinon `nil` (pas de recouvrement plutôt
    /// qu'un mot coupé). « Premier » = le recouvrement le plus long possible.
    func overlapStart(in content: Range<String.Index>, maxCharacters: Int) -> String.Index? {
        guard maxCharacters > 0 else { return nil }
        let windowStart = text.index(content.upperBound, offsetBy: -maxCharacters, limitedBy: content.lowerBound)
            ?? content.lowerBound

        for level in [SplitLevel.sentence, .whitespace, .word] {
            let start = boundaryCandidates(in: content, at: level).first {
                $0 >= windowStart && $0 < content.upperBound && isCharacterBoundary($0)
            }
            if let start { return start }
        }
        return nil
    }

    // MARK: Raffinement

    private func refine(_ range: Range<String.Index>, level: SplitLevel, maxCharacters: Int) -> [ChunkUnit] {
        let count = text[range].count
        guard count > maxCharacters else { return [ChunkUnit(range: range, characterCount: count)] }
        guard let finerLevel = level.finer else { return hardSplit(range, maxCharacters: maxCharacters) }

        let parts = pieces(of: range, cutAt: cutPoints(in: range, at: level))
        return parts.flatMap { refine($0, level: finerLevel, maxCharacters: maxCharacters) }
    }

    /// Frontières STRICTEMENT intérieures à la plage, sur un graphème. Le
    /// filtre est indispensable : `NLTokenizer.tokens(for:)` renvoie le jeton
    /// ENTIER qui chevauche le début de la plage, donc un début situé AVANT
    /// elle (vérifié : une plage ouverte au caractère 10 renvoie une phrase
    /// commençant à 0).
    private func cutPoints(in range: Range<String.Index>, at level: SplitLevel) -> [String.Index] {
        boundaryCandidates(in: range, at: level).filter {
            $0 > range.lowerBound && $0 < range.upperBound && isCharacterBoundary($0)
        }
    }

    private func boundaryCandidates(in range: Range<String.Index>, at level: SplitLevel) -> [String.Index] {
        switch level {
        case .sentence:
            return sentenceTokenizer.tokens(for: range).map(\.lowerBound)
        case .whitespace:
            return wordStartsAfterWhitespace(in: range)
        case .word:
            return wordTokenizer.tokens(for: range).map(\.lowerBound)
        case .character:
            return []
        }
    }

    /// `NLTokenizer` calcule en UTF-16 (via `NSString`) : rien ne garantit
    /// formellement que ses bornes tombent entre deux graphèmes. Une borne
    /// qui tomberait au milieu d'un « é » décomposé ou d'un emoji composé est
    /// écartée — c'est ce filtre, pas la bonne volonté du tokenizer, qui rend
    /// la coupe d'un caractère impossible.
    private func isCharacterBoundary(_ index: String.Index) -> Bool {
        String.Index(index, within: text) != nil
    }

    private func wordStartsAfterWhitespace(in range: Range<String.Index>) -> [String.Index] {
        var starts: [String.Index] = []
        var previousIsWhitespace = false
        for index in text[range].indices {
            let isWhitespace = text[index].isWhitespace
            if previousIsWhitespace && !isWhitespace {
                starts.append(index)
            }
            previousIsWhitespace = isWhitespace
        }
        return starts
    }

    /// Coupe franche tous les `maxCharacters` graphèmes. `index(_:offsetBy:)`
    /// avance de `Character` en `Character` : chaque borne est un graphème.
    private func hardSplit(_ range: Range<String.Index>, maxCharacters: Int) -> [ChunkUnit] {
        var units: [ChunkUnit] = []
        var start = range.lowerBound
        while start < range.upperBound {
            let end = text.index(start, offsetBy: maxCharacters, limitedBy: range.upperBound) ?? range.upperBound
            units.append(ChunkUnit(range: start..<end, characterCount: text[start..<end].count))
            start = end
        }
        return units
    }

    // MARK: Blocs

    /// Début de chaque bloc qui suit au moins une ligne vide (deux fins de
    /// ligne séparées seulement par des blancs). `Character.isNewline`
    /// reconnaît aussi `\r\n`, qui est UN seul `Character` en Swift.
    private func blockStarts() -> [String.Index] {
        var starts: [String.Index] = []
        var newlinesSinceText = 0
        for index in text.indices {
            let character = text[index]
            if character.isNewline {
                newlinesSinceText += 1
            } else if !character.isWhitespace {
                if newlinesSinceText >= 2 {
                    starts.append(index)
                }
                newlinesSinceText = 0
            }
        }
        return starts
    }

    /// Découpe sans perte : la concaténation des morceaux redonne exactement
    /// la plage, blancs compris (ils restent attachés à la fin du morceau
    /// qui les précède).
    private func pieces(of range: Range<String.Index>, cutAt cuts: [String.Index]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = range.lowerBound
        for cut in cuts where cut > start && cut < range.upperBound {
            result.append(start..<cut)
            start = cut
        }
        result.append(start..<range.upperBound)
        return result
    }
}

// MARK: - Pagination

/// Texte assemblé à partir des sections, et début de chaque section dans ce
/// texte, pour retrouver la page d'un fragment. Les sections blanches sont
/// écartées (page blanche d'un PDF) ; les autres sont séparées par une ligne
/// vide, ce qui fait d'un saut de page une frontière de bloc.
nonisolated private struct SectionLayout {
    private static let separator = "\n\n"

    let text: String
    private let sectionStarts: [String.Index]
    private let pageNumbers: [Int?]

    init(sections: [ExtractedTextSection]) {
        let kept = sections.compactMap { section -> ExtractedTextSection? in
            let trimmed = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : ExtractedTextSection(pageNumber: section.pageNumber, text: trimmed)
        }
        let joined = kept.map(\.text).joined(separator: Self.separator)

        // Positions calculées en octets UTF-8 une fois le texte final
        // construit, pour ne jamais conserver un index d'une chaîne encore
        // en cours de modification. Chaque début de section suit un `\n` (ou
        // ouvre le texte), donc tombe forcément entre deux graphèmes.
        var starts: [String.Index] = []
        var offset = 0
        for section in kept {
            starts.append(joined.utf8.index(joined.utf8.startIndex, offsetBy: offset))
            offset += section.text.utf8.count + Self.separator.utf8.count
        }

        text = joined
        sectionStarts = starts
        pageNumbers = kept.map(\.pageNumber)
    }

    /// Plus petite et plus grande page des sections que la plage touche ;
    /// `nil` si aucune n'a de numéro (fichier texte).
    func pageRange(covering range: Range<String.Index>) -> ClosedRange<Int>? {
        let pages = sectionStarts.indices.compactMap { position -> Int? in
            let start = sectionStarts[position]
            let end = position + 1 < sectionStarts.count ? sectionStarts[position + 1] : text.endIndex
            return start < range.upperBound && range.lowerBound < end ? pageNumbers[position] : nil
        }
        guard let first = pages.min(), let last = pages.max() else { return nil }
        return first...last
    }
}
