//
//  TextSimilarityScoringTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 16/09/2026.
//

import Testing
import Foundation
import NaturalLanguage
@testable import Triva

/// Fournisseur de vecteurs factice : aucun modèle système, donc des scores
/// entièrement calculables à la main. Sert surtout à faire s'exécuter le
/// chemin de repli, qui ne s'exécuterait JAMAIS autrement — sur toute machine
/// de développement, le français et l'anglais ont un modèle de phrase.
///
/// `isSupported` est un booléen et non un ensemble de langues : le test n'a
/// pas à parier sur la langue que `NLLanguageRecognizer` va détecter.
private struct MockVectorProvider: SentenceVectorProviding {
    var isSupported: Bool = true
    /// Texte exact -> vecteur. Un texte absent simule un texte non
    /// embeddable (l'API renvoie `nil` dans ce cas, vérifié sur chaîne vide).
    var vectors: [String: [Double]] = [:]

    func supportsSentenceEmbedding(for language: NLLanguage) async -> Bool {
        isSupported
    }

    func vector(for text: String, language: NLLanguage) async -> [Double]? {
        vectors[text]
    }
}

@MainActor
@Suite("TextVectorMath")
struct TextVectorMathTests {
    @Test("Vecteurs identiques : cosinus = 1")
    func cosineOfIdenticalVectors() {
        let vector = [1.0, 2.0, 3.0]
        #expect(TextVectorMath.cosine(vector, vector)! == 1.0)
    }

    @Test("Vecteurs orthogonaux : cosinus = 0")
    func cosineOfOrthogonalVectors() {
        #expect(TextVectorMath.cosine([1, 0], [0, 1])! == 0.0)
    }

    @Test("Vecteurs opposés : cosinus = -1 (valeur brute, hors contrat [0,1])")
    func cosineOfOppositeVectors() {
        #expect(TextVectorMath.cosine([1, 2], [-1, -2])! == -1.0)
    }

    @Test("Dimensions différentes : nil — c'est le garde-fou du piège 512 (anglais) / 640 (français)")
    func cosineRejectsMismatchedDimensions() {
        #expect(TextVectorMath.cosine([1, 2, 3], [1, 2]) == nil)
    }

    @Test("Vecteurs vides : nil")
    func cosineRejectsEmptyVectors() {
        #expect(TextVectorMath.cosine([], []) == nil)
    }

    @Test("Norme nulle : 0, comme computeSimilarity.ts")
    func cosineWithZeroNorm() {
        #expect(TextVectorMath.cosine([0, 0], [1, 1])! == 0.0)
        #expect(TextVectorMath.cosine([0, 0], [0, 0])! == 0.0)
    }

    @Test("Valeur connue : cosinus de [1,0] et [1,1] vaut 1/√2")
    func cosineOnKnownValue() {
        let expected = 1 / 2.0.squareRoot()
        #expect(abs(TextVectorMath.cosine([1, 0], [1, 1])! - expected) < 1e-12)
    }

    @Test("Clamp : les négatifs tombent à 0, pas à 0,5 (pas de remise à l'échelle affine)")
    func clampSquashesNegatives() {
        #expect(TextVectorMath.clampedToUnitRange(-1) == 0)
        #expect(TextVectorMath.clampedToUnitRange(-0.28) == 0)
        #expect(TextVectorMath.clampedToUnitRange(0) == 0)
    }

    @Test("Clamp : les valeurs valides passent, le dépassement est ramené à 1")
    func clampKeepsValidValues() {
        #expect(TextVectorMath.clampedToUnitRange(0.42) == 0.42)
        #expect(TextVectorMath.clampedToUnitRange(1) == 1)
        #expect(TextVectorMath.clampedToUnitRange(1.0000001) == 1)
    }

    @Test("Clamp : NaN et infini donnent 0, jamais une valeur hors contrat")
    func clampRejectsNonFiniteValues() {
        #expect(TextVectorMath.clampedToUnitRange(.nan) == 0)
        #expect(TextVectorMath.clampedToUnitRange(.infinity) == 0)
        #expect(TextVectorMath.clampedToUnitRange(-.infinity) == 0)
    }

    // MARK: - Exactitude au bit près (régression)
    //
    // Ces deux tests protègent un choix d'implémentation précis : diviser par
    // `√(‖a‖²·‖b‖²)` et NON par `√‖a‖² × √‖b‖²`. Les deux écritures sont
    // équivalentes en maths, pas en flottant — la seconde rendait
    // 0,999999999999999 8 au lieu de 1 sur environ un vecteur sur deux.
    // Sans ces cas, une « simplification » future rétablirait l'ancienne
    // écriture sans qu'aucun test ne bronche, et la borne haute du score
    // cesserait silencieusement d'être atteignable.

    /// Vecteurs choisis pour couvrir les pièges d'arrondi : entiers, décimaux
    /// non représentables en binaire, échelles très différentes, dimension 1.
    private static let identityProbes: [[Double]] = [
        [1, 2, 3],
        [0.1, 0.2, 0.3],
        [3.7],
        [1e-8, 5e-9, 2.5e-8],
        [1e6, 2.5e5, 3.75e6],
        [2.0986122886681098, 1.0],
        [0.3, 0.7, 0.1, 0.9, 0.42, 0.58]
    ]

    @Test("Un vecteur comparé à lui-même vaut EXACTEMENT 1, sans tolérance")
    func cosineOfIdentityIsExactlyOne() {
        for vector in Self.identityProbes {
            #expect(TextVectorMath.cosine(vector, vector) == 1.0)
        }
    }

    @Test("Un vecteur comparé à son opposé vaut EXACTEMENT -1, sans tolérance")
    func cosineOfOppositeIsExactlyMinusOne() {
        for vector in Self.identityProbes {
            #expect(TextVectorMath.cosine(vector, vector.map { -$0 }) == -1.0)
        }
    }

    @Test("Colinéarité : un vecteur et son multiple positif valent exactement 1")
    func cosineOfPositiveMultipleIsExactlyOne() {
        #expect(TextVectorMath.cosine([1, 2, 3], [2, 4, 6]) == 1.0)
        #expect(TextVectorMath.cosine([0.5, 1.5], [5, 15]) == 1.0)
    }
}

@MainActor
@Suite("LexicalSimilarityScorer")
struct LexicalSimilarityScorerTests {
    private let scorer = LexicalSimilarityScorer()

    // MARK: - Tokenisation

    @Test("Tokenisation : ponctuation retirée, casse et accents normalisés, mots vides filtrés")
    func tokenizeNormalizesAndFilters() {
        let tokens = LexicalSimilarityScorer.tokenize("L'intelligence artificielle, c'est GÉNIAL !")
        #expect(tokens == ["intelligence", "artificielle", "genial"])
    }

    @Test("Tokenisation : l'élision française est recoupée, apostrophe droite comme typographique")
    func tokenizeSplitsFrenchElision() {
        #expect(LexicalSimilarityScorer.tokenize("l'univers") == ["univers"])
        #expect(LexicalSimilarityScorer.tokenize("l\u{2019}univers") == ["univers"])
    }

    @Test("Tokenisation : un texte de pure ponctuation ne produit aucun jeton")
    func tokenizeDropsPunctuationOnlyText() {
        #expect(LexicalSimilarityScorer.tokenize("--- !!! ?? «»").isEmpty)
    }

    @Test("Pondération sous-linéaire : 3 occurrences valent 1 + ln(3), pas 3")
    func weightedCountsAreSublinear() {
        let weights = LexicalSimilarityScorer.weightedTokenCounts(of: "Chat chat CHAT")
        #expect(weights.count == 1)
        #expect(abs(weights["chat"]! - (1 + log(3.0))) < 1e-12)
    }

    // MARK: - Propriétés de la mesure

    @Test("Identité : un texte comparé à lui-même vaut exactement 1")
    func identityScoresOne() async {
        let text = "TypeScript ajoute un typage statique à JavaScript"
        #expect(await scorer.similarity(between: text, and: text) == 1.0)
    }

    @Test("Disjonction : aucun mot porteur commun donne exactement 0")
    func disjointTextsScoreZero() async {
        let score = await scorer.similarity(
            between: "compilateur TypeScript",
            and: "tarte pommes cannelle"
        )
        #expect(score == 0.0)
    }

    @Test("Symétrie : inverser les deux textes ne change pas le score")
    func measureIsSymmetric() async {
        let a = "le compilateur TypeScript vérifie les types"
        let b = "TypeScript compile vers du JavaScript"
        let forward = await scorer.similarity(between: a, and: b)
        let backward = await scorer.similarity(between: b, and: a)
        #expect(forward == backward)
        #expect(forward > 0)
    }

    @Test("Insensibilité à la casse")
    func measureIgnoresCase() async {
        let reference = "Machine Learning"
        #expect(await scorer.similarity(between: reference, and: "MACHINE LEARNING") == 1.0)
        #expect(await scorer.similarity(between: reference, and: "machine learning") == 1.0)
    }

    @Test("Insensibilité aux diacritiques")
    func measureIgnoresDiacritics() async {
        #expect(await scorer.similarity(between: "élève intérêt", and: "eleve interet") == 1.0)
    }

    @Test("Identité EXACTE sur des textes variés : le scorer lexical a sa propre division")
    func identityIsExactOnVariedTexts() async {
        // `LexicalSimilarityScorer` ne passe PAS par `TextVectorMath.cosine` :
        // il divise lui-même. Corriger l'arrondi dans `TextVectorMath` seul
        // n'aurait donc rien changé ici — d'où ce test dédié, qui couvre des
        // longueurs et des répétitions différentes (le poids `1 + ln(n)`
        // produit des irrationnels, terrain idéal pour l'erreur d'arrondi).
        let texts = [
            "TypeScript",
            "TypeScript ajoute un typage statique à JavaScript",
            "chat chat chat chien chien oiseau",
            "photosynthèse plante lumière glucose énergie chimique conversion",
            String(repeating: "vecteur similarité cosinus ", count: 40)
        ]

        for text in texts {
            #expect(await scorer.similarity(between: text, and: text) == 1.0)
        }
    }

    @Test("Textes vides : 0 dans les trois combinaisons possibles")
    func emptyTextsScoreZero() async {
        #expect(await scorer.similarity(between: "", and: "TypeScript") == 0.0)
        #expect(await scorer.similarity(between: "TypeScript", and: "") == 0.0)
        #expect(await scorer.similarity(between: "", and: "") == 0.0)
    }

    @Test("Texte réduit à des mots vides : 0 même contre lui-même, comportement documenté")
    func stopWordOnlyTextScoresZero() async {
        let stopWordsOnly = "de la et le les des"
        #expect(await scorer.similarity(between: stopWordsOnly, and: stopWordsOnly) == 0.0)
        #expect(await scorer.similarity(between: stopWordsOnly, and: "TypeScript compile") == 0.0)
    }

    @Test("Ponctuation seule : 0")
    func punctuationOnlyScoresZero() async {
        #expect(await scorer.similarity(between: "!!! ???", and: "TypeScript") == 0.0)
    }

    @Test("Texte très long : le score reste borné et l'extrait pertinent devance le hors-sujet")
    func veryLongTextStaysBounded() async {
        let relevant = String(repeating: "TypeScript apporte un typage statique. ", count: 500)
        let irrelevant = String(repeating: "La tarte aux pommes cuit au four. ", count: 500)
        let scores = await scorer.similarities(
            of: "typage statique TypeScript",
            against: [relevant, irrelevant]
        )

        #expect(scores.count == 2)
        #expect(scores.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(scores[0] > scores[1])
        #expect(scores[1] == 0)
    }

    @Test("Bourrage de mots-clés : la pondération sous-linéaire donne la valeur exacte attendue")
    func keywordStuffingIsDampened() async {
        // "chien" pèse 1 des deux côtés ; le candidat contient 10 fois
        // "chat" (poids 1 + ln 10) et 1 fois "chien" (poids 1).
        // cos = 1 / √((1 + ln10)² + 1²)
        let stuffed = String(repeating: "chat ", count: 10) + "chien"
        let expected = 1 / (pow(1 + log(10.0), 2) + 1).squareRoot()
        let score = await scorer.similarity(between: "chien", and: stuffed)
        #expect(abs(score - expected) < 1e-12)
    }

    @Test("Pertinence : l'extrait qui parle du sujet marque plus que celui qui n'en parle pas")
    func relevantCandidateOutranksIrrelevantOne() async {
        let scores = await scorer.similarities(
            of: "différence entre JavaScript et TypeScript",
            against: [
                "TypeScript est un sur-ensemble typé de JavaScript",
                "TypeScript ajoute des types, JavaScript reste dynamique",
                "Recette de tarte aux pommes de grand-mère"
            ]
        )

        #expect(scores[0] > scores[2])
        #expect(scores[1] > scores[2])
        #expect(scores[2] == 0)
    }

    // MARK: - Contrat du protocole

    @Test("Le tableau renvoyé a exactement autant d'éléments que de candidats, dans l'ordre")
    func returnsOneScorePerCandidate() async {
        let candidates = ["TypeScript", "", "   ", "JavaScript et TypeScript", "pommes"]
        let scores = await scorer.similarities(of: "TypeScript", against: candidates)

        #expect(scores.count == candidates.count)
        #expect(scores.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(scores[1] == 0)
        #expect(scores[2] == 0)
    }

    @Test("Liste de candidats vide : tableau vide, jamais de crash")
    func emptyCandidateListReturnsEmptyArray() async {
        #expect(await scorer.similarities(of: "TypeScript", against: []).isEmpty)
    }

    @Test("Le score d'une paire ne dépend pas de la taille du lot — propriété clé du protocole")
    func scoreIsIndependentOfBatchSize() async {
        let reference = "typage statique TypeScript"
        let candidate = "TypeScript ajoute un typage statique à JavaScript"

        let pairwise = await scorer.similarity(between: reference, and: candidate)
        let alone = await scorer.similarities(of: reference, against: [candidate])[0]
        let inLargeBatch = await scorer.similarities(
            of: reference,
            against: [candidate, "pommes", "météo Bretagne", "cours de piano", "TypeScript"]
        )[0]

        #expect(pairwise == alone)
        #expect(pairwise == inLargeBatch)
    }

    // MARK: - rankedMatches

    @Test("rankedMatches : tri décroissant, index d'origine conservé, limite respectée")
    func rankedMatchesSortsAndLimits() async {
        let candidates = [
            "Recette de tarte aux pommes",
            "TypeScript ajoute un typage statique",
            "Les prévisions météo de demain",
            "Le typage statique de TypeScript évite des erreurs"
        ]
        let matches = await scorer.rankedMatches(
            of: "typage statique TypeScript",
            against: candidates,
            limit: 2
        )

        #expect(matches.count == 2)
        #expect(matches[0].score >= matches[1].score)
        #expect(Set(matches.map(\.index)) == [1, 3])
        #expect(matches.allSatisfy { candidates[$0.index] == $0.text })
    }

    @Test("rankedMatches : à score égal, l'ordre d'origine est conservé (tri déterministe)")
    func rankedMatchesIsStableOnTies() async {
        // Trois candidats totalement hors-sujet : tous à 0, donc à égalité.
        let matches = await scorer.rankedMatches(
            of: "TypeScript",
            against: ["pommes", "poires", "cerises"],
            limit: 3
        )

        #expect(matches.map(\.index) == [0, 1, 2])
        #expect(matches.allSatisfy { $0.score == 0 })
    }

    @Test("rankedMatches : limite nulle ou candidats vides donnent une liste vide")
    func rankedMatchesHandlesDegenerateInput() async {
        #expect(await scorer.rankedMatches(of: "TypeScript", against: ["TypeScript"], limit: 0).isEmpty)
        #expect(await scorer.rankedMatches(of: "TypeScript", against: [], limit: 5).isEmpty)
    }
}

@MainActor
@Suite("NaturalLanguageSimilarityScorer")
struct NaturalLanguageSimilarityScorerTests {
    // MARK: - Repli (chemin impossible à atteindre avec le vrai modèle)

    @Test("Aucun modèle pour la langue : le lot entier repasse par le repli, au score près")
    func fallsBackEntirelyWhenNoModelIsAvailable() async {
        let fallback = LexicalSimilarityScorer()
        let scorer = NaturalLanguageSimilarityScorer(
            vectorProvider: MockVectorProvider(isSupported: false),
            fallback: fallback
        )

        let reference = "différence entre JavaScript et TypeScript"
        let candidates = [
            "TypeScript est un sur-ensemble typé de JavaScript",
            "Recette de tarte aux pommes de grand-mère"
        ]

        let native = await scorer.similarities(of: reference, against: candidates)
        let lexical = await fallback.similarities(of: reference, against: candidates)
        #expect(native == lexical)
    }

    @Test("Référence non embeddable : repli complet, et non un tableau de zéros")
    func fallsBackWhenReferenceHasNoVector() async {
        let fallback = LexicalSimilarityScorer()
        // Le fournisseur ne connaît que le candidat, pas la référence.
        let provider = MockVectorProvider(
            isSupported: true,
            vectors: ["TypeScript est un sur-ensemble typé de JavaScript": [1, 0, 0]]
        )
        let scorer = NaturalLanguageSimilarityScorer(
            vectorProvider: provider,
            fallback: fallback,
            minimumLanguageConfidence: 0
        )

        let reference = "différence entre JavaScript et TypeScript"
        let candidates = ["TypeScript est un sur-ensemble typé de JavaScript"]

        let native = await scorer.similarities(of: reference, against: candidates)
        let lexical = await fallback.similarities(of: reference, against: candidates)
        #expect(native == lexical)
    }

    // MARK: - Chemin natif, vecteurs entièrement contrôlés

    @Test("Vecteurs contrôlés : cosinus exact, candidat non embeddable à 0, négatif écrasé à 0")
    func scoresControlledVectorsExactly() async {
        let reference = "requête de référence en français pour la détection"
        let identical = "candidat identique en direction"
        let orthogonal = "candidat orthogonal en direction"
        let opposite = "candidat opposé en direction"
        let unembeddable = "candidat que le modèle ne sait pas représenter"

        let provider = MockVectorProvider(
            isSupported: true,
            vectors: [
                reference: [1, 0],
                identical: [2, 0],
                orthogonal: [0, 1],
                opposite: [-1, 0]
            ]
        )
        let scorer = NaturalLanguageSimilarityScorer(
            vectorProvider: provider,
            minimumLanguageConfidence: 0
        )

        let scores = await scorer.similarities(
            of: reference,
            against: [identical, orthogonal, opposite, unembeddable]
        )

        #expect(scores == [1, 0, 0, 0])
    }

    @Test("Dimensions incompatibles entre deux vecteurs : 0 pour ce candidat, pas de score fantaisiste")
    func mismatchedDimensionsScoreZero() async {
        let reference = "requête de référence en français pour la détection"
        let candidate = "candidat renvoyé dans un espace de dimension différente"

        let provider = MockVectorProvider(
            isSupported: true,
            vectors: [reference: [1, 0], candidate: [1, 0, 0]]
        )
        let scorer = NaturalLanguageSimilarityScorer(
            vectorProvider: provider,
            minimumLanguageConfidence: 0
        )

        #expect(await scorer.similarities(of: reference, against: [candidate]) == [0])
    }

    @Test("Référence vide : zéros, un par candidat")
    func emptyReferenceScoresZero() async {
        let scorer = NaturalLanguageSimilarityScorer(vectorProvider: MockVectorProvider())
        #expect(await scorer.similarities(of: "   ", against: ["TypeScript", "pommes"]) == [0, 0])
    }

    @Test("Liste de candidats vide : tableau vide")
    func emptyCandidateListReturnsEmptyArray() async {
        let scorer = NaturalLanguageSimilarityScorer(vectorProvider: MockVectorProvider())
        #expect(await scorer.similarities(of: "TypeScript", against: []).isEmpty)
    }

    // MARK: - Troncature

    @Test("Troncature : coupe au dernier blanc, jamais en plein milieu d'un mot")
    func truncationCutsOnWordBoundary() {
        #expect(NaturalLanguageSimilarityScorer.truncated("abc def ghi", to: 100) == "abc def ghi")
        #expect(NaturalLanguageSimilarityScorer.truncated("abc def ghi", to: 9) == "abc def")
        #expect(NaturalLanguageSimilarityScorer.truncated("abcdefghij", to: 4) == "abcd")
        #expect(NaturalLanguageSimilarityScorer.truncated("abc", to: 0) == "")
    }

    // MARK: - Propriétés avec le vrai modèle système
    //
    // Ces tests ne dépendent d'AUCUNE valeur exacte ni de la présence d'un
    // asset : si le modèle de phrase manque sur la machine, le scorer bascule
    // sur le repli lexical, qui satisfait exactement les mêmes propriétés.
    // C'est la seule façon d'avoir une suite verte partout.

    @Test("Vrai modèle : tous les scores restent dans [0, 1], un par candidat")
    func systemScorerStaysWithinContract() async {
        let scorer = NaturalLanguageSimilarityScorer()
        let candidates = [
            "TypeScript est un sur-ensemble typé de JavaScript qui compile vers du JavaScript standard.",
            "La recette de la tarte aux pommes de ma grand-mère se fait avec une pâte brisée maison.",
            "",
            "Les prévisions météo pour demain annoncent de la pluie sur toute la Bretagne."
        ]

        let scores = await scorer.similarities(
            of: "différence entre JavaScript et TypeScript",
            against: candidates
        )

        #expect(scores.count == candidates.count)
        #expect(scores.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(scores[2] == 0)
    }

    @Test("Vrai modèle : un texte est toujours au moins aussi proche de lui-même que d'un autre")
    func systemScorerIsMaximalOnIdentity() async {
        let scorer = NaturalLanguageSimilarityScorer()
        let text = "TypeScript ajoute un système de types statiques à JavaScript."
        let other = "La recette de la tarte aux pommes de ma grand-mère."

        let selfScore = await scorer.similarity(between: text, and: text)
        let otherScore = await scorer.similarity(between: text, and: other)

        #expect(selfScore >= otherScore)
        #expect(selfScore > 0)
    }

    @Test("Vrai modèle : la mesure est symétrique")
    func systemScorerIsSymmetric() async {
        let scorer = NaturalLanguageSimilarityScorer()
        let a = "TypeScript ajoute un système de types statiques à JavaScript."
        let b = "Le typage statique permet de détecter des erreurs avant l'exécution."

        let forward = await scorer.similarity(between: a, and: b)
        let backward = await scorer.similarity(between: b, and: a)

        #expect(abs(forward - backward) < 1e-9)
    }

    @Test("Vrai modèle : l'extrait pertinent devance nettement le hors-sujet")
    func systemScorerRanksRelevantContentFirst() async {
        let scorer = NaturalLanguageSimilarityScorer()
        let scores = await scorer.similarities(
            of: "différence entre JavaScript et TypeScript",
            against: [
                "TypeScript est un sur-ensemble typé de JavaScript qui compile vers du JavaScript standard.",
                "La recette de la tarte aux pommes de ma grand-mère, avec une pâte brisée maison."
            ]
        )

        #expect(scores[0] > scores[1])
    }
}
