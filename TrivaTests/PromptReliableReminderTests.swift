//
//  PromptReliableReminderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Rappel du mode Fiable dans les prompts de rédaction (rapport T2 `failed[9]`, test permanent manquant,
/// puis mission A3 : le prompt CONCIS en reçoit un lui aussi). Ces tests vérifient que la consigne est
/// ÉCRITE, au bon endroit et seulement au bon moment ; qu'un modèle la suive se mesure sur le modèle
/// (voir le commentaire de `PromptTemplates.conciseReliableReminder`).
@Suite("PromptTemplates — rappel du mode Fiable (mission A3)")
struct ReliableReminderTests {
    private static let marker = "Rappel du mode Fiable"
    private static let date = Date(timeIntervalSince1970: 0)
    private static let question = "Quelle est la capitale de l'Australie ?"
    private static let source = SearXNGSearchResult(
        title: "Canberra", url: "https://fr.wikipedia.org/wiki/Canberra", content: "Capitale fédérale de l'Australie.",
        imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    )

    private func prompt(
        _ complexity: WriterPromptComplexity,
        mode: ResponseMode,
        sources: [SearXNGSearchResult] = [Self.source],
        hasWidgetData: Bool = false
    ) -> String {
        PromptTemplates.writerPrompt(
            query: Self.question, sources: sources, mode: mode, complexity: complexity,
            currentDate: Self.date, hasWidgetData: hasWidgetData
        )
    }

    @Test("Fiable avec contexte non vide : le rappel y est, avec le refus exact, dans les deux verbosités", arguments: [
        WriterPromptComplexity.full, .concise,
    ])
    func reminderPresentInReliableMode(complexity: WriterPromptComplexity) {
        let text = prompt(complexity, mode: .reliable)

        #expect(text.contains(Self.marker))
        #expect(text.contains("réponds exactement « \(PromptTemplates.noRelevantInformationAnswer) »"))
    }

    @Test("Le rappel suit le contexte et précède la question", arguments: [WriterPromptComplexity.full, .concise])
    func reminderSitsBetweenContextAndQuestion(complexity: WriterPromptComplexity) throws {
        let text = prompt(complexity, mode: .reliable)

        let contextEnd = try #require(text.range(of: "</contexte>"))
        let reminder = try #require(text.range(of: Self.marker))
        let question = try #require(text.range(of: Self.question, options: .backwards))
        #expect(contextEnd.upperBound <= reminder.lowerBound)
        #expect(reminder.upperBound <= question.lowerBound)
    }

    @Test("Sans document (contexte « aucune source ») : pas de rappel, `modeSection` prévoit l'avertissement", arguments: [
        WriterPromptComplexity.full, .concise,
    ])
    func noReminderWithoutDocuments(complexity: WriterPromptComplexity) {
        let text = prompt(complexity, mode: .reliable, sources: [])

        #expect(text.contains(PromptTemplates.noSourcesContext))
        #expect(!text.contains(Self.marker))
    }

    @Test("Autres modes : jamais de rappel", arguments: [WriterPromptComplexity.full, .concise])
    func noReminderOutsideReliableMode(complexity: WriterPromptComplexity) {
        #expect(!prompt(complexity, mode: .quick).contains(Self.marker))
        #expect(!prompt(complexity, mode: .deep).contains(Self.marker))
    }

    @Test("Avec des données de widget : la variante ne demande jamais le refus, dans les deux verbosités", arguments: [
        WriterPromptComplexity.full, .concise,
    ])
    func widgetVariantNeverAsksForTheRefusal(complexity: WriterPromptComplexity) throws {
        let text = prompt(complexity, mode: .reliable, hasWidgetData: true)

        // Le texte du RAPPEL seul : `modeSection` contient d'autres consignes de refus, sans rapport.
        let reminder = try reminderText(in: text)
        #expect(reminder.contains("widgets plus bas"))
        #expect(!reminder.contains("réponds exactement"))
    }

    /// Du marqueur jusqu'au paragraphe de date qui suit (« Date et heure… » ou « Date du jour… »).
    private func reminderText(in text: String) throws -> Substring {
        let start = try #require(text.range(of: Self.marker))
        let end = try #require(text.range(of: "\n\nDate ", range: start.upperBound..<text.endIndex))
        return text[start.lowerBound..<end.lowerBound]
    }

    @Test("Le rappel concis reste plus court que le rappel long : un petit modèle perd les consignes longues")
    func conciseReminderStaysShort() throws {
        let concise = try reminderText(in: prompt(.concise, mode: .reliable))
        let full = try reminderText(in: prompt(.full, mode: .reliable))

        #expect(concise.count < 320)
        #expect(concise.count < full.count)
        #expect(!prompt(.concise, mode: .quick).contains(Self.marker))
    }
}
