//
//  AnswerPlainTextTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission B) : le texte lu par Siri. Marques [n] retirées, mise en forme retirée, 400 caractères
//  au plus coupés à une fin de phrase, suivis de la phrase fixe. Logique pure.
//

import Foundation
import Testing
@testable import Triva

@Suite("Texte lu par Siri")
struct AnswerPlainTextTests {
    @Test("Les marques de source [n] disparaissent, sans espace en trop")
    func removesCitationMarks() {
        #expect(AnswerPlainText.plain(from: "Paris est la capitale[1]. Elle compte 2 millions d'habitants [2][3].")
                == "Paris est la capitale. Elle compte 2 millions d'habitants.")
    }

    @Test("Un numéro de source à plusieurs chiffres disparaît aussi")
    func removesLargeMarks() {
        #expect(AnswerPlainText.plain(from: "Oui [12].") == "Oui.")
    }

    @Test("Un crochet qui n'est pas une source reste")
    func keepsOtherBrackets() {
        #expect(AnswerPlainText.plain(from: "La liste [voir plus] est longue.") == "La liste [voir plus] est longue.")
    }

    @Test("La mise en forme est retirée : titres, gras, listes, code, liens")
    func stripsMarkdown() {
        let markdown = """
        ## Réponse courte
        Le **soleil** est une `étoile`.
        - Première idée
        - Seconde idée
        Voir [cette page](https://example.com/a) pour plus.
        """
        #expect(AnswerPlainText.plain(from: markdown)
                == "Réponse courte. Le soleil est une étoile. Première idée. Seconde idée. Voir cette page pour plus.")
    }

    @Test("Une multiplication « 3 * 4 » n'est pas prise pour de la mise en forme")
    func keepsMultiplication() {
        #expect(AnswerPlainText.plain(from: "Le calcul 3 * 4 vaut 12.") == "Le calcul 3 * 4 vaut 12.")
    }

    @Test("Un texte vide reste vide")
    func emptyText() {
        #expect(AnswerPlainText.plain(from: "  \n ") == "")
        #expect(AnswerPlainText.spoken(from: "") == AnswerPlainText.completionSuffix)
    }

    @Test("Texte court : repris tel quel")
    func shortTextUnchanged() {
        #expect(AnswerPlainText.excerpt(of: "Il fait beau.") == "Il fait beau.")
    }

    @Test("Texte long : coupé à la dernière fin de phrase qui tient dans 400 caractères")
    func cutsAtSentenceEnd() {
        let sentence = "Ceci est une phrase de test assez longue pour remplir de la place. "
        let text = String(repeating: sentence, count: 12).trimmingCharacters(in: .whitespaces)
        let excerpt = AnswerPlainText.excerpt(of: text)
        #expect(excerpt.count <= AnswerPlainText.maxSpokenLength)
        #expect(excerpt.hasSuffix("place."))
        #expect(excerpt.count > 300)
        #expect(!excerpt.hasSuffix(" "))
    }

    @Test("Un point décimal ou une abréviation ne sert pas de coupure")
    func decimalPointIsNotASentenceEnd() {
        let text = "Le résultat vaut 3.5 environ " + String(repeating: "mot ", count: 120)
        let excerpt = AnswerPlainText.excerpt(of: text)
        #expect(excerpt.count <= AnswerPlainText.maxSpokenLength)
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.contains("3.5"))
    }

    @Test("Sans fin de phrase : coupé entre deux mots, avec des points de suspension, 400 caractères au plus")
    func cutsAtWordBoundary() {
        let text = String(repeating: "abcdefgh ", count: 80)
        let excerpt = AnswerPlainText.excerpt(of: text)
        #expect(excerpt.count <= AnswerPlainText.maxSpokenLength)
        #expect(excerpt.hasSuffix("…"))
        #expect(!excerpt.dropLast().hasSuffix(" "))
    }

    @Test("Un texte de 400 caractères pile n'est pas coupé")
    func exactLimitUnchanged() {
        let text = String(repeating: "a", count: 399) + "."
        #expect(AnswerPlainText.excerpt(of: text) == text)
    }

    @Test("Réponse qui tient en entier dans l'extrait : lue telle quelle, sans « la réponse complète est dans Triva »")
    func spokenWithoutSuffixWhenNothingIsCut() {
        #expect(AnswerPlainText.spoken(from: "Paris[1].") == "Paris.")
    }

    @Test("Exactement 400 caractères : pas coupé, donc pas de phrase fixe")
    func spokenAtTheLimitIsNotCut() {
        let text = String(repeating: "a", count: AnswerPlainText.maxSpokenLength - 1) + "."
        #expect(AnswerPlainText.spoken(from: text) == text)
    }

    @Test("401 caractères : coupé, donc la phrase fixe est ajoutée")
    func spokenOneOverTheLimitIsCut() {
        let text = String(repeating: "a", count: AnswerPlainText.maxSpokenLength) + "."
        let spoken = AnswerPlainText.spoken(from: text)
        #expect(spoken.hasSuffix(" " + AnswerPlainText.completionSuffix))
        #expect(spoken != text)
    }

    @Test("Réponse très longue : l'extrait reste sous 400 caractères, la phrase fixe s'y ajoute")
    func spokenLongText() {
        let text = String(repeating: "Une phrase courte. ", count: 100)
        let spoken = AnswerPlainText.spoken(from: text)
        #expect(spoken.hasSuffix(" " + AnswerPlainText.completionSuffix))
        #expect(spoken.count <= AnswerPlainText.maxSpokenLength + 1 + AnswerPlainText.completionSuffix.count)
    }
}
