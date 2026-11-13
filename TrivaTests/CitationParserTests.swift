//
//  CitationParserTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 23/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Fabriques et outils

/// Fabrique une source minimale : `CitationParser` ne lit JAMAIS le contenu
/// d'une source, seulement la TAILLE de la liste (pour les bornes) et son
/// indexation (pour le mapping). Les champs sont donc remplis de manière
/// reconnaissable, uniquement pour pouvoir vérifier qu'un indice tombe bien
/// sur la bonne entrée.
private func makeCitationSource(_ index: Int) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: "Source \(index)",
        url: "https://exemple\(index).fr/article",
        content: "Extrait \(index)",
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

private func makeCitationSources(_ count: Int) -> [SearXNGSearchResult] {
    (0..<count).map { makeCitationSource($0 + 1) }
}

/// Vrai si `text` se termine par un DÉBUT de marqueur non refermé (`[`, suivi
/// d'au moins un chiffre ASCII et d'au plus `maxCitationDigits`).
///
/// C'est l'assertion clé du streaming : ce que la vue affiche (la
/// concaténation des segments) ne doit jamais se terminer par un marqueur en
/// cours de frappe, sous peine de voir `[1` clignoter puis se changer en
/// badge.
///
/// On exige au moins UN chiffre, et pas seulement le `[` : un crochet seul en
/// fin d'affichage est légitime dans le cas imbriqué `[[1` — le premier
/// crochet y est un vrai caractère de texte, que le parseur émet pendant que
/// le second part en fragment retenu.
private func endsWithPartialCitationMarker(_ text: String) -> Bool {
    var digitCount = 0
    var cursor = text.endIndex

    while cursor > text.startIndex {
        let previous = text.index(before: cursor)
        let character = text[previous]

        if character.isASCII, character.isNumber {
            digitCount += 1
            if digitCount > CitationParser.maxCitationDigits { return false }
            cursor = previous
            continue
        }

        return character == "[" && digitCount >= 1
    }

    return false
}

// MARK: - Découpage de base

@MainActor
@Suite("CitationParser — découpage de base")
struct CitationParserBasicTests {

    @Test("Un texte sans aucun crochet donne un seul segment de texte")
    func plainTextProducesSingleSegment() {
        let result = CitationParser.parse("Une réponse sans la moindre source.", sourceCount: 3)

        #expect(result.segments.count == 1)
        #expect(result.segments.first?.kind == .text)
        #expect(result.segments.first?.text == "Une réponse sans la moindre source.")
        #expect(result.pendingSuffix.isEmpty)
        #expect(result.hasNoCitation)
    }

    @Test("Un texte vide ne produit aucun segment, pas même un segment vide")
    func emptyTextProducesNoSegment() {
        let result = CitationParser.parse("", sourceCount: 3)

        #expect(result.segments.isEmpty)
        #expect(result.pendingSuffix.isEmpty)
        #expect(result.reconstructedText.isEmpty)
        #expect(result.hasNoCitation)
    }

    @Test("Une citation isolée coupe le texte en trois segments")
    func singleCitationSplitsText() {
        let result = CitationParser.parse("Le sommet culmine à 4 805 m[2] en 2023.", sourceCount: 3)

        #expect(result.segments.count == 3)
        #expect(result.segments[0].kind == .text)
        #expect(result.segments[0].text == "Le sommet culmine à 4 805 m")
        #expect(result.segments[1].kind == .citation(index: 2))
        #expect(result.segments[1].text == "[2]")
        #expect(result.segments[2].kind == .text)
        #expect(result.segments[2].text == " en 2023.")
    }

    @Test("Le segment de citation conserve ses crochets, pas seulement le numéro")
    func citationSegmentKeepsBrackets() {
        let result = CitationParser.parse("Fait[1].", sourceCount: 1)

        #expect(result.segments[1].text == "[1]")
        #expect(result.segments[1].citationIndex == 1)
        #expect(result.segments[0].citationIndex == nil)
    }

    @Test("Des marqueurs collés ne créent aucun segment de texte vide entre eux")
    func adjacentMarkersProduceNoEmptyTextSegment() {
        let result = CitationParser.parse("[1][2][3]", sourceCount: 3)

        #expect(result.segments.count == 3)
        #expect(result.citationIndices == [1, 2, 3])
        #expect(result.segments.allSatisfy { !$0.text.isEmpty })
        #expect(result.reconstructedText == "[1][2][3]")
    }

    @Test("Une citation en tout début de texte n'est pas précédée d'un segment vide")
    func citationAtVeryStart() {
        let result = CitationParser.parse("[1] Ce point est établi.", sourceCount: 2)

        #expect(result.segments.count == 2)
        #expect(result.segments[0].kind == .citation(index: 1))
        #expect(result.segments[1].text == " Ce point est établi.")
    }

    @Test("Une citation en toute fin de texte est bien émise, sans fragment retenu")
    func citationAtVeryEnd() {
        let result = CitationParser.parse("Ce point est établi[3]", sourceCount: 3)

        #expect(result.segments.count == 2)
        #expect(result.segments[1].kind == .citation(index: 3))
        #expect(result.pendingSuffix.isEmpty)
    }

    @Test("Les identifiants de segments suivent le rang, pour un ForEach stable")
    func segmentIdentifiersFollowRank() {
        let result = CitationParser.parse("A[1] B[2] C", sourceCount: 2)

        #expect(result.segments.map(\.id) == Array(result.segments.indices))
    }

    @Test("Le même indice cité plusieurs fois est conservé tel quel")
    func repeatedIndicesArePreserved() {
        let result = CitationParser.parse("A[3] B[1] C[3]", sourceCount: 3)

        #expect(result.citationIndices == [3, 1, 3])
        #expect(result.distinctCitationIndices == [1, 3])
        #expect(!result.hasNoCitation)
    }
}

// MARK: - Faux positifs

@MainActor
@Suite("CitationParser — faux positifs")
struct CitationParserFalsePositiveTests {

    /// Chaque entrée doit rester du texte, intégralement. Les six premières
    /// sont exigées par le plan ; les trois dernières pinnent des écarts
    /// DOCUMENTÉS vis-à-vis de la version web d'origine (`[1,2]`, `[ 1 ]`) ou de l'ASCII strict
    /// (chiffres arabes-indiens).
    @Test(
        "Ces formes ne deviennent jamais des citations",
        arguments: [
            "Pour en savoir plus, [voir plus] sur le sujet.",
            "Référence [0] du document.",
            "Version [1.5] du protocole.",
            "Note [abc] de bas de page.",
            "- [x] tâche terminée",
            "- [ ] tâche à faire",
            "Consulter [la source](https://exemple.fr/page) pour le détail.",
            "Deux sources d'un coup [1,2] à la française.",
            "Avec des espaces [ 1 ] autour du numéro.",
            "Chiffres arabes-indiens [١] hors ASCII."
        ]
    )
    func staysPlainText(_ input: String) {
        let result = CitationParser.parse(input, sourceCount: 5)

        #expect(result.hasNoCitation)
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.text == input)
        #expect(result.pendingSuffix.isEmpty)
    }

    @Test("Un lien markdown numérique est écarté sur la parenthèse qui suit")
    func markdownLinkWithNumericLabel() {
        let result = CitationParser.parse("Voir [1](https://exemple.fr) en détail.", sourceCount: 3)

        #expect(result.hasNoCitation)
        #expect(result.reconstructedText == "Voir [1](https://exemple.fr) en détail.")
    }

    @Test("Une vraie citation suivie d'une parenthèse séparée reste une citation")
    func citationFollowedBySpaceThenParenthesis() {
        let result = CitationParser.parse("Établi[1] (voir aussi plus bas).", sourceCount: 3)

        #expect(result.citationIndices == [1])
    }

    @Test("Un indice hors bornes reste du texte, fondu dans le texte qui l'entoure")
    func outOfBoundsIndexStaysInsideSurroundingText() {
        let result = CitationParser.parse("Avant [9] après.", sourceCount: 3)

        #expect(result.hasNoCitation)
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.text == "Avant [9] après.")
    }

    @Test("Sans aucune source attachée, même [1] reste du texte")
    func noSourceMeansNoCitation() {
        let result = CitationParser.parse("Un fait[1].", sourceCount: 0)

        #expect(result.hasNoCitation)
        #expect(result.reconstructedText == "Un fait[1].")
    }

    @Test("Un marqueur mélangé à un indice valide : seul le valide devient citation")
    func mixedValidAndInvalidIndices() {
        let result = CitationParser.parse("A[1] B[9] C[2]", sourceCount: 3)

        #expect(result.citationIndices == [1, 2])
        #expect(result.reconstructedText == "A[1] B[9] C[2]")
    }

    @Test("Quatre chiffres passent, cinq chiffres non (borne maxCitationDigits)")
    func digitCountBoundary() {
        let withinBound = CitationParser.parse("Fait[9999].", sourceCount: 9999)
        let beyondBound = CitationParser.parse("Fait[12345].", sourceCount: 99999)

        #expect(withinBound.citationIndices == [9999])
        #expect(beyondBound.hasNoCitation)
        #expect(beyondBound.reconstructedText == "Fait[12345].")
    }

    @Test("Des crochets imbriqués laissent leur chance au marqueur intérieur")
    func nestedBracketsStillYieldInnerCitation() {
        let result = CitationParser.parse("[[1]]", sourceCount: 2)

        #expect(result.citationIndices == [1])
        #expect(result.segments.map(\.text) == ["[", "[1]", "]"])
        #expect(result.reconstructedText == "[[1]]")
    }

    @Test("Un crochet jamais refermé au milieu du texte reste affiché")
    func unclosedBracketInsideTextIsKept() {
        let result = CitationParser.parse("Un [crochet ouvert qui ne ferme jamais.", sourceCount: 3)

        #expect(result.hasNoCitation)
        #expect(result.segments.count == 1)
        #expect(result.pendingSuffix.isEmpty)
    }
}

// MARK: - Streaming

@MainActor
@Suite("CitationParser — streaming")
struct CitationParserStreamingTests {

    /// Une réponse réaliste : plusieurs citations, une paire collée, et une
    /// citation qui termine une phrase. C'est le texte balayé caractère par
    /// caractère par le test de préfixes.
    private static let streamedAnswer = """
    Le Mont-Blanc culmine à 4 805 mètres[1]. Cette altitude est réévaluée \
    tous les deux ans par des géomètres[2][3].

    La mesure de septembre 2023 fait aujourd'hui référence[3].
    """

    @Test("À chaque préfixe possible, rien n'est perdu et aucun marqueur partiel n'est affiché")
    func everyStreamingPrefixHoldsTheInvariants() {
        let answer = Self.streamedAnswer

        for length in 0...answer.count {
            let snapshot = String(answer.prefix(length))
            let result = CitationParser.parse(snapshot, sourceCount: 3)

            // 1. Invariant central : le parseur découpe, il ne réécrit pas.
            #expect(result.reconstructedText == snapshot, "Perte de texte au préfixe \(length)")

            // 2. Ce que la vue affiche ne se termine jamais par `[1` ou `[`.
            let displayed = result.segments.map(\.text).joined()
            #expect(
                !endsWithPartialCitationMarker(displayed),
                "Marqueur partiel affiché au préfixe \(length) : \(displayed.suffix(8))"
            )

            // 3. Toute citation émise est complète et dans les bornes.
            for segment in result.segments {
                guard let index = segment.citationIndex else { continue }
                #expect(segment.text == "[\(index)]")
                #expect(index >= 1 && index <= 3)
            }

            // 4. Les rangs restent alignés sur la position réelle.
            #expect(result.segments.map(\.id) == Array(result.segments.indices))
        }
    }

    @Test("Le nombre de citations ne fait que croître au fil du stream")
    func citationCountOnlyGrows() {
        let answer = Self.streamedAnswer
        var previousCount = 0

        for length in 0...answer.count {
            let result = CitationParser.parse(String(answer.prefix(length)), sourceCount: 3)
            #expect(result.citationIndices.count >= previousCount, "Régression au préfixe \(length)")
            previousCount = result.citationIndices.count
        }

        #expect(previousCount == 4)
    }

    @Test("Un marqueur tronqué est retenu au lieu d'être affiché")
    func truncatedMarkerIsHeldBack() {
        let result = CitationParser.parse("Le sommet culmine ici[1", sourceCount: 3)

        #expect(result.pendingSuffix == "[1")
        #expect(result.segments.map(\.text).joined() == "Le sommet culmine ici")
        #expect(result.hasNoCitation)
        #expect(result.reconstructedText == "Le sommet culmine ici[1")
    }

    @Test("Un crochet ouvrant seul en fin de texte est retenu lui aussi")
    func trailingOpeningBracketIsHeldBack() {
        let result = CitationParser.parse("Le sommet culmine ici[", sourceCount: 3)

        #expect(result.pendingSuffix == "[")
        #expect(result.segments.map(\.text).joined() == "Le sommet culmine ici")
    }

    @Test("Un fragment qui ne pourra jamais devenir un marqueur n'est pas retenu")
    func impossibleFragmentIsNotHeldBack() {
        let result = CitationParser.parse("Une note[abc", sourceCount: 3)

        #expect(result.pendingSuffix.isEmpty)
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.text == "Une note[abc")
    }

    @Test("Le fragment retenu se résout à l'instantané suivant")
    func heldFragmentResolvesOnNextSnapshot() {
        let held = CitationParser.parse("Fait[1", sourceCount: 3)
        let resolved = CitationParser.parse("Fait[1]", sourceCount: 3)

        #expect(held.hasNoCitation)
        #expect(resolved.citationIndices == [1])
        #expect(resolved.pendingSuffix.isEmpty)
    }

    @Test("Un fragment retenu dont l'indice finira hors bornes redevient du texte")
    func heldFragmentThatBecomesOutOfBoundsFallsBackToText() {
        let held = CitationParser.parse("Fait[9", sourceCount: 3)
        let resolved = CitationParser.parse("Fait[9]", sourceCount: 3)

        #expect(held.pendingSuffix == "[9")
        #expect(resolved.hasNoCitation)
        #expect(resolved.segments.first?.text == "Fait[9]")
    }

    @Test("Le fragment retenu, ajouté aux segments, redonne le texte d'origine")
    func pendingSuffixFlushRestoresOriginalText() {
        let snapshot = "Une phrase coupée net[2"
        let result = CitationParser.parse(snapshot, sourceCount: 3)

        // C'est exactement ce que la vue doit faire en fin de stream :
        // afficher les segments, puis relâcher le fragment en texte brut.
        #expect(result.segments.map(\.text).joined() + result.pendingSuffix == snapshot)
    }
}

// MARK: - Invariant de reconstruction

@MainActor
@Suite("CitationParser — invariant de reconstruction")
struct CitationParserRoundTripTests {

    @Test(
        "La concaténation des segments (plus le fragment retenu) redonne le texte d'origine",
        arguments: [
            "",
            "Texte sans le moindre crochet.",
            "[1]",
            "[1][2][3]",
            "Avant[1]milieu[2]après",
            "Indice hors bornes [42] au milieu.",
            "Liste markdown : - [x] fait, - [ ] à faire",
            "Lien [texte](https://exemple.fr) et citation[1].",
            "Crochets [[1]] imbriqués.",
            "Marqueur tronqué en fin de stream[3",
            "Crochet ouvrant seul en fin[",
            "Café[1] — résumé accentue\u{0301} et ligature œuf[2].",
            "Emoji composé 👨‍👩‍👧‍👦 avant citation[1], après.",
            "日本語のテキスト[2]と引用[3]。",
            "Mélange [٣] arabe-indien et [3] ASCII.",
            "[1,2] puis [ 2 ] puis [abc] puis [0] puis [1.5]",
            "\n\n[1]\n\n",
            "[[[[1]]]]"
        ]
    )
    func reconstructionIsExact(_ input: String) {
        let result = CitationParser.parse(input, sourceCount: 3)

        #expect(result.reconstructedText == input)
    }

    @Test("L'invariant tient aussi sur tous les préfixes d'un texte piégeux")
    func reconstructionHoldsOnEveryPrefixOfATrickyText() {
        let tricky = "A[1][2] B [x] tâche C [lien](url) D[9] E[[3]] F[4"

        for length in 0...tricky.count {
            let snapshot = String(tricky.prefix(length))
            let result = CitationParser.parse(snapshot, sourceCount: 3)

            #expect(result.reconstructedText == snapshot, "Perte au préfixe \(length)")
        }
    }

    @Test("La surcharge avec liste de sources se comporte comme celle avec un compte")
    func bothOverloadsAgree() {
        let text = "A[1] B[2] C[5]"
        let sources = makeCitationSources(3)

        #expect(CitationParser.parse(text, sources: sources) == CitationParser.parse(text, sourceCount: 3))
    }
}

// MARK: - Mapping indice → source

@MainActor
@Suite("CitationParser — mapping indice vers source")
struct CitationParserSourceMappingTests {

    @Test("Un indice 1-based désigne bien l'entrée correspondante de la liste")
    func oneBasedIndexResolvesToMatchingSource() {
        let sources = makeCitationSources(3)

        #expect(CitationParser.source(forCitationIndex: 1, in: sources) == sources[0])
        #expect(CitationParser.source(forCitationIndex: 2, in: sources) == sources[1])
        #expect(CitationParser.source(forCitationIndex: 3, in: sources) == sources[2])
    }

    @Test("Un indice hors de la liste renvoie nil plutôt que de planter", arguments: [0, -1, 4, 999])
    func outOfRangeIndexReturnsNil(_ index: Int) {
        let sources = makeCitationSources(3)

        #expect(CitationParser.source(forCitationIndex: index, in: sources) == nil)
    }

    @Test("Une liste vide renvoie toujours nil")
    func emptySourceListAlwaysReturnsNil() {
        #expect(CitationParser.source(forCitationIndex: 1, in: []) == nil)
    }

    @Test("Une liste plus courte que les indices analysés renvoie nil sur les indices manquants")
    func shorterListThanParsedIndices() {
        // Cas réel : un résultat analysé avec 5 sources (historique rechargé)
        // rapproché d'une liste qui n'en contient plus que 2.
        let result = CitationParser.parse("A[1] B[5]", sourceCount: 5)
        let shorterSources = makeCitationSources(2)

        #expect(result.citationIndices == [1, 5])
        #expect(CitationParser.source(forCitationIndex: 1, in: shorterSources) == shorterSources[0])
        #expect(CitationParser.source(forCitationIndex: 5, in: shorterSources) == nil)
    }

    @Test("Toutes les citations d'une analyse faite avec la même liste sont résolvables")
    func everyParsedCitationResolvesWithSameList() {
        let sources = makeCitationSources(4)
        let result = CitationParser.parse("A[1] B[4] C[2] D[7]", sources: sources)

        #expect(result.citationIndices == [1, 4, 2])
        for index in result.citationIndices {
            #expect(CitationParser.source(forCitationIndex: index, in: sources) != nil)
        }
    }
}
