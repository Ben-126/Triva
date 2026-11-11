//
//  PromptAccuracyRulesTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Consignes de la mission A2 (« des réponses justes, pas seulement une source présente ») dans les
// prompts : rédaction (rappel hors sujet, historique jamais recopié, longueur d'Approfondi) et
// classifieur (recherche sautée, académique, discussion). Ces tests vérifient que la consigne est
// ÉCRITE ; qu'un modèle la suive ne se prouve pas ici (classifieur stochastique) : c'est l'objet de
// l'évaluation réelle de la mission.

@Suite("PromptTemplates — consignes de justesse (mission A2)")
struct WriterAccuracyRulesTests {
    private static let reminder = "Attention : aucun document ci-dessus ne reprend les mots de la question"
    private static let date = Date(timeIntervalSince1970: 0)
    private static let source = SearXNGSearchResult(
        title: "Paris Saint-Germain", url: "https://fr.wikipedia.org/wiki/Paris_Saint-Germain", content: "Club de football.",
        imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    )

    private func prompt(
        _ complexity: WriterPromptComplexity,
        mode: ResponseMode = .quick,
        sources: [SearXNGSearchResult] = [Self.source],
        hasWidgetData: Bool = false,
        matches: Bool
    ) -> String {
        PromptTemplates.writerPrompt(
            query: "Cite les 27 pays de l'UE et la capitale de chacun",
            sources: sources,
            mode: mode,
            complexity: complexity,
            currentDate: Self.date,
            hasWidgetData: hasWidgetData,
            sourcesMatchQuestion: matches
        )
    }

    @Test("Sources hors sujet : rappel conditionnel avec le refus exact, dans les deux verbosités", arguments: [
        WriterPromptComplexity.full, .concise,
    ])
    func offTopicReminderGivesTheExactRefusal(complexity: WriterPromptComplexity) {
        let text = prompt(complexity, matches: false)

        #expect(text.contains(Self.reminder))
        #expect(text.contains("S'ils ne traitent pas de la question, ne les cite pas et réponds exactement « \(PromptTemplates.noRelevantInformationAnswer) »"))
    }

    @Test("Le rappel suit le contexte et précède la question", arguments: [WriterPromptComplexity.full, .concise])
    func reminderSitsBetweenContextAndQuestion(complexity: WriterPromptComplexity) throws {
        let text = prompt(complexity, matches: false)

        let contextEnd = try #require(text.range(of: "</contexte>"))
        let reminder = try #require(text.range(of: Self.reminder))
        let question = try #require(text.range(of: "Cite les 27 pays", options: .backwards))
        #expect(contextEnd.upperBound <= reminder.lowerBound)
        #expect(reminder.upperBound <= question.lowerBound)
    }

    @Test("Avec des données de widget, le rappel renvoie au widget au lieu du refus", arguments: [
        WriterPromptComplexity.full, .concise,
    ])
    func widgetVariantPointsToTheWidget(complexity: WriterPromptComplexity) {
        let text = prompt(complexity, hasWidgetData: true, matches: false)

        #expect(text.contains(Self.reminder))
        #expect(text.contains("réponds à partir des données des widgets plus bas"))
        #expect(!text.contains("ne les cite pas et réponds exactement"))
    }

    @Test("Sources sur le sujet, ou aucune source : pas de rappel", arguments: [WriterPromptComplexity.full, .concise])
    func noReminderWhenNotNeeded(complexity: WriterPromptComplexity) {
        #expect(!prompt(complexity, matches: true).contains(Self.reminder))
        #expect(!prompt(complexity, sources: [], matches: false).contains(Self.reminder))
    }

    @Test("Défaut de `sourcesMatchQuestion` : prompt identique au caractère près")
    func defaultLeavesThePromptUnchanged() {
        for complexity in [WriterPromptComplexity.full, .concise] {
            let explicit = prompt(complexity, matches: true)
            let byDefault = PromptTemplates.writerPrompt(
                query: "Cite les 27 pays de l'UE et la capitale de chacun",
                sources: [Self.source],
                mode: .quick,
                complexity: complexity,
                currentDate: Self.date
            )
            #expect(explicit == byDefault)
        }
    }

    @Test("Historique : jamais recopié, dans les deux verbosités", arguments: [WriterPromptComplexity.full, .concise])
    func historyIsNeverCopied(complexity: WriterPromptComplexity) {
        #expect(prompt(complexity, matches: true).contains("ne recopie jamais une réponse précédente"))
    }

    @Test("Approfondi concis : une longueur visée, sans pousser à inventer")
    func deepConciseHasALengthTarget() {
        let section = PromptTemplates.modeSection(for: .deep, complexity: .concise)

        #expect(section.contains("Vise 300 à 400 mots si les sources le permettent"))
        #expect(section.contains("sans rien inventer"))
        // Mesure APRÈS de l'éval A2 : la cible de longueur faisait résumer des documents hors sujet.
        #expect(section.contains("jamais le résumé d'un document qui parle d'autre chose"))
        #expect(!section.contains("écris tout ce qu'elles disent"))
        #expect(!PromptTemplates.modeSection(for: .quick, complexity: .concise).contains("Vise 300 à 400 mots"))
    }
}

@MainActor
@Suite("QueryClassifier — consignes de routage (mission A2)")
struct ClassifierAccuracyRulesTests {
    private static let full = QueryClassifier.buildPrompt(query: "requête", chatHistory: [], maxHistoryMessages: 8, promptComplexity: .full)
    private static let concise = QueryClassifier.buildPrompt(
        query: "requête", chatHistory: [], maxHistoryMessages: 8, promptComplexity: .concise
    )

    /// Le texte de T2 porte 7 espaces dans le FICHIER source ; la chaîne multiligne retire les 4 du
    /// `"""` final, d'où 3 dans le prompt réel. Vérifié avec la ligne qui la précède : la place
    /// demandée (« après QueryClassifier.swift:360 ») fait partie de la décision.
    @Test("Décision 1 : la ligne de T2 sur discussionSearch, au mot près, juste après la règle discussion existante")
    func discussionLineFromT2() {
        let previous = "   - Mets-le à false si la requête peut être répondue par une recherche web générale "
            + "ou ne demande pas spécifiquement des plateformes de discussion."
        let line = "   - Mets-le à false pour une question factuelle, une définition, une explication ou une comparaison technique, "
            + "par exemple \"Quelles sont les différences entre X et Y ?\" : ce n'est pas une demande d'avis."
        #expect(Self.full.contains(previous + "\n" + line + "\n"))
    }

    @Test("Décision 2 : en concis, skipSearch réservé à une liste fermée ; les faits passent par la recherche")
    func conciseSkipSearchIsAClosedList() {
        // La liste exacte de Ben : y ajouter un cas (la météo, par exemple) doit être une décision.
        #expect(Self.concise.contains(
            "\"skipSearch\": true SEULEMENT pour une salutation, une écriture ou reformulation "
                + "(poème, e-mail, traduction, résumé de la conversation) ou un calcul ;"
        ))
        #expect(Self.concise.contains("false pour toute question de fait"))
        #expect(Self.concise.contains("même si tu connais la réponse"))
        #expect(!Self.concise.contains("connaissance générale"))
    }

    @Test("Décision 4 : « Cite » ne déclenche plus la recherche académique, ni « citations » ni « recherches »")
    func citeIsNotAcademic() {
        #expect(Self.concise.contains("(« Cite… » demande une liste : false)"))
        #expect(!Self.concise.contains("études/recherches/citations"))
        #expect(!Self.full.contains("ou des citations"))
        #expect(!Self.full.contains("Fournis des citations pour"))
        #expect(Self.full.contains("Le verbe \"citer\""))
    }

    @Test("Le prompt concis reste nettement plus court que le détaillé")
    func conciseStaysShort() {
        #expect(Self.concise.count * 2 < Self.full.count)
    }
}
