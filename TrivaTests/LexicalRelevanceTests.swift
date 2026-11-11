//
//  LexicalRelevanceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Test lexical de pertinence (mission A2, décision 6 de Ben). Les cas « réels » reprennent les
/// titres relevés par l'éval A2 (Apple Intelligence, chaîne sans clé, 2026-11-11) et les rapports
/// T1/Q1 ; les extraits sont abrégés, jamais inventés pour faire passer le test.
@MainActor
@Suite("LexicalRelevance — une source parle-t-elle de la question ?")
struct LexicalRelevanceTests {
    private func result(_ title: String, url: String, content: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: content,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    // MARK: - Mots pleins

    @Test("Verbes de consigne, mots interrogatifs et outils grammaticaux sont retirés : il reste le sujet")
    func instructionWordsAreStopWords() {
        #expect(LexicalRelevance(query: "Explique en détail comment fonctionne la photosynthèse.").terms == ["photosynthese"])
        // « pays » -> « pay » : le pluriel en -s est retiré des DEUX côtés, l'égalité tient.
        #expect(LexicalRelevance(query: "Cite les 27 pays de l'UE et la capitale de chacun").terms == ["27", "pay", "ue", "capitale"])
        #expect(LexicalRelevance(query: "What is the capital of Japan?").terms == ["capital", "japan"])
    }

    @Test("Éval A2, mesure APRÈS : « processus » et « étape » ne suffisent plus, seul le sujet compte")
    func processWordsAreStopWords() {
        let relevance = LexicalRelevance(query: "Décrire le processus de la photosynthèse étape par étape.")
        #expect(relevance.terms == ["photosynthese"])
        #expect(LexicalRelevance(query: "Quelle est la méthode, la manière ou le principe ?").terms.isEmpty)
        #expect(LexicalRelevance(query: "What is the process, step by step?").terms.isEmpty)

        // Abrégé de l'introduction « Respiration » relevée par l'éval : rien sur la photosynthèse.
        let respiration = result(
            "Respiration", url: "https://fr.wikipedia.org/wiki/Respiration",
            content: "La respiration est un processus biochimique qui se déroule en plusieurs étapes dans la cellule."
        )
        let photosynthesis = result(
            "Photosynthèse", url: "https://fr.wikipedia.org/wiki/Photosynth%C3%A8se",
            content: "La photosynthèse est le processus par lequel les plantes synthétisent de la matière organique."
        )
        #expect(relevance.assess([respiration]) == .offTopic(bestMatchCount: 0))
        #expect(relevance.assess([respiration, photosynthesis]) == .relevant)
    }

    @Test("Apostrophes droite et typographique, traits d'union, accents, majuscules et pluriel : même mot")
    func normalisationFoldsVariants() {
        #expect(LexicalRelevance(query: "l'UE").terms == LexicalRelevance(query: "L’ue").terms)
        #expect(LexicalRelevance(query: "Tours Eiffel").terms == ["tour", "eiffel"])
        #expect(LexicalRelevance(query: "chaînée").terms == LexicalRelevance(query: "CHAINEE").terms)
        #expect(LexicalRelevance(query: "Saint-Germain-des-Prés").terms == ["saint", "germain", "pre"])
    }

    @Test("Mots exigés : 2, ou tous s'il y en a moins ; aucun sans mot plein")
    func requiredMatchesIsCappedAtTwo() {
        #expect(LexicalRelevance(query: "Prix d'un billet pour la tour Eiffel en 2026 ?").requiredMatches == 2)
        #expect(LexicalRelevance(query: "photosynthèse").requiredMatches == 1)
        #expect(LexicalRelevance(query: "Et toi ?").requiredMatches == 0)
    }

    // MARK: - Verdicts sur des cas réels

    @Test("Constat T1 / éval A2 : « Monty Python » n'est pas une réponse sur les listes chaînées en Python")
    func montyPythonIsOffTopicForLinkedLists() {
        let relevance = LexicalRelevance(query: "Quelles sont les méthodes pour créer une liste chaînée en Python ?")
        let monty = result(
            "Monty Python", url: "https://fr.wikipedia.org/wiki/Monty_Python",
            content: "Les Monty Python sont une troupe d'humoristes britanniques formée en 1969."
        )
        let youtube = result("YouTube", url: "https://fr.wikipedia.org/wiki/YouTube", content: "YouTube est un site web d'hébergement de vidéos.")

        #expect(relevance.assess([youtube, monty]) == .offTopic(bestMatchCount: 1))
    }

    @Test("Une vraie page sur le sujet passe, y compris en anglais par préfixe (« list » / « liste »)")
    func onTopicPagesPassAcrossLanguages() {
        let relevance = LexicalRelevance(query: "Comment créer une liste chaînée en Python ?")
        let french = result(
            "Liste chaînée", url: "https://fr.wikipedia.org/wiki/Liste_cha%C3%AEn%C3%A9e",
            content: "Une liste chaînée désigne en informatique une structure de données représentant une collection ordonnée."
        )
        let english = result(
            "Linked List in Python", url: "https://www.geeksforgeeks.org/python-linked-list/",
            content: "A linked list is a linear data structure where each node points to the next one."
        )

        #expect(relevance.assess([french]) == .relevant)
        #expect(relevance.assess([english]) == .relevant)
    }

    @Test("Limite assumée : « Liste des sketches des Monty Python » reprend « liste » et « python », elle passe")
    func knownFalsePassIsDocumented() {
        let relevance = LexicalRelevance(query: "Comment créer une liste chaînée en Python ?")
        let sketches = result(
            "Liste des sketches des Monty Python", url: "https://fr.wikipedia.org/wiki/Liste_des_sketches_des_Monty_Python",
            content: "Cet article recense les sketches du Flying Circus."
        )
        #expect(relevance.assess([sketches]) == .relevant)
    }

    @Test("Éval A2, Q4 : des thèses OpenAlex qui ne reprennent qu'« UE » ne répondent pas aux 27 pays et capitales")
    func academicThesesAreOffTopicForEUCapitals() {
        let relevance = LexicalRelevance(query: "Liste des 27 pays de l'UE avec leur capitale respective.")
        let thesis = result(
            "Immigration des étudiants internationaux vers l’UE - Luxembourg", url: "https://orbilu.uni.lu/handle/10993/18070",
            content: "Cette étude porte sur les politiques d'accueil des étudiants étrangers."
        )
        let eu = result(
            "Union européenne", url: "https://fr.wikipedia.org/wiki/Union_europ%C3%A9enne",
            content: "L'Union européenne (UE) est une union politico-économique de 27 États européens."
        )

        #expect(relevance.assess([thesis]) == .offTopic(bestMatchCount: 1))
        #expect(relevance.assess([thesis, eu]) == .relevant)
    }

    @Test("Un mot plein seul (« photosynthèse ») : l'article qui le contient passe")
    func singleTermQuestion() {
        let relevance = LexicalRelevance(query: "Explique en détail comment fonctionne la photosynthèse.")
        let article = result(
            "Photosynthèse", url: "https://fr.wikipedia.org/wiki/Photosynth%C3%A8se",
            content: "La photosynthèse est le processus bioénergétique qui permet de synthétiser de la matière organique."
        )
        #expect(relevance.assess([article]) == .relevant)
    }

    @Test("Le titre et l'URL comptent, pas seulement l'extrait")
    func titleAndURLAreSearched() {
        let relevance = LexicalRelevance(query: "Hauteur de la tour Montparnasse")
        let page = result("Accueil", url: "https://example.org/tour-montparnasse/hauteur", content: "Bienvenue sur notre site.")
        #expect(relevance.matchCount(in: page) == 3)
    }

    // MARK: - Rien à juger

    @Test("Question sans mot plein : toute réponse passe (rien à chercher)")
    func questionWithoutTermsAcceptsEverything() {
        let page = result("Trouvé", url: "https://trouve.example/page", content: "Extrait Trouvé")
        #expect(LexicalRelevance(query: "q").assess([page]) == .relevant)
        #expect(LexicalRelevance(query: "Et toi ?").assess([page]) == .relevant)
    }

    @Test("Réponse sans aucun extrait (URL nues de la recherche cloud) : non jugée, elle passe")
    func responsesWithoutExcerptsAreNotJudged() {
        let relevance = LexicalRelevance(query: "Quelle est la hauteur de la tour Eiffel ?")
        let bare = result("www.ryzlabs.com", url: "https://www.ryzlabs.com", content: nil)
        let blank = result("Sans titre", url: "https://example.org/a", content: "   ")
        #expect(relevance.assess([bare, blank]) == .relevant)
    }

    @Test("Aucun résultat : verdict vide, distinct du hors-sujet")
    func emptyResultsAreEmpty() {
        #expect(LexicalRelevance(query: "Tour Eiffel").assess([]) == .empty)
        #expect(LexicalRelevance(query: "q").assess([]) == .empty)
    }
}
