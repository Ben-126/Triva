//
//  SearchOrchestrator.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Résultat du pipeline (0.7) : le texte généré, accompagné des sources
/// effectivement utilisées comme contexte — utile pour 0.8, qui affiche une
/// liste de sources sous la réponse sans refaire de recherche.
struct SearchOrchestratorResult: Sendable, Equatable {
    let answer: String
    let sources: [SearXNGSearchResult]
}

/// Résultat du pipeline en streaming (0.8) : les sources sont déjà connues
/// (la recherche ET la boucle de recherche multi-actions sont terminées et
/// awaited) au moment où l'appelant les reçoit, seul le texte de réponse
/// arrive progressivement via `textStream`. `Equatable` non conformé
/// volontairement : un `AsyncThrowingStream` ne l'est pas.
struct StreamingAnswer: Sendable {
    let sources: [SearXNGSearchResult]
    let textStream: AsyncThrowingStream<String, Error>
}

/// Décision du planner (itérations 2+ de la boucle de recherche) : quelle
/// action lancer ensuite, avec quelles URLs le cas échéant. Port de la
/// boucle `for` de `researcher/index.ts` (web) — mais là où le TS délègue le
/// choix d'action à un vrai tool-calling LLM (schéma zod + function-calling
/// natif), ici la décision passe par un parsing JSON tolérant, même principe
/// que `QueryClassifier.parse` : aucun des 3 providers IA de Triva n'expose
/// de function-calling fiable.
struct PlannerDecision: Sendable, Equatable {
    let actionName: String
    let urls: [String]
    let reasoning: String?
}

/// Portage complet de l'orchestration multi-actions (1.2), remplace la
/// version minimale de 0.7 ("chercher puis répondre" sans classification).
/// Pipeline : `QueryClassifier` (1.1, un seul appel) décide l'action seedée
/// du 1er tour -> boucle planner bornée (`scrapeURL`/`done` uniquement, 2+
/// tours) -> sources + pages scrapées accumulées -> prompt enrichi -> réponse
/// (simple ou streaming). Le scoring des sources (`SourceRanker`, 1.3) et le
/// prompt writer complet avec citations `[n]` (1.4) restent hors scope :
/// `buildPrompt` reste volontairement simple, juste étendu pour absorber le
/// contenu scrapé.
struct SearchOrchestrator: Sendable {
    private let failoverManager: FailoverManager
    private let aiProvider: any AIGenerating
    private let queryClassifier: QueryClassifier
    private let scrapeService: any ScrapeServing
    private let maxResultsUsedForContext: Int
    private let maxIterations: Int
    private let maxScrapedURLsPerIteration: Int
    private let maxScrapedContextCharacters: Int

    /// `queryClassifier` par défaut résolu DANS le corps de l'init plutôt que
    /// via une valeur par défaut dans la signature : un paramètre par défaut
    /// ne peut pas référencer un autre paramètre du même init en Swift
    /// (`aiProvider` n'est pas encore un identifiant valide à ce point).
    ///
    /// `maxIterations` par défaut à 3 : 1 tour seedé par la classification +
    /// jusqu'à 2 tours planner (`2...maxIterations`, voir `runResearch`).
    /// `maxScrapedURLsPerIteration` à 3 et `maxScrapedContextCharacters` à
    /// 8000 (~2000 tokens, proxy caractères/4) : les constantes TS
    /// (3000 tokens/chunk * 4 chunks * jusqu'à 3 URLs ≈ 36k tokens)
    /// supposent une compression LLM par chunk absente ici et exploseraient
    /// le contexte d'un modèle on-device (Apple Intelligence ~4k tokens, MLX
    /// 0.5B/1.7B 2k-8k tokens) — porter ces constantes telles quelles serait
    /// un échec dur, pas une simple dégradation. Tous ces paramètres restent
    /// ajustables par provider actif sans changer de code.
    init(
        failoverManager: FailoverManager,
        aiProvider: any AIGenerating,
        queryClassifier: QueryClassifier? = nil,
        scrapeService: any ScrapeServing = ScrapeService(),
        maxResultsUsedForContext: Int = 5,
        maxIterations: Int = 3,
        maxScrapedURLsPerIteration: Int = 3,
        maxScrapedContextCharacters: Int = 8000
    ) {
        self.failoverManager = failoverManager
        self.aiProvider = aiProvider
        self.queryClassifier = queryClassifier ?? QueryClassifier(aiProvider: aiProvider)
        self.scrapeService = scrapeService
        self.maxResultsUsedForContext = maxResultsUsedForContext
        self.maxIterations = maxIterations
        self.maxScrapedURLsPerIteration = maxScrapedURLsPerIteration
        self.maxScrapedContextCharacters = maxScrapedContextCharacters
    }

    func answer(query: String, chatHistory: [ClassifierChatMessage] = []) async throws -> SearchOrchestratorResult {
        let (sources, scrapedPages) = try await runResearch(query: query, chatHistory: chatHistory)
        let boundedSources = Array(sources.prefix(maxResultsUsedForContext))
        let prompt = Self.buildPrompt(
            query: query,
            sources: boundedSources,
            scrapedPages: scrapedPages,
            maxScrapedContextCharacters: maxScrapedContextCharacters
        )
        let answerText = try await aiProvider.generate(prompt: prompt)
        return SearchOrchestratorResult(answer: answerText, sources: boundedSources)
    }

    /// Même pipeline que `answer(query:chatHistory:)` jusqu'à la construction
    /// du prompt (classification, boucle de recherche et scrapes sont tous
    /// awaited ICI, pas dans le flux renvoyé — contrat déjà établi en 0.8 :
    /// `ChatViewModel` attache `StreamingAnswer.sources` AVANT d'itérer
    /// `textStream`, donc toute l'orchestration doit être terminée avant de
    /// construire le flux) ; seule la génération finale est déléguée à
    /// `aiProvider.streamGenerate(prompt:)`.
    func streamAnswer(query: String, chatHistory: [ClassifierChatMessage] = []) async throws -> StreamingAnswer {
        let (sources, scrapedPages) = try await runResearch(query: query, chatHistory: chatHistory)
        let boundedSources = Array(sources.prefix(maxResultsUsedForContext))
        let prompt = Self.buildPrompt(
            query: query,
            sources: boundedSources,
            scrapedPages: scrapedPages,
            maxScrapedContextCharacters: maxScrapedContextCharacters
        )
        let textStream = aiProvider.streamGenerate(prompt: prompt)
        return StreamingAnswer(sources: boundedSources, textStream: textStream)
    }

    /// Coeur de l'orchestration, partagé par `answer` et `streamAnswer` (seule
    /// la génération finale diffère entre les deux) :
    /// 1. Classification (1 seul appel `QueryClassifier.classify`, comme
    ///    côté web où le classifieur tourne une fois en amont du chercheur).
    /// 2. `.skip` : court-circuit total, comme le macro-niveau de
    ///    `search/index.ts` (web) — aucune action lancée, sources/pages
    ///    vides, direction directe vers la génération.
    /// 3. Sinon : la classification SEEDE le 1er tour (mappée vers une
    ///    `SearchAction` concrète via `Self.action(for:)`) — pas d'appel
    ///    planner pour ce tour, on a déjà payé pour `classify()`.
    /// 4. Boucle planner bornée `2...maxIterations` (donc `maxIterations - 1`
    ///    tours planner au maximum) : à chaque tour, un appel
    ///    `aiProvider.generate(plannerPrompt)` tranché par
    ///    `decideNextAction` — "done" (ou toute sortie imparsable/nom
    ///    d'action inconnu, replis sûrs identiques) sort de la boucle SANS
    ///    exécuter d'action supplémentaire, "scrapeURL" lance un scrape
    ///    parallèle borné par URL.
    private func runResearch(
        query: String,
        chatHistory: [ClassifierChatMessage]
    ) async throws -> (sources: [SearXNGSearchResult], scrapedPages: [ScrapedPage]) {
        let classification = await Self.classifyWithFallback(query: query, chatHistory: chatHistory, using: queryClassifier)

        guard classification.primaryAction != .skip else {
            return ([], [])
        }

        var sources: [SearXNGSearchResult] = []
        var scrapedPages: [ScrapedPage] = []

        if let seededAction = Self.action(for: classification.primaryAction) {
            let output = try await seededAction.execute(
                query: query,
                urls: [],
                failoverManager: failoverManager,
                scrapeService: scrapeService
            )
            Self.accumulate(output, sources: &sources, scrapedPages: &scrapedPages)
        }

        if maxIterations >= 2 {
            for iteration in 2...maxIterations {
                let plannerText = Self.plannerPrompt(
                    query: query,
                    accumulatedSources: sources,
                    availableActionNames: ["scrapeURL", "done"],
                    iteration: iteration,
                    maxIterations: maxIterations
                )
                let rawOutput = try await aiProvider.generate(prompt: plannerText)
                let decision = Self.decideNextAction(rawOutput: rawOutput)

                if decision.actionName == "done" {
                    break
                } else if decision.actionName == "scrapeURL" {
                    let urlsToScrape = Array(decision.urls.prefix(maxScrapedURLsPerIteration))
                    guard !urlsToScrape.isEmpty else { break }
                    let pages = await Self.scrapeAll(urlsToScrape, using: scrapeService)
                    scrapedPages.append(contentsOf: pages)
                } else {
                    // Nom d'action inconnu du planner : repli sûr identique à
                    // "done", jamais de crash sur une sortie LLM imprévue.
                    break
                }
            }
        }

        return (sources, scrapedPages)
    }

    /// Isole l'appel à `QueryClassifier.classify`, seul maillon de la boucle
    /// de recherche qui pouvait encore faire échouer TOUT le pipeline
    /// (`throw`, propagé jusqu'à `answer`/`streamAnswer`) sur un simple aléa
    /// réseau/provider — contrairement à `QueryClassifier.parse` (jamais de
    /// `throw` sur une sortie mal formée) et au planner (`decideNextAction`,
    /// repli "done" systématique). Un échec ICI ne doit pas empêcher de
    /// répondre : on retombe sur la même classification "sûre" que
    /// `QueryClassifier.parse` utilise déjà pour une sortie imparsable (tous
    /// les booléens à `false` -> `primaryAction == .webSearch`), pour rester
    /// cohérent avec la dégradation gracieuse déjà établie plutôt que
    /// d'ajouter un deuxième comportement de repli différent.
    private static func classifyWithFallback(
        query: String,
        chatHistory: [ClassifierChatMessage],
        using classifier: QueryClassifier
    ) async -> QueryClassification {
        do {
            return try await classifier.classify(query: query, chatHistory: chatHistory)
        } catch {
            return QueryClassification(
                skipSearch: false,
                personalSearch: false,
                academicSearch: false,
                discussionSearch: false,
                showWeatherWidget: false,
                showStockWidget: false,
                showCalculationWidget: false,
                standaloneFollowUp: query
            )
        }
    }

    /// Lance un scrape par URL EN PARALLÈLE (`TaskGroup`) : `scrape(url:)` ne
    /// throw JAMAIS (voir `ScrapeService`), donc pas de `try` ici — un échec
    /// individuel produit un `ScrapedPage(succeeded: false)` conservé plutôt
    /// que de disparaître silencieusement (une trace d'échec reste utile).
    private static func scrapeAll(_ urls: [String], using scrapeService: any ScrapeServing) async -> [ScrapedPage] {
        await withTaskGroup(of: ScrapedPage.self) { group in
            for url in urls {
                group.addTask { await scrapeService.scrape(url: url) }
            }
            var results: [ScrapedPage] = []
            for await page in group {
                results.append(page)
            }
            return results
        }
    }

    /// Mappe l'action principale décidée par `QueryClassifier` (1.1) vers une
    /// `SearchAction` concrète. `.skip` est traité en amont dans
    /// `runResearch` (court-circuit total avant même d'appeler cette
    /// fonction), donc jamais atteint ici. Les widgets et `.personalSearch`
    /// retombent tous sur `WebSearchAction` — pas encore implémentés
    /// (widgets : tâche 1.5 ; documents importés : aucun stockage de document
    /// côté app aujourd'hui) : mieux vaut une recherche web dégradée mais
    /// utile qu'un silence total ou un crash.
    private static func action(for primaryAction: ClassifiedAction) -> (any SearchAction)? {
        switch primaryAction {
        case .skip:
            return nil
        case .weatherWidget, .stockWidget, .calculationWidget:
            return WebSearchAction()
        case .personalSearch:
            return WebSearchAction()
        case .academicSearch:
            return AcademicSearchAction()
        case .discussionSearch:
            return SocialSearchAction()
        case .webSearch:
            return WebSearchAction()
        }
    }

    private static func accumulate(
        _ output: SearchActionOutput,
        sources: inout [SearXNGSearchResult],
        scrapedPages: inout [ScrapedPage]
    ) {
        switch output {
        case .searchResults(let results):
            // Dédoublonnage par URL, comme côté web (`researcher/index.ts`) :
            // conserve l'ordre d'arrivée, ignore les doublons ultérieurs.
            let existingURLs = Set(sources.map(\.url))
            for result in results where !existingURLs.contains(result.url) {
                sources.append(result)
            }
        case .scrapedPages(let pages):
            scrapedPages.append(contentsOf: pages)
        case .reasoning, .done:
            break
        }
    }

    // MARK: - Prompts et parsing, fonctions pures testables (pas `private`)

    /// Construction du prompt final, étendue par rapport à la version 0.7
    /// pour absorber le contenu scrapé (`scrapedPages`) en plus des sources
    /// de recherche brutes. Toujours sans règle anti-remplissage ni exigence
    /// de citation `[n]` — le prompt writer complet est la tâche 1.4.
    static func buildPrompt(
        query: String,
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = [],
        maxScrapedContextCharacters: Int = 8000
    ) -> String {
        let sourcesContext = sources.enumerated()
            .map { index, result in
                "<result index=\(index + 1) title=\"\(result.title)\">\(result.content ?? "")</result>"
            }
            .joined(separator: "\n")

        let scrapedContext = Self.formatScrapedPages(scrapedPages, maxTotalCharacters: maxScrapedContextCharacters)

        return """
        Réponds à la question de l'utilisateur en te basant sur le contexte de recherche ci-dessous.

        Contexte de recherche :
        \(sourcesContext)
        \(scrapedContext)

        Question : \(query)
        """
    }

    /// Protection anti-overflow NIVEAU 2 (globale) : répartit
    /// `maxTotalCharacters` équitablement entre TOUTES les pages scrapées
    /// avec succès, chaque page tronquée à SA part au moment de la
    /// construction du prompt — plutôt qu'un plafond consommé au fil de
    /// l'eau qui laisserait la première page scrapée manger tout le budget.
    /// Complète la protection NIVEAU 1, par page, déjà appliquée dans
    /// `ScrapeService` (`maxContentCharactersPerPage`, un seul chunk gardé
    /// par page). Les pages en échec (`succeeded == false`) sont ignorées :
    /// rien d'utile à injecter dans le prompt.
    private static func formatScrapedPages(_ pages: [ScrapedPage], maxTotalCharacters: Int) -> String {
        let successfulPages = pages.filter(\.succeeded)
        guard !successfulPages.isEmpty, maxTotalCharacters > 0 else { return "" }

        let budgetPerPage = max(1, maxTotalCharacters / successfulPages.count)
        let formatted = successfulPages
            .map { page in "<scraped url=\"\(page.url)\" title=\"\(page.title)\">\(page.content.prefix(budgetPerPage))</scraped>" }
            .joined(separator: "\n")

        return "\n" + formatted
    }

    /// Prompt du planner (itérations 2+) : contrairement au tool-calling
    /// natif de `researcher/index.ts` (web), demande explicitement un JSON
    /// `{ "action": ..., "urls": [...], "reasoning": ... }`, même approche
    /// tolérante que `QueryClassifier.buildPrompt`. Le marqueur
    /// `<planner_context>` (absent du prompt de classification ET du prompt
    /// final) permet de distinguer sans ambiguïté un prompt de planificateur
    /// des deux autres étapes — utile aux mocks de test comme au débogage.
    static func plannerPrompt(
        query: String,
        accumulatedSources: [SearXNGSearchResult],
        availableActionNames: [String],
        iteration: Int,
        maxIterations: Int
    ) -> String {
        let sourcesSummary = accumulatedSources.enumerated()
            .map { index, result in "\(index + 1). \(result.title) — \(result.url)" }
            .joined(separator: "\n")

        return """
        Tu es un agent de recherche. Itération \(iteration)/\(maxIterations).

        <planner_context>
        Requête de l'utilisateur : \(query)

        Sources déjà trouvées :
        \(sourcesSummary)

        Actions disponibles : \(availableActionNames.joined(separator: ", "))
        - "scrapeURL" : récupère le contenu complet d'1 à 3 URLs parmi les sources ci-dessus, pour approfondir la réponse. Fournis "urls" avec les URLs exactes à scraper.
        - "done" : arrête la recherche, les sources actuelles suffisent pour répondre.
        </planner_context>

        Réponds STRICTEMENT avec ce JSON, sans aucun texte autour :
        {
          "action": "scrapeURL" ou "done",
          "urls": ["url1", "url2"],
          "reasoning": "courte explication"
        }
        """
    }

    /// Parsing tolérant, même principe que `QueryClassifier.parse` : jamais
    /// de `throw`, un JSON introuvable/invalide/mal typé retombe sur
    /// `fallbackActionName` ("done" par défaut) — garantit la terminaison de
    /// la boucle planner quelle que soit la sortie du LLM.
    static func decideNextAction(rawOutput: String, fallbackActionName: String = "done") -> PlannerDecision {
        let fallback = PlannerDecision(actionName: fallbackActionName, urls: [], reasoning: nil)

        for candidate in Self.jsonCandidates(from: rawOutput) {
            guard
                let data = candidate.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(RawPlannerResponse.self, from: data),
                let actionName = decoded.action
            else { continue }

            return PlannerDecision(actionName: actionName, urls: decoded.urls ?? [], reasoning: decoded.reasoning)
        }

        return fallback
    }

    /// Extraction de candidats JSON dupliquée depuis `QueryClassifier`
    /// (blocs de code markdown, puis repli sur la sous-chaîne entre la
    /// première `{` et la dernière `}`) plutôt que partagée :
    /// `QueryClassifier.jsonCandidates` est `private`, et ce fichier reste
    /// hors du scope autorisé de modification de `QueryClassifier.swift`
    /// (voir consignes de la tâche 1.2).
    private static func jsonCandidates(from rawOutput: String) -> [String] {
        var candidates: [String] = []
        for fencedBlock in Self.extractFencedBlocks(from: rawOutput) {
            candidates.append(Self.extractBracesSubstring(from: fencedBlock) ?? fencedBlock)
        }
        if let braces = Self.extractBracesSubstring(from: rawOutput) {
            candidates.append(braces)
        }
        return candidates
    }

    private static func extractFencedBlocks(from rawOutput: String) -> [String] {
        let fenceComponents = rawOutput.components(separatedBy: "```")
        guard fenceComponents.count >= 3 else { return [] }
        var blocks: [String] = []
        var index = 1
        while index < fenceComponents.count {
            var block = fenceComponents[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if block.hasPrefix("json") {
                block.removeFirst("json".count)
            }
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            index += 2
        }
        return blocks
    }

    private static func extractBracesSubstring(from rawOutput: String) -> String? {
        guard
            let firstBrace = rawOutput.firstIndex(of: "{"),
            let lastBrace = rawOutput.lastIndex(of: "}"),
            firstBrace < lastBrace
        else { return nil }
        return String(rawOutput[firstBrace...lastBrace])
    }

    private struct RawPlannerResponse: Decodable {
        let action: String?
        let urls: [String]?
        let reasoning: String?
    }
}
