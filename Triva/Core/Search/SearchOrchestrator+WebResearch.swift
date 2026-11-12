//
//  SearchOrchestrator+WebResearch.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Recherche web de l'orchestrateur (découpage E1b) : tour seedé, médias en parallèle, lecture sans LLM
/// et boucle planner. Les propriétés stockées lues ici ne sont pas `private` dans
/// `SearchOrchestrator.swift` (voir le commentaire de leur liste) ; `WebResearch` et
/// `webResearchAlongsideMedia` sont appelés par `gather`, resté dans le fichier principal.
extension SearchOrchestrator {
    /// Recherche web : sources classées, pages scrapées, et documents trouvés
    /// par le planner (`uploadsSearch`).
    nonisolated struct WebResearch: Sendable {
        let documents: [SearXNGSearchResult]
        let sources: [SearXNGSearchResult]
        let scrapedPages: [ScrapedPage]
        /// Source qui a fourni le tour seedé (RI1b).
        let webSourceKind: WebSearchSourceKind
        /// Constat de la chaîne sur ce tour (mission A2).
        let webSearchReport: WebSearchChainReport
    }

    /// Événement de la recherche web menée en parallèle des médias.
    private nonisolated enum ParallelSearchEvent: Sendable {
        case research(WebResearch)
        case media(MediaSearchResults)
        case mediaGraceExpired
    }

    /// Recherche web et médias EN PARALLÈLE (1.6), jamais en série : deux
    /// tâches d'un même groupe. Les médias ne nourrissent pas le prompt :
    /// une fois la recherche texte finie, ils ont encore `mediaGracePeriod`
    /// pour arriver, puis valent `.failed` et sont annulés. Une erreur de la
    /// recherche texte (ou une annulation) remonte et annule les médias ; un
    /// échec des médias ne lève jamais (`MediaSearchResults.search`).
    /// `Task.sleep` (temps réel) plutôt que `clock` : l'horloge injectée ne
    /// mesure que les tours de scrape.
    nonisolated func webResearchAlongsideMedia(
        flavor: WebSearchFlavor,
        uploads: UploadsSearchAction?,
        searchQuery: String,
        mediaKinds: MediaSearchKinds
    ) async throws -> (WebResearch, MediaSearchResults) {
        guard !mediaKinds.isEmpty else {
            return (try await webResearch(flavor: flavor, uploads: uploads, searchQuery: searchQuery), .notRequested)
        }
        let searcher = mediaSearcher
        let grace = mediaGracePeriod
        return try await withThrowingTaskGroup(of: ParallelSearchEvent.self) { group in
            group.addTask { .research(try await self.webResearch(flavor: flavor, uploads: uploads, searchQuery: searchQuery)) }
            group.addTask { .media(await MediaSearchResults.search(mediaKinds, query: searchQuery, using: searcher)) }
            var research: WebResearch?
            var media: MediaSearchResults?
            while let event = try await group.next() {
                switch event {
                case .research(let outcome):
                    research = outcome
                    if media == nil {
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .mediaGraceExpired
                        }
                    }
                case .media(let results):
                    media = media ?? results
                case .mediaGraceExpired:
                    media = media ?? .failed(mediaKinds)
                }
                if let research, let media {
                    group.cancelAll()
                    return (research, media)
                }
            }
            // Inatteignable : la tâche de recherche rend un événement ou lève.
            throw CancellationError()
        }
    }

    /// Recherche web d'une route `.web` :
    /// 1. la classification SEEDE le 1er tour — pas d'appel planner pour ce
    ///    tour, on a déjà payé pour `classify()` (repli web du bug 5 compris,
    ///    voir `seededSearch`) ;
    /// 2. classement (1.3) des résultats du tour seedé, UNE fois : la boucle
    ///    planner ne fait que scraper (ou consulter les fichiers joints), elle
    ///    n'ajoute jamais de source web. Si un jour le planner peut relancer
    ///    une recherche web, il faudra reclasser après chaque tour ;
    /// 3. lecture sans LLM des sources classées SANS EXTRAIT, dans tous les
    ///    modes (mission A1, `SearchOrchestrator+PreRead.swift`) : le repli
    ///    cloud rend des URL nues, et le mode Rapide n'a pas de planner pour
    ///    les lire ;
    /// 4. boucle planner sur les seules sources classées, qui sait ces pages
    ///    déjà tentées, puis `pagesBackedBySources` : invariant des citations
    ///    garanti en un seul point, quelle que soit l'origine d'une page.
    private nonisolated func webResearch(flavor: WebSearchFlavor, uploads: UploadsSearchAction?, searchQuery: String) async throws -> WebResearch {
        let seeded = try await seededSearch(flavor: flavor, query: searchQuery)
        var searchResults: [SearXNGSearchResult] = []
        var seededPages: [ScrapedPage] = []
        Self.accumulate(seeded.output, sources: &searchResults, scrapedPages: &seededPages)

        // `searchResults` est encore dans l'ordre rendu par le moteur
        // (`accumulate` conserve l'ordre d'arrivée) : c'est le contrat
        // d'entrée de `SourceRanker.rank`, dont 30 % du score dérive de la
        // position. Le filtre "sources fiables" s'y applique AVANT le
        // scoring, et peut légitimement tout retirer (mode Fiable sans
        // aucun domaine fiable) : on n'y retombe jamais sur des sources non
        // fiables, `PromptTemplates` gère alors l'avertissement dédié.
        let sources = await sourceRanker.rank(
            query: searchQuery,
            results: searchResults,
            limit: maxResultsUsedForContext,
            trustedDomainsOnly: restrictsToTrustedDomains
        ).map(\.result)

        // Copie locale : voir `runPlannerLoop` (SE-0352).
        let roundClock = clock
        let alreadyRead = try await Self.preRead(
            sources,
            using: scrapeService,
            timeout: Self.preReadTimeout(for: responseMode, scrapeRoundTimeout: scrapeRoundTimeout),
            clock: roundClock
        )
        let harvest = try await runPlannerLoop(query: searchQuery, sources: sources, uploads: uploads, alreadyRead: alreadyRead)
        let pages = Self.pagesBackedBySources(seededPages + harvest.pages, sources: sources)
        return WebResearch(
            documents: harvest.documents,
            sources: sources,
            scrapedPages: pages,
            webSourceKind: seeded.sourceKind,
            webSearchReport: seeded.report
        )
    }

    /// Tour seedé, avec le repli du bug 5 (sans chaîne) ou la chaîne de repli
    /// de la recherche web (RI1b) : logique et documentation dans
    /// `SearchOrchestrator+WebSearchChain.swift` (`seededWebSearch`).
    private nonisolated func seededSearch(flavor: WebSearchFlavor, query: String) async throws -> SeededWebSearch {
        try await Self.seededWebSearch(
            flavor: flavor,
            query: query,
            webSearchChain: webSearchChain,
            trustedDomainsOnly: restrictsToTrustedDomains,
            failoverManager: failoverManager
        )
    }

    /// Boucle planner bornée `2...maxIterations` (donc `maxIterations - 1`
    /// tours au plus, aucun en mode Rapide où `maxIterations` vaut 1).
    ///
    /// - Aucun tour sans source (bug 8) : le planner ne peut scraper que des
    ///   sources affichées, il n'aurait rien à choisir.
    /// - Mémoire des URLs déjà tentées, succès comme échec (bug 11) : sans
    ///   elle, le prompt du tour 3 était identique à celui du tour 2 et le
    ///   modèle redemandait les mêmes pages, téléchargées deux fois. Elle
    ///   alimente `scrapableURLs` (filtre) ET `plannerPrompt` (le modèle sait
    ///   ce qui est déjà lu). Un tour qui ne propose rien de neuf, ou plus
    ///   rien à proposer, termine la boucle.
    /// - Annulation vérifiée à chaque tour et après chaque série de scrapes
    ///   (bug 3) : `scrapeAll` ne lève jamais.
    /// - Fichiers joints (1.11) : `uploadsSearch` est proposé tant qu'il n'a
    ///   pas servi, UNE fois au plus (un second passage reclasserait les
    ///   mêmes fragments, pour un coût d'embeddings de plusieurs secondes sur
    ///   l'appareil). Les documents trouvés s'ajoutent en tête des sources.
    /// - Pages déjà lues sans LLM (`alreadyRead`, mission A1) : elles ouvrent
    ///   la récolte et comptent comme tentées, succès comme échec — le
    ///   planner les voit déjà lues et ne les redemande pas ; toutes lues, il
    ///   ne reste rien à scraper et aucun tour (donc aucun appel LLM) n'a
    ///   lieu. Sans planner (mode Rapide), elles sont rendues telles quelles :
    ///   c'est tout l'intérêt de les lire avant.
    private nonisolated func runPlannerLoop(
        query: String,
        sources: [SearXNGSearchResult],
        uploads: UploadsSearchAction?,
        alreadyRead: [ScrapedPage]
    ) async throws -> PlannerHarvest {
        let preRead = PlannerHarvest(pages: alreadyRead)
        guard maxIterations >= 2, !sources.isEmpty || uploads != nil else { return preRead }

        let sourceKeys = Set(sources.map { Self.urlKey($0.url) })
        // Copie locale indispensable : passée directement, la propriété
        // `any Clock` n'est pas ouverte vers le générique de `scrapeAll`
        // (SE-0352) dès que Foundation est importé — vérifié en Swift 6.4.
        let roundClock = clock
        var attemptedKeys = Set(alreadyRead.map { Self.urlKey($0.url) })
        var pendingUploads = uploads
        var harvest = preRead
        for iteration in 2...maxIterations {
            try Task.checkCancellation()
            let canScrape = !sourceKeys.isSubset(of: attemptedKeys)
            guard canScrape || pendingUploads != nil else { break }

            let actionNames = Self.plannerActionNames(canScrape: canScrape, canSearchUploads: pendingUploads != nil)
            let decision = try await nextPlannerDecision(
                query: query,
                sources: sources,
                scrapedPages: harvest.pages,
                actionNames: actionNames,
                iteration: iteration
            )
            if decision.actionName == Self.uploadsSearchActionName, let uploadsAction = pendingUploads {
                pendingUploads = nil
                harvest.documents = try await uploadsAction.search(queries: decision.queries.isEmpty ? [query] : decision.queries)
                continue
            }
            // "done", action inconnue ou indisponible, sortie imparsable ou
            // planner en échec : même repli sûr, jamais d'action supplémentaire.
            guard canScrape, decision.actionName == Self.scrapeActionName else { break }

            let urls = Self.scrapableURLs(
                decision.urls,
                displayedSources: sources,
                alreadyAttempted: attemptedKeys,
                limit: maxScrapedURLsPerIteration
            )
            guard !urls.isEmpty else { break }
            attemptedKeys.formUnion(urls.map { Self.urlKey($0) })

            let pages = await Self.scrapeAll(urls, using: scrapeService, timeout: scrapeRoundTimeout, clock: roundClock)
            try Task.checkCancellation()
            harvest.pages.append(contentsOf: pages)
        }
        return harvest
    }

    /// Récolte de la boucle planner.
    private nonisolated struct PlannerHarvest: Sendable {
        var pages: [ScrapedPage] = []
        var documents: [SearXNGSearchResult] = []
    }

    /// Un tour planner : étape AUXILIAIRE (bug 3). Son échec (429/529 ou
    /// timeout BYOK, garde-fou ou limite d'Apple Intelligence…) vaut "done" :
    /// on répond avec les sources déjà trouvées plutôt que de perdre toute la
    /// réponse pour une étape facultative. L'annulation, elle, remonte.
    private nonisolated func nextPlannerDecision(
        query: String,
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage],
        actionNames: [String],
        iteration: Int
    ) async throws -> PlannerDecision {
        let prompt = Self.plannerPrompt(
            query: query,
            displayedSources: sources,
            scrapedPages: scrapedPages,
            availableActionNames: actionNames,
            iteration: iteration,
            maxIterations: maxIterations,
            maxURLsPerIteration: maxScrapedURLsPerIteration
        )
        return try await Self.bestEffort(fallback: PlannerDecision(actionName: Self.doneActionName, urls: [])) {
            let rawOutput = try await aiProvider.generate(prompt: prompt)
            return Self.decideNextAction(rawOutput: rawOutput)
        }
    }
}
