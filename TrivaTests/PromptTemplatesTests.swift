//
//  PromptTemplatesTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 18/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// La génération d'un LLM n'est pas déterministe : on ne teste donc JAMAIS la
/// réponse produite, seulement le prompt envoyé — qui, lui, est une fonction
/// pure de ses entrées. Ces tests vérifient trois choses : les marqueurs
/// attendus sont présents par mode et par verbosité, le contexte et
/// l'historique sont réellement injectés, et la variante concise est
/// effectivement plus courte (sa raison d'être).
@MainActor
@Suite("PromptTemplates")
struct PromptTemplatesTests {

    // MARK: - Fixtures

    private static func source(
        title: String = "Wikipédia — Photosynthèse",
        url: String = "https://fr.wikipedia.org/wiki/Photosynthese",
        content: String? = "La photosynthèse convertit la lumière en énergie chimique."
    ) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title,
            url: url,
            content: content,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    private static func page(
        url: String,
        title: String = "Page scrapée",
        content: String = "Contenu complet de la page scrapée.",
        succeeded: Bool = true
    ) -> ScrapedPage {
        ScrapedPage(url: url, title: title, content: content, succeeded: succeeded)
    }

    /// Date figée : c'est tout l'intérêt du paramètre `currentDate` — sans
    /// lui, aucune assertion sur la date injectée ne serait possible.
    private static let fixedDate = Date(timeIntervalSince1970: 0)

    private static let history: [ClassifierChatMessage] = [
        ClassifierChatMessage(role: .user, content: "Parle-moi de la photosynthèse"),
        ClassifierChatMessage(role: .assistant, content: "C'est le processus qui transforme la lumière."),
    ]

    // MARK: - Marqueurs par mode et par verbosité

    @Test("Mode Rapide, consignes détaillées : limite de phrases annoncée et blocs de raisonnement interdits")
    func quickFullPromptMarkers() {
        let prompt = PromptTemplates.writerPrompt(
            query: "Quelle est la capitale de la France ?",
            sources: [Self.source()],
            mode: .quick,
            complexity: .full,
            currentDate: Self.fixedDate
        )

        #expect(prompt.contains("mode Rapide"))
        #expect(prompt.contains("2 à 3 phrases"))
        #expect(prompt.contains("NI bloc <think>, NI bloc <tldr>"))
        // Les consignes du mode approfondi ne doivent pas fuiter ici.
        #expect(!prompt.contains("mode Approfondi"))
    }

    @Test("Mode Approfondi, consignes détaillées : <think>, <tldr>, 3 à 5 sections, 500 mots, une seule Conclusion")
    func deepFullPromptMarkers() {
        let prompt = PromptTemplates.writerPrompt(
            query: "Comment fonctionne la photosynthèse ?",
            sources: [Self.source()],
            mode: .deep,
            complexity: .full,
            currentDate: Self.fixedDate
        )

        #expect(prompt.contains("<think>...</think>"))
        #expect(prompt.contains("<tldr>...</tldr>"))
        #expect(prompt.contains("3 à 5 sections"))
        #expect(prompt.contains("500 mots"))
        #expect(prompt.contains("EXACTEMENT UNE section ## Conclusion"))
        #expect(prompt.contains("2 phrases MAXIMUM"))
    }

    @Test("Mode Fiable, consignes détaillées : marqueur de non-confirmation et avertissement sans source")
    func reliableFullPromptMarkers() {
        let prompt = PromptTemplates.writerPrompt(
            query: "Quel est le taux exact ?",
            sources: [],
            mode: .reliable,
            complexity: .full,
            currentDate: Self.fixedDate
        )

        #expect(prompt.contains(PromptTemplates.unsupportedClaimMarker))
        #expect(prompt.contains(PromptTemplates.unverifiedSourcesWarning))
        #expect(prompt.contains("NI bloc <think>, NI bloc <tldr>"))
    }

    @Test("Les 3 modes produisent des sections de forme distinctes")
    func modeSectionsAreDistinct() {
        let sections = ResponseMode.allCases.map { PromptTemplates.modeSection(for: $0, complexity: .full) }
        #expect(sections.allSatisfy { !$0.isEmpty })
        #expect(Set(sections).count == sections.count)
    }

    @Test("Divergence assumée du mode Approfondi : <think>/<tldr> exigés en détaillé, interdits en concis")
    func deepModeBlocksDependOnComplexity() {
        let full = PromptTemplates.modeSection(for: .deep, complexity: .full)
        let concise = PromptTemplates.modeSection(for: .deep, complexity: .concise)

        #expect(full.contains("Raisonnement d'abord"))
        #expect(concise.contains("Pas de balise <think> ni <tldr>"))
    }

    // MARK: - Variante concise

    @Test("La variante concise est réellement plus courte que la détaillée, pour les 3 modes")
    func concisePromptIsShorterForEveryMode() {
        for mode in ResponseMode.allCases {
            let full = PromptTemplates.writerPrompt(
                query: "Comment fonctionne la photosynthèse ?",
                sources: [Self.source()],
                chatHistory: Self.history,
                mode: mode,
                complexity: .full,
                currentDate: Self.fixedDate
            )
            let concise = PromptTemplates.writerPrompt(
                query: "Comment fonctionne la photosynthèse ?",
                sources: [Self.source()],
                chatHistory: Self.history,
                mode: mode,
                complexity: .concise,
                currentDate: Self.fixedDate
            )

            #expect(concise.count < full.count, "mode \(mode.rawValue) : concise=\(concise.count) full=\(full.count)")
            // Facteur 2 au minimum : une version « concise » à peine plus
            // courte ne servirait à rien pour un modèle 0.6B, qui est la
            // seule raison d'exister de cette variante.
            #expect(concise.count * 2 < full.count, "mode \(mode.rawValue) : la réduction est trop faible")
        }
    }

    @Test("La variante concise garde l'essentiel : citations [n], interdiction d'inventer, longueur")
    func concisePromptKeepsTheEssentials() {
        let prompt = PromptTemplates.writerPrompt(
            query: "Quelle est la capitale de la France ?",
            sources: [Self.source()],
            mode: .quick,
            complexity: .concise,
            currentDate: Self.fixedDate
        )

        #expect(prompt.contains("[1]"))
        #expect(prompt.contains("[1][2]"))
        #expect(prompt.contains("N'invente rien"))
        #expect(prompt.contains("2 à 3 phrases maximum"))
    }

    @Test("La checklist finale n'existe qu'en consignes détaillées")
    func checklistOnlyInFullComplexity() {
        for mode in ResponseMode.allCases {
            #expect(PromptTemplates.checklistSection(for: mode, complexity: .concise).isEmpty)
            #expect(!PromptTemplates.checklistSection(for: mode, complexity: .full).isEmpty)
        }
    }

    @Test("La checklist détaillée est spécialisée par mode")
    func checklistIsModeSpecific() {
        #expect(PromptTemplates.checklistSection(for: .quick, complexity: .full).contains("Mode Rapide"))
        #expect(PromptTemplates.checklistSection(for: .deep, complexity: .full).contains("Mode Approfondi"))
        #expect(PromptTemplates.checklistSection(for: .reliable, complexity: .full).contains("Mode Fiable"))
    }

    // MARK: - Rappel du mode Fiable (mission A1, rapport T2 finding 9)

    /// Ouverture du rappel, juste après la balise fermante du contexte.
    private static let reliableReminderOpening = "</contexte>\n\nRappel du mode Fiable : "

    /// Prompt de rédaction détaillé (seul à porter le rappel), date fixée.
    private static func fullWriterPrompt(
        mode: ResponseMode,
        sources: [SearXNGSearchResult],
        hasWidgetData: Bool = false
    ) -> String {
        PromptTemplates.writerPrompt(
            query: "Quelles sont les différences entre JavaScript et TypeScript ?",
            sources: sources,
            mode: mode,
            complexity: .full,
            currentDate: Self.fixedDate,
            hasWidgetData: hasWidgetData
        )
    }

    /// Mesure du 2026-11-05 (rapport T2) : sans ce rappel, un document hors sujet
    /// suffisait à une réponse de tête, sans citation ni marqueur, en mode Fiable.
    @Test("Mode Fiable, contexte non vide : le rappel suit le contexte, avant la date, et impose le refus exact")
    func reliableReminderFollowsANonEmptyContext() throws {
        let prompt = Self.fullWriterPrompt(mode: .reliable, sources: [Self.source()])

        let reminder = try #require(prompt.range(of: Self.reliableReminderOpening))
        let date = try #require(prompt.range(of: "Date et heure actuelles"))
        #expect(reminder.upperBound < date.lowerBound)
        #expect(prompt[reminder.upperBound...].contains("réponds exactement « \(PromptTemplates.noRelevantInformationAnswer) »"))
    }

    /// « Aucune source disponible. » : sources absentes, ou toutes sans contenu
    /// (mission A1, `numberedContext`) — le cas widget seul, où `modeSection`
    /// impose déjà l'avertissement.
    @Test("Mode Fiable sans document lisible (aucune source, ou sources sans contenu) : aucun rappel")
    func reliableReminderIsAbsentWithNoSourcesContext() {
        let noSource = Self.fullWriterPrompt(mode: .reliable, sources: [])
        let unreadable = Self.fullWriterPrompt(
            mode: .reliable,
            sources: [Self.source(title: "Page jamais lue", url: "https://exemple.fr/nue", content: nil)]
        )

        for prompt in [noSource, unreadable] {
            #expect(prompt.contains("<contexte>\n\(PromptTemplates.noSourcesContext)\n</contexte>"))
            #expect(!prompt.contains("Rappel du mode Fiable"))
        }
        #expect(!unreadable.contains("Page jamais lue"))
    }

    @Test("Modes Rapide et Approfondi : jamais de rappel Fiable, même avec un contexte non vide", arguments: [ResponseMode.quick, .deep])
    func reliableReminderIsAbsentInOtherModes(mode: ResponseMode) {
        let prompt = Self.fullWriterPrompt(mode: mode, sources: [Self.source()])

        #expect(!prompt.contains("Rappel du mode Fiable"))
    }

    /// Rapport T2, finding 4 : `<donnees_widgets>` arrive après le rappel ; un
    /// refus exact y ferait refuser une question mixte malgré un widget valide.
    @Test("Mode Fiable avec données de widgets : rappel adapté, qui ne demande jamais le refus exact")
    func reliableReminderWithWidgetDataNeverAsksForTheRefusal() throws {
        let prompt = Self.fullWriterPrompt(mode: .reliable, sources: [Self.source()], hasWidgetData: true)

        let reminder = try #require(prompt.range(of: Self.reliableReminderOpening))
        let tail = prompt[reminder.upperBound...]
        #expect(tail.contains("données des widgets"))
        #expect(tail.contains("n'utilise pas tes connaissances générales"))
        #expect(!tail.contains(PromptTemplates.noRelevantInformationAnswer))
        #expect(Self.fullWriterPrompt(mode: .quick, sources: [Self.source()], hasWidgetData: true) == Self.fullWriterPrompt(mode: .quick, sources: [Self.source()]))
    }

    @Test("Checklist : la règle des numéros ne parle plus d'un nombre de documents, faux avec un trou de numérotation")
    func checklistCitationRuleToleratesNumberingGaps() {
        let checklist = PromptTemplates.checklistSection(for: .quick, complexity: .full)

        #expect(checklist.contains("Chaque numéro de citation est celui d'un document du contexte, et aucun n'est [0]."))
        #expect(!checklist.contains("nombre de documents"))
    }

    // MARK: - Injection du contexte

    @Test("Le contexte est numéroté sous la forme exacte demandée au modèle : [1], titre, URL, extrait")
    func numberedContextUsesCitationForm() {
        let context = PromptTemplates.numberedContext(sources: [Self.source()])

        #expect(context.hasPrefix("[1] Wikipédia — Photosynthèse"))
        #expect(context.contains("https://fr.wikipedia.org/wiki/Photosynthese"))
        #expect(context.contains("Extrait : La photosynthèse convertit la lumière en énergie chimique."))
    }

    @Test("Deux sources donnent deux numéros consécutifs")
    func numberedContextNumbersEverySource() {
        let context = PromptTemplates.numberedContext(sources: [
            Self.source(title: "Première", url: "https://exemple.fr/a"),
            Self.source(title: "Seconde", url: "https://exemple.fr/b"),
        ])

        #expect(context.contains("[1] Première"))
        #expect(context.contains("[2] Seconde"))
        #expect(PromptTemplates.citableDocumentCount(sources: [
            Self.source(title: "Première", url: "https://exemple.fr/a"),
            Self.source(title: "Seconde", url: "https://exemple.fr/b"),
        ]) == 2)
    }

    @Test("Contexte vide : phrase explicite plutôt qu'un bloc vide, et zéro document citable")
    func emptyContextIsExplicit() {
        #expect(PromptTemplates.numberedContext(sources: [], scrapedPages: []) == "Aucune source disponible.")
        #expect(PromptTemplates.citableDocumentCount(sources: [], scrapedPages: []) == 0)
    }

    @Test("Une page scrapée dont l'URL est déjà une source est FUSIONNÉE dans son document, pas numérotée deux fois")
    func scrapedPageIsMergedIntoItsSource() {
        let sources = [Self.source(url: "https://exemple.fr/article")]
        // Slash final : la normalisation doit reconnaître la même page.
        let pages = [Self.page(url: "https://exemple.fr/article/")]

        let context = PromptTemplates.numberedContext(sources: sources, scrapedPages: pages)

        #expect(PromptTemplates.citableDocumentCount(sources: sources, scrapedPages: pages) == 1)
        #expect(!context.contains("[2]"))
        #expect(context.contains("Contenu de la page : Contenu complet de la page scrapée."))
    }

    @Test("Une page scrapée absente des sources obtient son propre numéro, à la suite")
    func orphanScrapedPageGetsItsOwnNumber() {
        let sources = [Self.source(url: "https://exemple.fr/article")]
        let pages = [Self.page(url: "https://autre.fr/page", title: "Page orpheline")]

        let context = PromptTemplates.numberedContext(sources: sources, scrapedPages: pages)

        #expect(PromptTemplates.citableDocumentCount(sources: sources, scrapedPages: pages) == 2)
        #expect(context.contains("[2] Page orpheline"))
    }

    @Test("Les pages scrapées en échec ou vides sont ignorées : pas de document citable creux")
    func failedOrEmptyScrapedPagesAreIgnored() {
        let sources = [Self.source(url: "https://exemple.fr/article")]
        let pages = [
            Self.page(url: "https://echec.fr/page", content: "", succeeded: false),
            Self.page(url: "https://vide.fr/page", content: "", succeeded: true),
        ]

        #expect(PromptTemplates.citableDocumentCount(sources: sources, scrapedPages: pages) == 1)
    }

    @Test("Le budget de caractères scrapés est réparti entre les documents et tronque le contenu")
    func scrapedContentIsTruncatedWithinBudget() {
        let longContent = String(repeating: "a", count: 500)
        let sources = [
            Self.source(title: "A", url: "https://exemple.fr/a", content: nil),
            Self.source(title: "B", url: "https://exemple.fr/b", content: nil),
        ]
        let pages = [
            Self.page(url: "https://exemple.fr/a", content: longContent),
            Self.page(url: "https://exemple.fr/b", content: longContent),
        ]

        // 200 caractères de budget pour 2 documents scrapés = 100 chacun.
        let context = PromptTemplates.numberedContext(
            sources: sources,
            scrapedPages: pages,
            maxScrapedContextCharacters: 200
        )

        #expect(!context.contains(longContent))
        #expect(context.contains(String(repeating: "a", count: 100)))
        #expect(!context.contains(String(repeating: "a", count: 101)))
    }

    // MARK: - Injection de l'historique et de la date

    @Test("L'historique de conversation est injecté avec les rôles en français")
    func historyIsInjected() {
        let prompt = PromptTemplates.writerPrompt(
            query: "Et le rendement ?",
            sources: [Self.source()],
            chatHistory: Self.history,
            mode: .deep,
            currentDate: Self.fixedDate
        )

        #expect(prompt.contains("Utilisateur : Parle-moi de la photosynthèse"))
        #expect(prompt.contains("Assistant : C'est le processus qui transforme la lumière."))
        #expect(prompt.contains("Et le rendement ?"))
    }

    @Test("Historique vide : phrase explicite, jamais un bloc vide")
    func emptyHistoryIsExplicit() {
        #expect(PromptTemplates.formattedHistory([]) == "Aucun échange précédent.")
    }

    @Test("L'historique est tronqué aux derniers messages, comme dans QueryClassifier")
    func historyIsTruncatedToLastMessages() {
        let longHistory = (1...12).map { ClassifierChatMessage(role: .user, content: "message \($0)") }

        let formatted = PromptTemplates.formattedHistory(longHistory, maxHistoryMessages: 3)

        #expect(!formatted.contains("message 9"))
        #expect(formatted.contains("message 10"))
        #expect(formatted.contains("message 12"))
    }

    @Test("Un maxHistoryMessages négatif ne trappe pas : repli sur aucun message gardé")
    func negativeHistoryLimitDoesNotTrap() {
        #expect(PromptTemplates.formattedHistory(Self.history, maxHistoryMessages: -5) == "Aucun échange précédent.")
    }

    @Test("Bug 1 : un message d'historique trop long est coupé sur une fin de phrase et marqué « […] »")
    func longHistoryMessageIsCutAtSentenceBoundary() {
        let longAnswer = String(repeating: "La photosynthèse produit du glucose. ", count: 100)

        let formatted = PromptTemplates.formattedHistory(
            [ClassifierChatMessage(role: .assistant, content: longAnswer)],
            maxHistoryMessageCharacters: 80
        )

        // Frontières de phrase à 37 et 74 caractères : la coupe se fait à 74.
        #expect(formatted == "Assistant : La photosynthèse produit du glucose. La photosynthèse produit du glucose. […]")
    }

    @Test("Un message court reste intact ; un budget par message nul ou négatif vaut « aucun historique »")
    func shortHistoryMessageIsKeptAndNonPositiveBudgetDropsHistory() {
        let formatted = PromptTemplates.formattedHistory(Self.history, maxHistoryMessageCharacters: 2000)

        #expect(formatted.contains("Assistant : C'est le processus qui transforme la lumière."))
        #expect(!formatted.contains("[…]"))
        #expect(PromptTemplates.formattedHistory(Self.history, maxHistoryMessageCharacters: 0) == "Aucun échange précédent.")
        #expect(PromptTemplates.formattedHistory(Self.history, maxHistoryMessageCharacters: -1) == "Aucun échange précédent.")
    }

    @Test("reformulationLine : omise si absente, blanche ou identique à la question (casse et accents ignorés)")
    func reformulationLineIsOmittedWhenRedundant() {
        #expect(PromptTemplates.reformulationLine(query: "Et son salaire ?", standaloneQuery: nil) == "")
        #expect(PromptTemplates.reformulationLine(query: "Et son salaire ?", standaloneQuery: " \n ") == "")
        #expect(PromptTemplates.reformulationLine(query: "Météo à Paris", standaloneQuery: " meteo a PARIS ") == "")
        #expect(
            PromptTemplates.reformulationLine(query: "Et son salaire ?", standaloneQuery: " Salaire de Tim Cook ")
                == "Question reformulée d'après la conversation : Salaire de Tim Cook\n"
        )
    }

    @Test("Bug 1 : la reformulation est donnée EN PLUS de la question d'origine, juste avant elle, dans les deux verbosités")
    func writerPromptAddsReformulationBeforeOriginalQuestion() {
        for complexity in [WriterPromptComplexity.full, .concise] {
            let prompt = PromptTemplates.writerPrompt(
                query: "Et son salaire ?",
                standaloneQuery: "Salaire de Tim Cook",
                sources: [Self.source()],
                mode: .quick,
                complexity: complexity,
                currentDate: Self.fixedDate
            )

            #expect(prompt.contains("Question reformulée d'après la conversation : Salaire de Tim Cook\nQuestion"))
            #expect(prompt.hasSuffix(": Et son salaire ?"))
        }
    }

    // MARK: - Réponse sans recherche (chemin .skip, bug 1)

    @Test("Bug 1 : le prompt sans recherche répond depuis la conversation — historique présent ; ni sources numérotées, ni contexte, ni phrase de refus")
    func conversationPromptAnswersFromHistory() {
        for mode in ResponseMode.allCases {
            for complexity in [WriterPromptComplexity.full, .concise] {
                let prompt = PromptTemplates.conversationPrompt(
                    query: "Traduis ta réponse en anglais",
                    chatHistory: Self.history,
                    mode: mode,
                    complexity: complexity,
                    currentDate: Self.fixedDate
                )
                let label = "mode \(mode.rawValue) / \(complexity)"

                #expect(prompt.contains("Assistant : C'est le processus qui transforme la lumière."), "\(label)")
                #expect(!prompt.contains("sources numérotées"), "\(label)")
                #expect(!prompt.contains("<contexte>"), "\(label)")
                #expect(!prompt.contains(PromptTemplates.noRelevantInformationAnswer), "\(label)")
                #expect(prompt.contains("1970-01-01T00:00:00Z"), "\(label)")
                #expect(prompt.hasSuffix(": Traduis ta réponse en anglais"), "\(label)")
                let emoji = prompt.unicodeScalars.filter { $0.properties.isEmoji && $0.value > 0x238C }
                #expect(emoji.isEmpty, "\(label) : emoji trouvé")
            }
        }
    }

    @Test("Mode Fiable sans recherche : l'avertissement « aucune source vérifiée » devient conditionnel, jamais imposé à une salutation")
    func reliableConversationPromptMakesWarningConditional() {
        let conversation = PromptTemplates.conversationPrompt(query: "Bonjour", mode: .reliable, currentDate: Self.fixedDate)
        let writer = PromptTemplates.writerPrompt(query: "Bonjour", sources: [], mode: .reliable, currentDate: Self.fixedDate)

        #expect(conversation.contains("une salutation ou une reprise de la conversation n'en a pas besoin"))
        // Le prompt de rédaction, lui, l'impose sans condition dès 0 source.
        #expect(writer.contains("Si le contexte ne contient AUCUNE source, commence par exactement"))
        #expect(!conversation.contains("Si le contexte ne contient AUCUNE source"))
    }

    @Test("La date injectée est au format ISO 8601 UTC, indépendant de la locale de l'appareil")
    func injectedDateIsISO8601UTC() {
        #expect(PromptTemplates.formattedDate(Self.fixedDate) == "1970-01-01T00:00:00Z")

        let prompt = PromptTemplates.writerPrompt(
            query: "Quelle heure est-il ?",
            sources: [Self.source()],
            mode: .quick,
            currentDate: Self.fixedDate
        )
        #expect(prompt.contains("1970-01-01T00:00:00Z"))
    }

    // MARK: - Formulations bannies (source de vérité partagée avec le validateur)

    @Test("Les deux listes de formulations bannies sont non vides, sans doublon, et couvrent le français et l'anglais")
    func bannedPhraseListsAreWellFormed() {
        #expect(!PromptTemplates.bannedSpeculationPhrases.isEmpty)
        #expect(!PromptTemplates.bannedFillerPhrases.isEmpty)
        #expect(Set(PromptTemplates.allBannedPhrases).count == PromptTemplates.allBannedPhrases.count)

        // Le web liste les deux langues : le portage doit garder les deux.
        #expect(PromptTemplates.bannedFillerPhrases.contains("en résumé"))
        #expect(PromptTemplates.bannedFillerPhrases.contains("in summary"))
        #expect(PromptTemplates.bannedSpeculationPhrases.contains("il est probable que"))
        #expect(PromptTemplates.bannedSpeculationPhrases.contains("it is likely that"))
    }

    @Test("allBannedPhrases est exactement l'union des deux catégories, dans cet ordre")
    func allBannedPhrasesIsTheUnion() {
        #expect(
            PromptTemplates.allBannedPhrases
                == PromptTemplates.bannedSpeculationPhrases + PromptTemplates.bannedFillerPhrases
        )
    }

    @Test("Les formulations bannies sont en minuscules : la comparaison du validateur replie la casse")
    func bannedPhrasesAreLowercased() {
        for phrase in PromptTemplates.allBannedPhrases {
            #expect(phrase == phrase.lowercased(), "« \(phrase) » n'est pas en minuscules")
        }
    }

    @Test("Le prompt détaillé énumère réellement les formulations bannies plutôt que d'y faire allusion")
    func fullPromptListsBannedPhrases() {
        let prompt = PromptTemplates.writerPrompt(
            query: "Question",
            sources: [Self.source()],
            mode: .deep,
            complexity: .full,
            currentDate: Self.fixedDate
        )

        #expect(prompt.contains("« en résumé »"))
        #expect(prompt.contains("« il est probable que »"))
    }

    // MARK: - Conformité DESIGN.md

    @Test("Aucun emoji dans les prompts : le texte produit par le modèle s'affiche tel quel dans l'UI")
    func promptsContainNoEmoji() {
        for mode in ResponseMode.allCases {
            for complexity in [WriterPromptComplexity.full, .concise] {
                let prompt = PromptTemplates.writerPrompt(
                    query: "Question",
                    sources: [Self.source()],
                    mode: mode,
                    complexity: complexity,
                    currentDate: Self.fixedDate
                )
                let emoji = prompt.unicodeScalars.filter { $0.properties.isEmoji && $0.value > 0x238C }
                #expect(emoji.isEmpty, "mode \(mode.rawValue) / \(complexity) : emoji trouvé")
            }
        }
    }

    @Test("Les marqueurs imposés au modèle sont en texte simple, sans emoji, contrairement au web")
    func mandatedMarkersAreEmojiFree() {
        let markers = [
            PromptTemplates.unsupportedClaimMarker,
            PromptTemplates.unverifiedSourcesWarning,
            PromptTemplates.noRelevantInformationAnswer,
            PromptTemplates.contradictorySourcesMarker,
        ]

        for marker in markers {
            #expect(!marker.contains("⚠️"))
            #expect(!marker.isEmpty)
        }
    }
}

// MARK: - Budgets par moteur (bug 6)

/// Budgets du pipeline par moteur (`SearchPipelineConfiguration`, défini dans
/// `SearchOrchestrator.swift`). Rangés ici parce que ce sont des budgets de
/// PROMPT, vérifiés sur les prompts réels — et parce que les deux fichiers de
/// tests de l'orchestrateur frôlent déjà la limite de 800 lignes.
@MainActor
@Suite("SearchPipelineConfiguration — budgets par moteur (bug 6)")
struct SearchPipelineConfigurationTests {
    private static func catalogEntry(capabilityScore: Int) -> MLXModelCatalogEntry {
        MLXModelCatalogEntry(
            id: "modele-\(capabilityScore)",
            displayName: "Modèle \(capabilityScore)",
            huggingFaceRepo: "mlx-community/modele-\(capabilityScore)",
            registryKey: nil,
            license: "apache-2.0",
            downloadSizeBytes: 1,
            recommendedGPUWorkingSetBytes: 1,
            capabilityScore: capabilityScore,
            supportsThinkingMode: true,
            isMixtureOfExperts: false,
            isAdvancedOnly: false,
            summary: "",
            strengths: [],
            tradeoffs: []
        )
    }

    /// Texte de remplissage fait de phrases (la coupe de l'historique se fait
    /// sur une fin de phrase), bien plus long que tout budget.
    private static let longText = String(repeating: "Une phrase de remplissage pour saturer le budget. ", count: 200)

    private static func source(_ index: Int) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: "Titre de source volontairement long, numéro \(index), pour le pire cas",
            url: "https://un-domaine-assez-long.example.fr/rubrique/sous-rubrique/article-\(index)",
            content: String(longText.prefix(300)),
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    @Test("Préréglage selon le moteur résolu : cloud, Apple Intelligence, MLX léger (0.6B, 1.7B ou modèle inconnu), MLX 4B et plus")
    func presetFollowsTheResolvedEngine() {
        #expect(SearchPipelineConfiguration.preset(for: .cloudBYOK) == .cloud)
        #expect(SearchPipelineConfiguration.preset(for: .appleIntelligence) == .appleIntelligence)
        #expect(SearchPipelineConfiguration.preset(for: .mlxLocal) == .mlxCompact)
        #expect(SearchPipelineConfiguration.preset(for: .mlxLocal, mlxModel: Self.catalogEntry(capabilityScore: 1)) == .mlxCompact)
        #expect(SearchPipelineConfiguration.preset(for: .mlxLocal, mlxModel: Self.catalogEntry(capabilityScore: 2)) == .mlxCompact)
        #expect(SearchPipelineConfiguration.preset(for: .mlxLocal, mlxModel: Self.catalogEntry(capabilityScore: 3)) == .mlx)
        #expect(SearchPipelineConfiguration.preset(for: .mlxLocal, mlxModel: Self.catalogEntry(capabilityScore: 7)) == .mlx)
    }

    @Test("Le préréglage cloud reprend exactement les défauts historiques : le comportement cloud ne change pas")
    func cloudPresetMatchesHistoricalDefaults() {
        let cloud = SearchPipelineConfiguration.cloud
        #expect(cloud.promptComplexity == .full)
        #expect(cloud.maxHistoryMessages == PromptTemplates.defaultMaxHistoryMessages)
        #expect(cloud.maxHistoryMessageCharacters == PromptTemplates.defaultMaxHistoryMessageCharacters)
        #expect(cloud.maxScrapedContextCharacters == PromptTemplates.defaultMaxScrapedContextCharacters)
        #expect(cloud.maxResultsUsedForContext == 5)
        #expect(cloud.maxScrapedURLsPerIteration == 3)
    }

    @Test("Prompts courts pour Apple Intelligence et MLX léger, budgets jamais plus larges que le cloud")
    func onDevicePresetsAreTighterThanCloud() {
        #expect(SearchPipelineConfiguration.appleIntelligence.promptComplexity == .concise)
        #expect(SearchPipelineConfiguration.mlxCompact.promptComplexity == .concise)
        #expect(SearchPipelineConfiguration.mlx.promptComplexity == .full)
        #expect(SearchPipelineConfiguration.appleIntelligence.classifierPromptComplexity == .concise)
        #expect(SearchPipelineConfiguration.cloud.classifierPromptComplexity == .full)

        for preset in [SearchPipelineConfiguration.appleIntelligence, .mlxCompact, .mlx] {
            #expect(preset.maxHistoryMessages <= SearchPipelineConfiguration.cloud.maxHistoryMessages)
            #expect(preset.maxHistoryMessageCharacters < SearchPipelineConfiguration.cloud.maxHistoryMessageCharacters)
            #expect(preset.maxScrapedContextCharacters < SearchPipelineConfiguration.cloud.maxScrapedContextCharacters)
        }
    }

    /// Le cas qui faisait déborder Apple Intelligence : longues réponses dans
    /// l'historique, pages scrapées pleines (4 000 caractères chacune, plafond
    /// de `ScrapeService`), 2 tours planner × 2 pages, question et
    /// reformulation de 300 caractères, dans le mode le plus bavard. Seule
    /// hypothèse : des extraits SearXNG de 300 caractères, que le pipeline ne
    /// borne pas lui-même.
    @Test("Apple Intelligence, pire cas : prompt de rédaction sous 10 000 caractères, prompt du classifieur sous 6 000")
    func appleIntelligenceWorstCaseFitsTheContextWindow() {
        let budget = SearchPipelineConfiguration.appleIntelligence
        let sources = (1...budget.maxResultsUsedForContext).map(Self.source)
        let pages = sources.prefix(2 * budget.maxScrapedURLsPerIteration).map { source in
            ScrapedPage(url: source.url, title: source.title, content: String(Self.longText.prefix(ScrapeService.defaultMaxContentCharactersPerPage)), succeeded: true)
        }
        let history = (0..<10).map { ClassifierChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: Self.longText) }
        let query = String(Self.longText.prefix(300))

        let writerLengths = ResponseMode.allCases.map { mode in
            SearchOrchestrator.buildPrompt(
                query: query,
                standaloneQuery: query + " ?",
                sources: sources,
                scrapedPages: Array(pages),
                chatHistory: history,
                mode: mode,
                complexity: budget.promptComplexity,
                maxHistoryMessages: budget.maxHistoryMessages,
                maxHistoryMessageCharacters: budget.maxHistoryMessageCharacters,
                maxScrapedContextCharacters: budget.maxScrapedContextCharacters
            ).count
        }
        let classifierPrompt = QueryClassifier.buildPrompt(
            query: query,
            chatHistory: SearchOrchestrator.boundedHistory(history, maxMessages: budget.maxHistoryMessages, maxCharacters: budget.maxHistoryMessageCharacters),
            maxHistoryMessages: budget.maxHistoryMessages,
            promptComplexity: budget.classifierPromptComplexity
        )

        let longestWriterPrompt = writerLengths.max() ?? .max
        #expect(longestWriterPrompt < 10_000, "pire cas mesuré : \(longestWriterPrompt) caractères")
        #expect(classifierPrompt.count < 6_000, "pire cas mesuré : \(classifierPrompt.count) caractères")
    }

    @Test("boundedHistory : derniers messages seulement, chacun coupé sur une fin de phrase et marqué « […] » ; budget nul = aucun historique")
    func boundedHistoryLimitsCountAndLength() {
        let history = [
            ClassifierChatMessage(role: .user, content: "Premier sujet abandonné"),
            ClassifierChatMessage(role: .assistant, content: "Réponse courte."),
            ClassifierChatMessage(role: .user, content: "Parle-moi de la photosynthèse"),
            ClassifierChatMessage(role: .assistant, content: String(repeating: "La photosynthèse produit du glucose. ", count: 100)),
        ]

        let bounded = SearchOrchestrator.boundedHistory(history, maxMessages: 2, maxCharacters: 80)

        #expect(bounded.map(\.role) == [.user, .assistant])
        #expect(bounded.first?.content == "Parle-moi de la photosynthèse")
        #expect(bounded.last?.content == "La photosynthèse produit du glucose. La photosynthèse produit du glucose. […]")
        #expect(SearchOrchestrator.boundedHistory(history, maxMessages: 2, maxCharacters: 0).isEmpty)
        #expect(SearchOrchestrator.boundedHistory(history, maxMessages: -1, maxCharacters: 80).isEmpty)
        #expect(SearchOrchestrator.boundedHistory(history, maxMessages: 8, maxCharacters: 2000).count == 4)
    }
}
