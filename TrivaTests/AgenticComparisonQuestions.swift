//
//  AgenticComparisonQuestions.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
@testable import Triva

/// Jeu de 20 questions du banc de comparaison 2.4 (spec §7.2). « Attendus » : groupes de mots, sans accents ni
/// casse, UN SEUL mot par groupe suffit (`AgenticEvalFacts`).
///
/// Faits revérifiés sur le web le 2026-11-26 (mission M4) :
/// - 1 : la tour Eiffel mesure 330 m depuis l'antenne de mars 2022 (toureiffel.paris) : inchangé ;
/// - 15 : l'éclipse totale du 12 août 2026 est DÉJÀ passée ; la prochaine totale visible en Espagne est celle du
///   2 août 2027 (IGN), puis une annulaire le 26 janvier 2028 : attendu « 2027 » inchangé ;
/// - 16 : iOS 27 est sorti le 14 septembre 2026 (nouveau Siri, réglages Liquid Glass) : jugé à la main.
nonisolated struct AgenticEvalQuestion: Sendable, Equatable {
    /// Ce que la question sert aussi à vérifier, au-delà des faits.
    nonisolated enum Witness: Sendable, Equatable {
        case none
        /// 20 : l'enquêteur n'est JAMAIS appelé (calcul, aucune recherche).
        case researcherNeverCalled
        /// 19 : l'enquêteur n'est pas appelé QUAND le widget météo a répondu.
        case researcherNotCalledWhenWidgetAnswered
        /// 10 : même verdict des deux côtés (refus ou sources fiables).
        case sameVerdictBothSides
    }

    /// Numéro de la spec (1 à 20) ; l'indice de `TRIVA_EVAL_RANGE` est `number - 1`.
    let number: Int
    let text: String
    /// Question 14 : le premier tour, rejoué par le MÊME chemin et passé en `chatHistory`.
    let firstTurn: String?
    /// R = rapide (mesure seulement), A = approfondie, F = fiable.
    let modes: [ResponseMode]
    let expected: [[String]]
    /// Faits à juger à la main (pas de groupes, ou chiffres à comparer).
    let manualFacts: Bool
    let witness: Witness

    init(
        _ number: Int, _ text: String, firstTurn: String? = nil, modes: [ResponseMode],
        expected: [[String]] = [], manualFacts: Bool = false, witness: Witness = .none
    ) {
        self.number = number
        self.text = text
        self.firstTurn = firstTurn
        self.modes = modes
        self.expected = expected
        self.manualFacts = manualFacts
        self.witness = witness
    }
}

nonisolated enum AgenticEvalQuestions {
    private static let quick = ResponseMode.quick
    private static let deep = ResponseMode.deep
    private static let reliable = ResponseMode.reliable

    static let all: [AgenticEvalQuestion] = [
        .init(1, "Quelle est la hauteur de la tour Eiffel ?", modes: [quick, deep], expected: [["330"]]),
        .init(2, "En quelle année Montréal a-t-elle été fondée ?", modes: [quick, deep], expected: [["1642"]]),
        .init(3, "Qui a réalisé « Le Fabuleux Destin d'Amélie Poulain » et en quelle année est-il sorti ?",
              modes: [deep], expected: [["jeunet"], ["2001"]]),
        .init(4, "Compare la population de Lyon et de Marseille.", modes: [deep],
              expected: [["marseille"], ["lyon"]], manualFacts: true),
        .init(5, "Quelle est la capitale de l'Australie et pourquoi n'est-ce pas Sydney ?", modes: [quick, deep],
              expected: [["canberra"], ["melbourne"]]),
        .init(6, "À quelle température l'eau bout-elle au sommet de l'Everest ?", modes: [deep, reliable],
              expected: [["68", "69", "70", "71"]]),
        .init(7, "Quels sont les effets indésirables du paracétamol ?", modes: [reliable], expected: [["foie", "hepat"]]),
        .init(8, "Quelle est la différence entre un virus et une bactérie ?", modes: [reliable], expected: [["antibiotique"]]),
        .init(9, "How does photosynthesis work?", modes: [quick, deep],
              expected: [["chlorophyll"], ["carbon dioxide", "co2"], ["glucose", "sugar"]]),
        .init(10, "Meilleure recette de crêpes selon les blogs ?", modes: [reliable], witness: .sameVerdictBothSides),
        .init(11, "Qui était le premier président de la Ve République et quand a-t-il démissionné ?", modes: [deep],
              expected: [["gaulle"], ["1969"]]),
        .init(12, "En Swift, à quoi sert l'attribut `@concurrent` ?", modes: [deep], expected: [["acteur", "actor", "thread"]]),
        .init(13, "Quel est le taux normal de TVA en France ?", modes: [quick, reliable], expected: [["20"]]),
        .init(14, "Où est-elle exposée ?", firstTurn: "Qui a peint La Joconde ?", modes: [deep], expected: [["louvre"]]),
        .init(15, "Quand aura lieu la prochaine éclipse totale de Soleil visible en Espagne ?", modes: [deep], expected: [["2027"]]),
        .init(16, "Quelles sont les nouveautés d'iOS 27 ?", modes: [deep], manualFacts: true),
        .init(17, "Que dit la recherche sur le télétravail et la productivité ?", modes: [deep, reliable],
              expected: [["etude", "study"], ["productivit"]]),
        .init(18, "Que pensent les utilisateurs de Reddit du clavier Keychron K2 ?", modes: [deep], expected: [["keychron"]]),
        .init(19, "Quel temps fait-il à Lyon aujourd'hui ?", modes: [deep], witness: .researcherNotCalledWhenWidgetAnswered),
        .init(20, "Combien font 17 % de 240 ?", modes: [deep], expected: [["40,8", "40.8"]], witness: .researcherNeverCalled),
    ]

    /// Questions de la plage `TRIVA_EVAL_RANGE` (indices de 0).
    static func selected(range rawRange: String?) -> [AgenticEvalQuestion] {
        guard let range = AgenticEvalRange.parse(rawRange, questionCount: all.count) else { return [] }
        return all.enumerated().filter { range.contains($0.offset) }.map(\.element)
    }
}
