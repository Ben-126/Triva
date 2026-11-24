//
//  ResearchToolOutputTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/11/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("ResearchToolOutput : textes rendus au modèle")
struct ResearchToolOutputTests {
    // MARK: Troncature

    @Test("truncated : texte court inchangé, blancs normalisés")
    func truncatedKeepsShortText() {
        #expect(ResearchToolOutput.truncated("  bonjour \n  le   monde ", to: 80) == "bonjour le monde")
    }

    @Test("truncated : jamais plus que la limite, points de suspension compris")
    func truncatedRespectsTheLimit() {
        let text = String(repeating: "abcde ", count: 60)
        for limit in [1, 2, 10, 80, 300] {
            #expect(ResearchToolOutput.truncated(text, to: limit).count <= limit)
        }
        #expect(ResearchToolOutput.truncated(text, to: 80).hasSuffix("…"))
        #expect(ResearchToolOutput.truncated("x", to: 0) == "")
        #expect(ResearchToolOutput.truncated(text, to: 1) == "…")
    }

    @Test("truncated : exactement la limite n'ajoute rien")
    func truncatedAtExactLimit() {
        let text = String(repeating: "a", count: 80)
        #expect(ResearchToolOutput.truncated(text, to: 80) == text)
        #expect(ResearchToolOutput.truncated(text + "b", to: 80).count == 80)
    }

    // MARK: Liste de recherche

    @Test("searchOutput : une ligne par entrée, « [k] titre — domaine », sans www.")
    func searchOutputFormat() {
        let entries = [
            ResearchEntry(number: 3, result: makeSourceResult(url: "https://www.exemple.fr/a", title: "Un titre")),
            ResearchEntry(number: 4, result: makeSourceResult(url: "https://docs.autre.org/b", title: "Autre")),
        ]
        #expect(ResearchToolOutput.searchOutput(entries) == "[3] Un titre — exemple.fr\n[4] Autre — docs.autre.org")
    }

    @Test("searchOutput : liste vide = texte « aucun résultat »")
    func searchOutputEmpty() {
        #expect(ResearchToolOutput.searchOutput([]) == ResearchToolOutput.noResults)
    }

    @Test("searchOutput : un titre de 200 caractères est coupé à 80")
    func searchOutputTruncatesTitles() {
        let entry = ResearchEntry(number: 1, result: makeSourceResult(url: "https://a.fr/x", title: String(repeating: "t", count: 200)))
        let line = ResearchToolOutput.searchOutput([entry])
        let title = line.dropFirst("[1] ".count).dropLast(" — a.fr".count)
        #expect(title.count == ResearchToolOutput.maxTitleCharacters)
    }

    @Test("domain : sans hôte, « source »")
    func domainFallback() {
        #expect(ResearchToolOutput.domain(of: "pas une adresse") == "source")
        #expect(ResearchToolOutput.domain(of: "https://www.Exemple.FR/x") == "exemple.fr")
    }

    // MARK: Lecture

    @Test("readOutput : accusé avec le nombre de caractères, puis le passage")
    func readOutputSuccess() {
        let page = ScrapedPage(url: "https://a.fr", title: "t", content: "La tour mesure 330 mètres. Elle est à Paris.", succeeded: true)
        let output = ResearchToolOutput.readOutput(number: 2, page: page, query: "hauteur tour")
        #expect(output.hasPrefix("[2] lue, \(page.content.count) caractères.\nPassage : "))
        #expect(output.contains("330 mètres"))
    }

    @Test("readOutput : refus du site, échec, contenu blanc")
    func readOutputFailures() {
        let refused = ScrapedPage(url: "u", title: "", content: "", succeeded: false, refusedBySite: true)
        #expect(ResearchToolOutput.readOutput(number: 1, page: refused, query: "q") == "[1] refusée par le site.")
        let failed = ScrapedPage(url: "u", title: "", content: "texte", succeeded: false)
        #expect(ResearchToolOutput.readOutput(number: 1, page: failed, query: "q") == "[1] illisible.")
        let blank = ScrapedPage(url: "u", title: "", content: " \n ", succeeded: true)
        #expect(ResearchToolOutput.readOutput(number: 1, page: blank, query: "q") == "[1] illisible.")
    }

    // MARK: Passage

    @Test("bestPassage : la phrase qui reprend le plus de mots de la question")
    func bestPassagePicksTheClosestSentence() {
        let text = "Paris est la capitale. La tour Eiffel mesure 330 mètres de hauteur. Le métro compte 16 lignes."
        let passage = ResearchToolOutput.bestPassage(in: text, query: "Quelle est la hauteur de la tour Eiffel ?")
        #expect(passage.hasPrefix("La tour Eiffel mesure 330 mètres de hauteur."))
    }

    @Test("bestPassage : jamais plus de 300 caractères")
    func bestPassageIsCapped() {
        let text = String(repeating: "La tour Eiffel est haute. ", count: 100)
        #expect(ResearchToolOutput.bestPassage(in: text, query: "tour Eiffel").count <= ResearchToolOutput.maxPassageCharacters)
    }

    @Test("bestPassage : une phrase de 1000 caractères est coupée à 300 avec « … »")
    func bestPassageTruncatesAHugeSentence() {
        let text = "Eiffel " + String(repeating: "mot ", count: 250) + "fin."
        let passage = ResearchToolOutput.bestPassage(in: text, query: "Eiffel")
        #expect(passage.count <= ResearchToolOutput.maxPassageCharacters)
        #expect(passage.count >= ResearchToolOutput.maxPassageCharacters - 5)
        #expect(passage.hasSuffix("…"))
    }

    @Test("bestPassage : complète avec les phrases suivantes tant que ça tient")
    func bestPassageExtendsWithFollowingSentences() {
        let text = "Intro sans rapport. La tour Eiffel mesure 330 mètres. Elle date de 1889. Fin."
        let passage = ResearchToolOutput.bestPassage(in: text, query: "tour Eiffel")
        #expect(passage == "La tour Eiffel mesure 330 mètres. Elle date de 1889. Fin.")
    }

    @Test("bestPassage : égalité = la première phrase ; aucun mot repris = le début du texte")
    func bestPassageTiesAndMisses() {
        #expect(ResearchToolOutput.bestPassage(in: "Alpha beta. Alpha gamma.", query: "alpha").hasPrefix("Alpha beta."))
        #expect(ResearchToolOutput.bestPassage(in: "Rien ici. Rien là.", query: "zèbre").hasPrefix("Rien ici."))
    }

    @Test("bestPassage : texte vide ou blanc = chaîne vide")
    func bestPassageEmpty() {
        #expect(ResearchToolOutput.bestPassage(in: "", query: "x") == "")
        #expect(ResearchToolOutput.bestPassage(in: " \n\n ", query: "x") == "")
    }

    @Test("sentences : coupe après . ! ? suivi d'un blanc, et aux sauts de ligne ; 3.5 reste entier")
    func sentenceSplitting() {
        let text = "Il fait 3.5 degrés. Vraiment ? Oui !\nNouvelle ligne"
        #expect(ResearchToolOutput.sentences(of: text) == ["Il fait 3.5 degrés.", "Vraiment ?", "Oui !", "Nouvelle ligne"])
    }

    @Test("sentences : blancs normalisés, lignes vides ignorées")
    func sentenceNormalisation() {
        #expect(ResearchToolOutput.sentences(of: "  a   b \n\n\n  c  ") == ["a b", "c"])
    }
}
