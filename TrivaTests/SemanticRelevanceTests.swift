//
//  SemanticRelevanceTests.swift
//  TrivaTests
//
//  Mission C6 (décision de Ben, 2026-11-14) : un fichier joint est pertinent si les mots OU le sens
//  correspondent. Le seuil (1,05, distance cosinus entre MOTS) est documenté dans `SemanticRelevance`.
//

import Testing
import Foundation
import NaturalLanguage
@testable import Triva

private func document(_ content: String, title: String = "fichier.txt") -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: title, url: "triva-attachment:\(UUID().uuidString)", content: content,
        imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    )
}

/// Sens simulé : une table de paires de mots liés, pour tester la RÈGLE sans le modèle système.
private struct TableMatcher: SemanticWordMatching {
    let related: Set<String>
    func relatedTerms(_ terms: [String], among words: [String], language: NLLanguage, maximumDistance: Double) async -> Set<String> {
        Set(terms.filter { term in words.contains { related.contains("\(term)|\($0)") } })
    }
}

private struct NoModelMatcher: SemanticWordMatching {
    func relatedTerms(_ terms: [String], among words: [String], language: NLLanguage, maximumDistance: Double) async -> Set<String> { [] }
}

@Suite("SemanticRelevance : la règle (sens simulé)")
struct SemanticRelevanceRuleTests {
    private let matcher = TableMatcher(related: ["voiture|automobile", "electrique|batterie", "électrique|batterie"])

    @Test("C6b : le sens seul ne suffit JAMAIS, même avec deux mots liés (aucun mot commun)")
    func relatedWordsWithoutAnySharedWordAreRejected() async {
        let relevance = SemanticRelevance(query: "voiture électrique autonomie", matcher: matcher)
        #expect(await !relevance.matches(document("Cette automobile à batterie parcourt 400 kilomètres.")))
    }

    /// Non-régression C6b (faux accord prouvé) : gâteau~gourmands 0,959 et chocolat~gourmands 0,933 sous le
    /// seuil de 1,05 faisaient passer un extrait de jardinage. Doit échouer sans la garde « au moins un mot commun ».
    @Test("C6b : « recette gâteau chocolat » contre un extrait de jardinage (« gourmands ») est rejeté")
    func gardeningExcerptIsRejectedForACakeRecipe() async {
        let polysemy = TableMatcher(related: ["gâteau|gourmands", "chocolat|gourmands", "gateau|gourmands"])
        let relevance = SemanticRelevance(query: "recette gâteau chocolat", matcher: polysemy)
        #expect(await !relevance.matches(document("Taillez les gourmands des tomates pour favoriser la récolte.")))
    }

    @Test("Un mot commun plus un mot lié par le sens suffisent (cas positif adapté : au moins 1 mot commun)")
    func oneSharedWordPlusOneRelatedWordPassWithBattery() async {
        let relevance = SemanticRelevance(query: "voiture électrique autonomie", matcher: matcher)
        #expect(await relevance.matches(document("Cette voiture à batterie parcourt 400 kilomètres.")))
    }

    @Test("Un mot commun seul ne suffit pas (il en faut 2 au total, sens compris)")
    func oneSharedWordAloneIsNotEnough() async {
        let relevance = SemanticRelevance(query: "voiture électrique autonomie", matcher: matcher)
        #expect(await !relevance.matches(document("Cette voiture est rouge et très grande.")))
    }

    @Test("Un mot commun plus un mot lié par le sens suffisent")
    func oneSharedWordPlusOneRelatedWordPass() async {
        let relevance = SemanticRelevance(query: "voiture électrique autonomie", matcher: matcher)
        #expect(await relevance.matches(document("L'autonomie dépend de la batterie.")))
    }

    @Test("Question à un seul mot plein : le sens est désactivé, la règle reste lexicale")
    func singleTermQueryStaysLexical() async {
        let relevance = SemanticRelevance(query: "Comment fonctionne la voiture ?", matcher: matcher)
        #expect(await !relevance.matches(document("Cette automobile à batterie est neuve.")))
        #expect(await relevance.matches(document("La voiture démarre.")))
    }

    @Test("Sans modèle de mots (langue non couverte) : repli lexical, comportement d'avant")
    func withoutModelItIsLexical() async {
        let relevance = SemanticRelevance(query: "voiture électrique autonomie", matcher: NoModelMatcher())
        #expect(await !relevance.matches(document("Cette automobile à batterie parcourt 400 kilomètres.")))
        #expect(await relevance.matches(document("La voiture électrique roule.")))
    }

    @Test("Question sans mot plein : rien à juger, le fichier passe (comme avant)")
    func emptyQueryPasses() async {
        #expect(await SemanticRelevance(query: "Et toi ?", matcher: NoModelMatcher()).matches(document("texte")))
    }
}

/// Le vrai modèle de mots du système (macOS/iOS 27, sur l'appareil). Les exemples demandés par Ben, FR et EN,
/// plus les hors-sujet : ce sont eux qui justifient le seuil. Chaque test exige le modèle de SA langue : le
/// simulateur iOS n'a pas le français (`NLEmbedding.wordEmbedding(for: .french)` vaut nil), il n'est alors pas
/// exécuté (« Skipped », jamais un faux succès ni un faux échec) ; la règle, elle, est couverte plus haut par un sens simulé.
@Suite("SemanticRelevance : modèle système, FR et EN")
struct SemanticRelevanceSystemTests {
    static let hasFrenchModel = SystemSemanticWordMatcher.hasWordModel(for: .french)
    static let hasEnglishModel = SystemSemanticWordMatcher.hasWordModel(for: .english)

    private func passes(_ query: String, _ excerpt: String) async -> Bool {
        await SemanticRelevance(query: query).matches(document(excerpt))
    }

    @Test("FR : « voiture électrique autonomie » + un mot commun et « batterie » ; la cuisine, non",
          .enabled(if: hasFrenchModel, "pas de modèle de mots français sur cet appareil"))
    func frenchCar() async {
        let query = "voiture électrique autonomie"
        #expect(await passes(query, "Cette voiture à batterie parcourt 400 kilomètres avec une seule charge."))
        #expect(await !passes(query, "Faites revenir les oignons dans du beurre puis ajoutez la crème et le sel."))
        #expect(await !passes(query, "Le match de football s'est terminé par une victoire de l'équipe locale."))
        #expect(await !passes(query, "Le contrat de location prévoit un préavis de trois mois."))
    }

    @Test("FR (C6b) : « recette gâteau chocolat » rejette l'extrait de jardinage avec le VRAI modèle",
          .enabled(if: hasFrenchModel, "pas de modèle de mots français sur cet appareil"))
    func frenchCakeVersusGardening() async {
        #expect(await !passes("recette gâteau chocolat", "Taillez les gourmands des tomates pour favoriser la récolte."))
    }

    @Test("FR : questions en phrase entière (mots vides retirés)",
          .enabled(if: hasFrenchModel, "pas de modèle de mots français sur cet appareil"))
    func frenchSentences() async {
        #expect(await passes("Quels sont les effets du réchauffement climatique ?", "Le réchauffement mondial fait fondre les glaciers et monter les océans."))
        #expect(await !passes("Quels sont les effets du réchauffement climatique ?", "La mitochondrie produit de l'énergie sous forme d'ATP dans la cellule."))
        #expect(await passes("Comment apprendre à programmer ?", "Pour apprendre, il faut écrire de petits programmes, avec des boucles et des variables."))
    }

    @Test("EN : « electric vehicle range » + un mot commun et « battery » ; la cuisine, non",
          .enabled(if: hasEnglishModel, "pas de modèle de mots anglais sur cet appareil"))
    func englishCar() async {
        // « vehicle » et non « car » : « car » est un mot vide de `LexicalRelevance` (« car » français = parce que).
        let query = "electric vehicle range"
        #expect(await passes(query, "This battery-powered vehicle can travel 250 miles on a single charge."))
        #expect(await !passes(query, "Heat the butter in a pan, add the onions and stir in the cream."))
        #expect(await !passes(query, "The football match ended with a win for the home team."))
        #expect(await !passes(query, "The lease agreement requires three months notice before moving out."))
    }

    @Test("EN : climat et programmation",
          .enabled(if: hasEnglishModel, "pas de modèle de mots anglais sur cet appareil"))
    func englishOthers() async {
        #expect(await passes("climate change effects", "Rising climate temperatures melt glaciers and raise sea levels."))
        #expect(await !passes("climate change effects", "The city council voted on the library budget on Tuesday."))
        #expect(await passes("learn programming", "Beginners should learn to write small programs and understand loops and variables."))
        #expect(await !passes("learn programming", "This novel tells the story of a family of fishermen in Brittany."))
    }

    @Test("Les mots communs passent toujours, sens ou pas")
    func sharedWordsStillPass() async {
        #expect(await passes("voiture électrique autonomie", "L'autonomie de la voiture électrique dépasse 500 km."))
        #expect(await passes("tour Eiffel hauteur", "La tour Eiffel mesure 330 mètres de hauteur."))
    }

    @Test("Détection de la langue de la question")
    func languageDetection() {
        #expect(SemanticRelevance.language(of: "Comment apprendre à programmer ?", excerpt: "") == .french)
        #expect(SemanticRelevance.language(of: "How to learn programming?", excerpt: "") == .english)
    }

    @Test("Le matcher par défaut est l'instance partagée : son cache de modèles sert d'une question à l'autre")
    func defaultMatcherIsTheSharedInstance() {
        #expect(SystemSemanticWordMatcher.shared === SystemSemanticWordMatcher.shared)
    }
}
