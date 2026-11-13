//
//  SearchOrchestrator+Support.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Fonctions de soutien du pipeline (découpage E1b) : historique borné, étapes « meilleur effort »,
/// annulation, tour de scrape, sujet de recherche, URLs et pages. Statiques et sans état.
/// `bestEffort` n'est plus `private` : elle sert aussi à `classifyWithFallback`, resté dans
/// `SearchOrchestrator.swift`.
extension SearchOrchestrator {
    /// Historique tel que le classifieur le reçoit (bug 6) : `QueryClassifier`
    /// n'en bornait que le NOMBRE de messages (`suffix(8)`), jamais la
    /// longueur — quelques réponses Approfondies suffisaient à faire déborder
    /// Apple Intelligence dès la classification. Mêmes bornes et même coupe
    /// (fin de phrase, « […] ») que le prompt final ; un budget nul ou
    /// négatif vaut « aucun historique », comme `PromptTemplates.formattedHistory`.
    nonisolated static func boundedHistory(
        _ history: [ClassifierChatMessage],
        maxMessages: Int,
        maxCharacters: Int
    ) -> [ClassifierChatMessage] {
        guard maxCharacters > 0 else { return [] }
        return history.suffix(max(0, maxMessages)).map { message in
            ClassifierChatMessage(
                role: message.role,
                content: PromptTemplates.boundedHistoryContent(message.content, maxCharacters: maxCharacters)
            )
        }
    }

    /// Étape LLM auxiliaire (classification, planner) : en cas d'échec,
    /// `fallback`. Seule exception, l'annulation (`isCancellation`), relancée
    /// TELLE QUELLE : l'avaler ferait enchaîner le tour planner suivant —
    /// voire la génération finale — dans une tâche que l'utilisateur vient
    /// d'arrêter. Même règle que `FailoverManager.search`, qui relance
    /// l'erreur d'une tâche annulée au lieu d'essayer l'instance suivante.
    nonisolated static func bestEffort<Value>(
        fallback: Value,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            if isCancellation(error) { throw error }
            return fallback
        }
    }

    /// Une erreur est une annulation si la tâche l'est (`Task.isCancelled`,
    /// le critère de `FailoverManager` et de `ChatViewModel`), ou si elle en
    /// porte la marque sans que la tâche le soit encore : `CancellationError`
    /// (Swift Concurrency) ou `URLError(.cancelled)` (requête `URLSession`
    /// interrompue, ce que lève un provider cloud coupé en plein vol).
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Un tour de scrape : un scrape par URL EN PARALLÈLE (`TaskGroup`), sous
    /// une échéance GLOBALE (`timeout`, proposée par A′) — sans elle, le tour
    /// durait autant que la page la plus lente, et la réponse l'attendait.
    /// À l'échéance, les pages finies sont gardées, les autres annulées puis
    /// rendues EN ÉCHEC, comme tout échec individuel (`scrape(url:)` ne lève
    /// jamais) : `plannerPrompt` les annonce « récupération échouée », le
    /// modèle ne les redemande pas. Une annulation de la tâche englobante
    /// (Stop) interrompt aussitôt l'attente ; `runPlannerLoop` la vérifie
    /// juste après. Pages rendues dans l'ordre de `urls`, plus d'arrivée.
    ///
    /// Limite assumée : sortir d'un `TaskGroup` attend ses tâches, une tâche
    /// annulée doit donc s'arrêter d'elle-même — `ScrapeService` le fait
    /// (`URLSession` async) ; une page arrivée après l'échéance est ignorée.
    /// `clock.now` est lu ICI, sur l'exécuteur de l'orchestrateur, et non
    /// dans la tâche minuteur : un test s'en sert comme sonde du `@concurrent`.
    /// Non `private` depuis la mission A1 : la lecture des sources sans
    /// extrait (`SearchOrchestrator+PreRead.swift`) réutilise ce même tour.
    nonisolated static func scrapeAll<C: Clock<Duration>>(
        _ urls: [String],
        using scrapeService: any ScrapeServing,
        timeout: Duration,
        clock: C
    ) async -> [ScrapedPage] {
        guard !urls.isEmpty else { return [] }
        let deadline = clock.now.advanced(by: timeout)
        return await withTaskGroup(of: ScrapeRoundEvent.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { .page(index: index, page: await scrapeService.scrape(url: url)) }
            }
            group.addTask {
                try? await clock.sleep(until: deadline, tolerance: nil)
                return .deadlineReached
            }
            var finishedPages: [Int: ScrapedPage] = [:]
            while finishedPages.count < urls.count, case .page(let index, let page)? = await group.next() {
                finishedPages[index] = page
            }
            group.cancelAll()
            return urls.indices.map { finishedPages[$0] ?? ScrapedPage(url: urls[$0], title: urls[$0], content: "", succeeded: false) }
        }
    }

    /// Événement d'un tour de scrape : une page finie (avec son rang dans la
    /// demande), ou l'échéance.
    private nonisolated enum ScrapeRoundEvent: Sendable {
        case page(index: Int, page: ScrapedPage)
        case deadlineReached
    }

    // MARK: - Sujet de recherche, URLs et pages (fonctions pures testables)

    /// Au-delà, une « reformulation » plus longue que la question elle-même
    /// n'en est pas une : le classifieur demande une reformulation COURTE, et
    /// un petit modèle qui boucle peut en produire des milliers de caractères.
    /// Envoyée telle quelle à SearXNG (requête GET), elle ferait échouer les
    /// instances une à une (URL trop longue) jusqu'à `allInstancesUnavailable`
    /// — une réponse perdue sur un simple raté de génération.
    nonisolated static let maxStandaloneQueryCharacters = 300

    /// Sujet de recherche (bug 1) : la reformulation autonome du classifieur
    /// (« Et son salaire ? » -> « Salaire de Tim Cook, PDG d'Apple »), sans
    /// laquelle SearXNG, le classement et le planner travaillaient sur une
    /// question incompréhensible hors conversation. Repli sur la question
    /// d'origine si la reformulation est vide après nettoyage des blancs, ou
    /// anormalement longue (`maxStandaloneQueryCharacters`, sauf si la
    /// question l'est déjà autant). Le classifieur en échec reformule déjà
    /// par la question elle-même (`classifyWithFallback`).
    nonisolated static func effectiveQuery(for query: String, standaloneFollowUp: String) -> String {
        let reformulation = standaloneFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reformulation.isEmpty, reformulation.count <= max(maxStandaloneQueryCharacters, query.count) else {
            return query
        }
        return reformulation
    }

    /// Clé de comparaison d'URL de tout le pipeline : `SourceRanker.normalizedURLKey`,
    /// celle qui déduplique déjà les sources — fragment `#…` retiré (jamais
    /// envoyé au serveur : deux URLs qui ne diffèrent que par lui téléchargent
    /// le MÊME document), hôte sans `www.` ni casse, slash final et paramètres
    /// de suivi ignorés, chemin sensible à la casse. Une seule règle : un
    /// dédoublonnage et une liste blanche fondés sur deux normalisations
    /// différentes finiraient par se contredire.
    nonisolated static func urlKey(_ url: String) -> String {
        SourceRanker.normalizedURLKey(for: url)
    }

    /// URLs que le planner peut réellement faire télécharger, dans l'ordre où
    /// il les propose :
    /// - uniquement des SOURCES AFFICHÉES (bug 8) : une page hors du top N, ou
    ///   inventée par le modèle, serait téléchargée depuis l'IP de
    ///   l'utilisateur puis injectée dans le prompt sans qu'il puisse la voir
    ///   sous la réponse ;
    /// - jamais deux fois la même page (bug 11), ni au sein d'une même liste
    ///   ni d'un tour à l'autre (`alreadyAttempted`, clés `urlKey`) ;
    /// - au plus `limit`, compté APRÈS ce filtre : trois URLs invalides en
    ///   tête ne doivent pas priver le tour d'une quatrième valide.
    /// Chaque URL retenue est réécrite à l'identique de sa source (la
    /// variante proposée par le modèle est abandonnée) : la page scrapée
    /// porte alors exactement l'URL que `PromptTemplates.numberedContext`
    /// compare pour la fusionner dans le document de cette source.
    nonisolated static func scrapableURLs(
        _ requestedURLs: [String],
        displayedSources: [SearXNGSearchResult],
        alreadyAttempted attemptedKeys: Set<String>,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let canonicalURLByKey = canonicalURLsByKey(displayedSources)
        var selectedKeys: Set<String> = []
        var selected: [String] = []
        for url in requestedURLs {
            let key = urlKey(url)
            guard let canonicalURL = canonicalURLByKey[key], !attemptedKeys.contains(key) else { continue }
            guard selectedKeys.insert(key).inserted else { continue }
            selected.append(canonicalURL)
            if selected.count == limit { break }
        }
        return selected
    }

    /// Invariant des citations (bug 8) garanti en UN point, juste avant le
    /// prompt : toute page scrapée injectée figure dans les sources affichées.
    /// Les autres sont écartées, et l'URL de chaque page gardée est recopiée
    /// de sa source — sans cela, une page à l'URL légèrement différente
    /// (fragment, slash final) recevrait de `numberedContext` son propre
    /// numéro, une citation `[n]` au-delà des sources affichées. Le
    /// dédoublonnage reste celui de `numberedContext` (première page
    /// exploitable gagnante), qui sait préférer une page réussie à un échec.
    nonisolated static func pagesBackedBySources(_ pages: [ScrapedPage], sources: [SearXNGSearchResult]) -> [ScrapedPage] {
        let canonicalURLByKey = canonicalURLsByKey(sources)
        return pages.compactMap { page in
            guard let canonicalURL = canonicalURLByKey[urlKey(page.url)] else { return nil }
            return ScrapedPage(url: canonicalURL, title: page.title, content: page.content, succeeded: page.succeeded)
        }
    }

    /// Clé normalisée -> URL exacte de la source ; la première source gagne
    /// si deux partagent une clé (cas évité en amont : `SourceRanker`
    /// déduplique avec la même clé).
    private nonisolated static func canonicalURLsByKey(_ sources: [SearXNGSearchResult]) -> [String: String] {
        Dictionary(sources.map { (urlKey($0.url), $0.url) }, uniquingKeysWith: { first, _ in first })
    }

    /// Dédoublonnage par URL normalisée (`urlKey`), comme dans la version web d'origine :
    /// conserve l'ordre d'arrivée, ignore les
    /// doublons ultérieurs. Bug 11 corrigé : l'ensemble des URLs vues était
    /// calculé AVANT la boucle et jamais mis à jour, si bien que deux
    /// résultats de même URL dans un même lot passaient tous les deux — et
    /// produisaient des identifiants en double dans le `ForEach` des sources.
    nonisolated static func accumulate(
        _ output: SearchActionOutput,
        sources: inout [SearXNGSearchResult],
        scrapedPages: inout [ScrapedPage]
    ) {
        switch output {
        case .searchResults(let results):
            var seenKeys = Set(sources.map { urlKey($0.url) })
            for result in results where seenKeys.insert(urlKey(result.url)).inserted {
                sources.append(result)
            }
        case .scrapedPages(let pages):
            scrapedPages.append(contentsOf: pages)
        case .reasoning, .done:
            break
        }
    }
}
