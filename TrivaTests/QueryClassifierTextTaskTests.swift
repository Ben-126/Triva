//
//  QueryClassifierTextTaskTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Mission C1, K1 : le champ `textTask` de la classification (travail sur la conversation ou
/// écriture, sans fait à vérifier). Absent, faux ou illisible, il vaut `false` : en cas de doute,
/// le mode Fiable cherche (`SearchRoute.resolve`).
@MainActor
@Suite("QueryClassifier — textTask (mission C1)")
struct QueryClassifierTextTaskTests {
    private static func json(textTaskField: String) -> String {
        """
        {"classification":{"skipSearch":true,"personalSearch":false,"academicSearch":false,\
        "discussionSearch":false,"showWeatherWidget":false,"showStockWidget":false,\
        "showCalculationWidget":false\(textTaskField)},"standaloneFollowUp":"traduire la réponse"}
        """
    }

    @Test("textTask vrai : repris, les autres champs aussi")
    func parsesTextTask() {
        let result = QueryClassifier.parse(Self.json(textTaskField: #","textTask":true"#), fallbackQuery: "q")

        #expect(result.textTask)
        #expect(result.skipSearch)
        #expect(result.standaloneFollowUp == "traduire la réponse")
    }

    @Test("textTask absent : false, sans que le reste de la classification retombe sur le repli")
    func absentTextTaskIsFalse() {
        let result = QueryClassifier.parse(Self.json(textTaskField: ""), fallbackQuery: "q")

        #expect(!result.textTask)
        #expect(result.skipSearch, "un champ ajouté après coup ne doit pas invalider une classification valide")
    }

    @Test("textTask de mauvais type (« oui ») : false, le reste de la classification est conservé", arguments: [#","textTask":"oui""#, #","textTask":1"#, #","textTask":null"#])
    func wrongTypedTextTaskIsFalseAndKeepsTheRest(field: String) {
        let result = QueryClassifier.parse(Self.json(textTaskField: field), fallbackQuery: "q")

        #expect(!result.textTask)
        #expect(result.skipSearch)
        #expect(result.standaloneFollowUp == "traduire la réponse")
    }

    @Test("Sortie illisible : repli sûr, textTask faux")
    func unreadableOutputHasNoTextTask() {
        #expect(!QueryClassifier.parse("pas du JSON", fallbackQuery: "q").textTask)
    }

    @Test("Les deux prompts demandent le champ textTask et disent de le mettre à false en cas de doute", arguments: [ClassifierPromptComplexity.full, .concise])
    func promptsAskForTextTask(complexity: ClassifierPromptComplexity) {
        let prompt = QueryClassifier.buildPrompt(query: "Traduis ta réponse", chatHistory: [], maxHistoryMessages: 8, promptComplexity: complexity)

        #expect(prompt.contains("\"textTask\""))
        #expect(prompt.lowercased().contains("incertain"))
    }
}
