//
//  ResearchLedger.swift
//  Triva
//
//  Created by ben podrojsky on 20/11/2026.
//

import Foundation
import Synchronization

/// Les trois outils de l'enquêteur. La valeur brute est le nom de l'outil vu par le modèle.
nonisolated enum ResearchToolKind: String, Sendable, Equatable, CaseIterable {
    case search = "webSearch"
    case read = "readPage"
    case finish = "finish"

    init?(toolName: String) { self.init(rawValue: toolName) }
}

/// Plafond atteint. Levé par le registre (donc par les outils), jamais par le modèle.
nonisolated struct ResearchBudgetExceeded: Error, Equatable {
    nonisolated enum Limit: Sendable, Equatable {
        case toolCalls
        case searches
        case reads
    }

    let limit: Limit
}

/// Erreur sentinelle de fin normale : levée par `onToolOutput` une fois `finish` appelé
/// (prototype M1 : `respond` la rend telle quelle, sans enveloppe, et ne fait aucune requête de plus).
/// Levée aussi par le registre pour un outil appelé APRÈS la fin.
nonisolated struct ResearchFinished: Error, Equatable {}

/// Un résultat numéroté du registre. Le numéro est stable et c'est la SEULE façon pour le modèle de
/// désigner une page (jamais d'URL libre).
nonisolated struct ResearchEntry: Sendable, Equatable {
    let number: Int
    let result: SearXNGSearchResult
}

/// Une page lue par l'enquêteur : numéro du registre et page rendue par le scrape (succès, échec ou refus du site).
nonisolated struct ResearchReadPage: Sendable, Equatable {
    let number: Int
    let page: ScrapedPage
}

/// Suite donnée à une demande de recherche (`ResearchLedger.beginSearch`).
nonisolated enum SearchReservation: Sendable, Equatable {
    /// Recherche à faire : le budget de recherches est consommé.
    case proceed
    /// Même requête déjà faite (casse, accents et blancs ignorés) : AUCUN réseau. Compte comme un appel d'outil.
    case duplicate
    /// Requête vide après nettoyage des blancs. Compte comme un appel d'outil.
    case empty
}

/// Suite donnée à une demande de lecture (`ResearchLedger.beginRead`).
nonisolated enum ReadReservation: Sendable, Equatable {
    /// Page à lire : le budget de lectures est consommé.
    case proceed(ResearchEntry)
    /// Numéro absent du registre (jamais montré au modèle, ou page non fiable écartée en mode Fiable).
    case unknownNumber
    /// Page déjà lue ou en cours de lecture : pas de deuxième lecture.
    case alreadyRead(ResearchEntry)
}

/// Registre PARTAGÉ de l'enquête (spec 2.4 §2.1, §3) : numérote les résultats, compte les appels,
/// garde les pages lues. Lu par le profil (`body`, plusieurs fois par requête, donc sans effet de
/// bord) ET écrit par les outils (`@concurrent`, hors du main actor) : `final class` `Sendable`,
/// état sous `Mutex`.
///
/// CONTRAT pour la mission M3 (profil et `AppleAgenticResearcher`) :
/// - Les plafonds sont consommés à UN SEUL endroit : `beginSearch` / `beginRead`, appelés par les
///   outils eux-mêmes, atomiquement (contrôle ET incrément sous le même verrou). Un outil lancé sans
///   passer par le modèle est donc borné aussi, et les tests n'ont pas besoin de modèle.
/// - `.onToolCall` ne doit PAS consommer (sinon chaque appel serait compté deux fois) : il peut appeler
///   `precheck(_:)`, qui contrôle sans rien compter. Attention : ce lancer-là dans `onToolCall` n'a
///   pas été exécuté par le prototype M1 (signature seulement) ; les outils lèvent de toute façon.
/// - `body` ne lit que `canSearch`, `canRead` et `snapshot` : purs, sans effet de bord.
/// - `finish()` n'est jamais refusé et ne compte pas dans `maxToolCalls` : le profil « budget épuisé »
///   n'offre que `finish`, un plafond qui le refuserait transformerait un succès partiel en erreur.
/// - À la sentinelle `ResearchFinished`, le transcript du modèle est restauré (`.revertTranscript` par
///   défaut) : tout ce qui a été trouvé se lit dans `snapshot`, jamais dans le transcript.
nonisolated final class ResearchLedger: Sendable {
    /// Résultats montrés au modèle par recherche (et au départ).
    static let maxShownResults = 5
    /// Longueur maximale d'une requête acceptée (une requête plus longue est coupée par l'outil).
    static let maxQueryCharacters = 200

    /// Photographie lisible sans effet de bord. Tout ce dont la mission M3 a besoin une fois
    /// l'enquête finie (le transcript est alors restauré).
    nonisolated struct Snapshot: Sendable, Equatable {
        /// Tous les résultats numérotés, par numéro croissant (= ordre d'arrivée) : départ montré, puis recherches.
        let entries: [ResearchEntry]
        /// Nombre d'entrées venant du départ (les premières de `entries`).
        let seededCount: Int
        /// Requêtes de l'enquêteur, dans l'ordre, telles qu'envoyées au moteur.
        let queries: [String]
        let searchCount: Int
        let readCount: Int
        let toolCallCount: Int
        /// Pages lues, dans l'ordre de lecture, texte complet, échecs et refus compris.
        let readPages: [ResearchReadPage]
        let finished: Bool

        /// Résultats numérotés du départ (ce que montre le prompt de l'enquêteur).
        var seededEntries: [ResearchEntry] { Array(entries.prefix(seededCount)) }

        /// Résultats trouvés, dans l'ordre d'arrivée (départ montré compris : la déduplication est à l'assemblage).
        var foundResults: [SearXNGSearchResult] { entries.map(\.result) }

        /// Pages lues AVEC succès, dans l'ordre de lecture.
        var successfulPages: [ScrapedPage] { readPages.map(\.page).filter(\.succeeded) }

        /// Vrai si l'enquête a rapporté quelque chose en plus du départ (un résultat nouveau ou une page lue).
        /// Faux : l'orchestrateur reprend la boucle actuelle (spec §2.6, « registre sans source »).
        var hasFindings: Bool { entries.count > seededCount || !successfulPages.isEmpty }
    }

    private nonisolated struct State: Sendable {
        var entries: [ResearchEntry] = []
        var numberByKey: [String: Int] = [:]
        var seededCount = 0
        var queries: [String] = []
        var queryKeys: Set<String> = []
        var searches = 0
        var reads = 0
        var toolCalls = 0
        var attemptedReads: Set<Int> = []
        var readPages: [ResearchReadPage] = []
        var finished = false
    }

    let budget: ResearchBudget
    let trustedDomainsOnly: Bool
    private let state = Mutex(State())

    /// `seeded` : résultats du départ, dans l'ordre du moteur. Les `maxShownResults` premiers (après le
    /// filtre Fiable) reçoivent les numéros 1...n. En mode Fiable, un résultat hors des domaines
    /// fiables n'a JAMAIS de numéro : il ne peut être ni montré ni lu.
    init(budget: ResearchBudget, trustedDomainsOnly: Bool, seeded: [SearXNGSearchResult]) {
        self.budget = budget
        self.trustedDomainsOnly = trustedDomainsOnly
        let trusted = trustedDomainsOnly
        state.withLock { state in
            for result in seeded {
                guard state.entries.count < Self.maxShownResults else { break }
                _ = Self.register(result, trustedOnly: trusted, in: &state)
            }
            state.seededCount = state.entries.count
        }
    }

    // MARK: - Lecture (pure)

    var snapshot: Snapshot {
        state.withLock { state in
            Snapshot(
                entries: state.entries,
                seededCount: state.seededCount,
                queries: state.queries,
                searchCount: state.searches,
                readCount: state.reads,
                toolCallCount: state.toolCalls,
                readPages: state.readPages,
                finished: state.finished
            )
        }
    }

    var isFinished: Bool { state.withLock { $0.finished } }

    /// Une recherche est encore possible (recherches ET appels d'outil restants, enquête non finie).
    var canSearch: Bool {
        state.withLock { !$0.finished && $0.searches < budget.maxSearches && $0.toolCalls < budget.maxToolCalls }
    }

    /// Une lecture est encore possible : lectures ET appels restants, et au moins une page numérotée jamais demandée.
    var canRead: Bool {
        state.withLock { state in
            !state.finished && state.reads < budget.maxReads && state.toolCalls < budget.maxToolCalls
                && state.entries.contains { !state.attemptedReads.contains($0.number) }
        }
    }

    /// Contrôle SANS rien compter : pour `.onToolCall` (voir le contrat). `finish` passe toujours.
    func precheck(_ kind: ResearchToolKind) throws {
        try state.withLock { state in
            guard kind != .finish else { return }
            guard !state.finished else { throw ResearchFinished() }
            guard state.toolCalls < budget.maxToolCalls else { throw ResearchBudgetExceeded(limit: .toolCalls) }
            if kind == .search, state.searches >= budget.maxSearches { throw ResearchBudgetExceeded(limit: .searches) }
            if kind == .read, state.reads >= budget.maxReads { throw ResearchBudgetExceeded(limit: .reads) }
        }
    }

    // MARK: - Écriture (appelée par les outils)

    /// Réserve une recherche, atomiquement. Lève `ResearchBudgetExceeded` (ou `ResearchFinished`) sans rien compter.
    func beginSearch(query: String) throws -> SearchReservation {
        try state.withLock { state in
            try Self.requireRoom(in: state, budget: budget)
            let key = Self.queryKey(query)
            guard !key.isEmpty else {
                state.toolCalls += 1
                return .empty
            }
            guard !state.queryKeys.contains(key) else {
                state.toolCalls += 1
                return .duplicate
            }
            guard state.searches < budget.maxSearches else { throw ResearchBudgetExceeded(limit: .searches) }
            state.queryKeys.insert(key)
            state.queries.append(query.trimmingCharacters(in: .whitespacesAndNewlines))
            state.searches += 1
            state.toolCalls += 1
            return .proceed
        }
    }

    /// Numérote les résultats d'une recherche faite après `beginSearch` et rend ceux à montrer au
    /// modèle (5 au plus, dans l'ordre du moteur). Un résultat déjà connu garde son numéro.
    func recordSearch(results: [SearXNGSearchResult]) -> [ResearchEntry] {
        let trusted = trustedDomainsOnly
        return state.withLock { state in
            var shown: [ResearchEntry] = []
            for result in results where shown.count < Self.maxShownResults {
                guard let number = Self.register(result, trustedOnly: trusted, in: &state),
                      !shown.contains(where: { $0.number == number }) else { continue }
                shown.append(state.entries[number - 1])
            }
            return shown
        }
    }

    /// Réserve la lecture du résultat `number`, atomiquement. Un numéro inconnu ou déjà demandé
    /// compte comme un appel d'outil (une boucle de numéros invalides reste bornée) mais pas comme une lecture.
    func beginRead(number: Int) throws -> ReadReservation {
        try state.withLock { state in
            try Self.requireRoom(in: state, budget: budget)
            guard let entry = state.entries.first(where: { $0.number == number }) else {
                state.toolCalls += 1
                return .unknownNumber
            }
            guard !state.attemptedReads.contains(number) else {
                state.toolCalls += 1
                return .alreadyRead(entry)
            }
            guard state.reads < budget.maxReads else { throw ResearchBudgetExceeded(limit: .reads) }
            state.attemptedReads.insert(number)
            state.reads += 1
            state.toolCalls += 1
            return .proceed(entry)
        }
    }

    /// Garde la page lue (texte complet, pour le rédacteur).
    func recordRead(number: Int, page: ScrapedPage) {
        state.withLock { $0.readPages.append(ResearchReadPage(number: number, page: page)) }
    }

    /// Marque l'enquête finie. Jamais refusé, ne compte pas dans `maxToolCalls`.
    func finish() {
        state.withLock { $0.finished = true }
    }

    // MARK: - Interne

    private static func requireRoom(in state: State, budget: ResearchBudget) throws {
        guard !state.finished else { throw ResearchFinished() }
        guard state.toolCalls < budget.maxToolCalls else { throw ResearchBudgetExceeded(limit: .toolCalls) }
    }

    /// Numéro du résultat dans le registre, créé au besoin. `nil` : résultat inutilisable (URL sans hôte,
    /// jamais lisible ni citable) ou, en mode Fiable, hors des domaines fiables.
    private static func register(_ result: SearXNGSearchResult, trustedOnly: Bool, in state: inout State) -> Int? {
        guard SourceRanker.normalizedHost(of: result.url) != nil else { return nil }
        guard !trustedOnly || SourceRanker.isTrustedDomain(result.url) else { return nil }
        let key = SearchOrchestrator.urlKey(result.url)
        if let existing = state.numberByKey[key] { return existing }
        let number = state.entries.count + 1
        state.entries.append(ResearchEntry(number: number, result: result))
        state.numberByKey[key] = number
        return number
    }

    /// Clé de comparaison des requêtes : casse, accents et blancs ignorés.
    static func queryKey(_ query: String) -> String {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
