//
//  ResearchTools.swift
//  Triva
//
//  Created by ben podrojsky on 20/11/2026.
//

import Foundation
import FoundationModels

// Les trois outils de l'enquêteur (spec 2.4 §2.2), `Tool` de FoundationModels. Aucune dépendance
// réseau directe : la recherche et le scrape sont des closures injectées (la mission M3 les bâtit sur le
// `failoverManager`, la `webSearchChain` et le `scrapeService` de l'orchestrateur ; les tests, sur des doubles).
//
// Chaque outil range sa logique dans une méthode simple (`run`), que `call(arguments:)` appelle : les
// `Arguments` `@Generable` n'ont pas d'initialiseur utilisable en test. Tous les types sont `nonisolated`
// (le projet isole tout au main actor par défaut) et les points d'entrée sont `@concurrent` : ni recherche
// ni lecture ne passent par le fil d'interface. Les descriptions et guides sont des textes pour le MODÈLE
// (jamais affichés à l'utilisateur).

/// `webSearch` : cherche sur le web (la MÊME chaîne que la recherche de départ) et rend 5 résultats numérotés.
nonisolated struct WebSearchTool: Tool {
    /// Recherche web d'une requête. Lève en cas d'échec ; l'annulation est relancée telle quelle.
    typealias Search = @Sendable (String) async throws -> [SearXNGSearchResult]

    let ledger: ResearchLedger
    let search: Search

    let name = ResearchToolKind.search.rawValue
    let description = "Cherche sur le web. Donne une requête de 3 à 12 mots. Renvoie jusqu'à 5 résultats numérotés."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "La requête de recherche, 3 à 12 mots")
        var query: String
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        try await run(query: arguments.query)
    }

    /// Requête déjà faite (casse et accents ignorés), vide : AUCUN réseau, un appel d'outil compté.
    /// Échec de la recherche (hors annulation) : un texte pour le modèle, qui peut changer de mots ou finir.
    /// Plafond atteint : `ResearchBudgetExceeded` (le modèle ne le voit pas, l'enquêteur garde ce qu'il a).
    @concurrent
    func run(query: String) async throws -> String {
        try Task.checkCancellation()
        let clipped = String(query.prefix(ResearchLedger.maxQueryCharacters))
        switch try ledger.beginSearch(query: clipped) {
        case .empty:
            return ResearchToolOutput.emptyQuery
        case .duplicate:
            return ResearchToolOutput.duplicateSearch
        case .proceed:
            break
        }
        let results: [SearXNGSearchResult]
        do {
            results = try await search(clipped)
        } catch {
            if SearchOrchestrator.isCancellation(error) { throw CancellationError() }
            return ResearchToolOutput.searchFailed
        }
        try Task.checkCancellation()
        return ResearchToolOutput.searchOutput(ledger.recordSearch(results: results))
    }
}

/// `readPage` : lit la page d'un résultat DÉJÀ numéroté. Le modèle donne un numéro, jamais une adresse :
/// une page lue peut contenir une injection de prompt, elle ne peut pas faire télécharger une URL de son choix.
nonisolated struct ReadPageTool: Tool {
    /// Lecture d'une page (ne lève jamais, comme `ScrapeServing.scrape(url:)`).
    typealias Scrape = @Sendable (String) async -> ScrapedPage

    let ledger: ResearchLedger
    let scrape: Scrape
    /// Question de recherche : sert à choisir le passage rendu au modèle.
    let focusQuery: String

    let name = ResearchToolKind.read.rawValue
    let description = "Lit la page d'un résultat déjà trouvé. Donne le NUMÉRO du résultat, jamais une adresse."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Numéro du résultat à lire", .range(1...20))
        var source: Int
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        try await run(number: arguments.source)
    }

    /// Numéro inconnu ou page déjà demandée : AUCUN réseau, un appel d'outil compté. Sinon scrape de l'URL
    /// EXACTE du registre ; la page (texte complet, échec et refus compris) est gardée au registre pour le
    /// rédacteur, avec l'URL du registre ; le modèle ne reçoit qu'un accusé et un passage de 300 caractères.
    @concurrent
    func run(number: Int) async throws -> String {
        try Task.checkCancellation()
        switch try ledger.beginRead(number: number) {
        case .unknownNumber:
            return ResearchToolOutput.unknownNumber(number)
        case .alreadyRead(let entry):
            return ResearchToolOutput.alreadyRead(entry.number)
        case .proceed(let entry):
            let scraped = await scrape(entry.result.url)
            try Task.checkCancellation()
            let page = ScrapedPage(
                url: entry.result.url,
                title: scraped.title,
                content: scraped.content,
                succeeded: scraped.succeeded,
                refusedBySite: scraped.refusedBySite
            )
            ledger.recordRead(number: entry.number, page: page)
            return ResearchToolOutput.readOutput(number: entry.number, page: page, query: focusQuery)
        }
    }
}

/// `finish` : l'enquêteur estime avoir assez de sources. Marque le registre fini ; l'arrêt de la session
/// se fait par la sentinelle `ResearchFinished` levée dans `onToolOutput` (mission M3).
nonisolated struct FinishResearchTool: Tool {
    let ledger: ResearchLedger

    let name = ResearchToolKind.finish.rawValue
    let description = "Termine l'enquête quand les sources suffisent."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Vrai si les sources trouvées suffisent pour répondre")
        var enough: Bool
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        run()
    }

    /// Jamais refusé, même budget épuisé ; ne compte pas dans `maxToolCalls`.
    func run() -> String {
        ledger.finish()
        return "ok"
    }
}
