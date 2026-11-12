//
//  ChatViewModelTests+Doubles.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

// Doublures de la suite `ChatViewModelTests`, imbriquées dans la suite :
// `private` ne traverse pas les fichiers, et les mêmes noms existent ailleurs.

extension ChatViewModelTests {
    enum MockError: Error, Sendable, Equatable {
        case searchFailed
        case midStreamFailure
        case providerResolutionFailed
        case mediaFailed
    }

    // MARK: - Doublures réseau

    /// Client SearXNG factice, même principe que `MockSearXNGClient` de
    /// `SearchOrchestratorTests.swift` (dupliqué ici, `private` est scopé au
    /// fichier) : réponse fixe, ou erreur si configuré pour échouer. Compte les
    /// requêtes : un chemin « sans recherche » doit le laisser à zéro.
    actor MockSearXNGClient {
        private let response: SearXNGSearchResponse
        private let shouldFail: Bool
        private(set) var receivedQueries: [String] = []

        init(response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: []), shouldFail: Bool = false) {
            self.response = response
            self.shouldFail = shouldFail
        }
    }

    /// Client SearXNG dont `search` reste en vol jusqu'à `fail(with:)` : simule
    /// une annulation PENDANT `failoverManager.search(query:)`, avant même que
    /// `streamAnswer` ait créé un `textStream` (finding ChatViewModel.swift:166
    /// de la revue 0.8).
    actor ControllableSearXNGClient {
        private(set) var continuation: CheckedContinuation<SearXNGSearchResponse, Error>?
    }

    // MARK: - Doublures IA

    /// Provider IA qui streame une suite fixe de snapshots, avec une erreur
    /// optionnelle en fin de flux. `generate(prompt:)` sert à la classification
    /// et aux tours planner (jamais à la génération finale, qui passe par
    /// `streamGenerate`) : deux tableaux séparés. Sans `classification`, la
    /// sortie n'est jamais du JSON valide et le classifieur retombe sur son repli
    /// sûr (recherche web, aucun widget).
    final class MockStreamingAIGenerating: AIGenerating {
        private(set) var receivedGeneratePrompts: [String] = []
        private(set) var receivedStreamPrompts: [String] = []
        private let chunks: [String]
        private let midStreamFailure: (any Error)?
        private let classification: String?

        init(chunks: [String] = ["chunk"], midStreamFailure: (any Error)? = nil, classification: String? = nil) {
            self.chunks = chunks
            self.midStreamFailure = midStreamFailure
            self.classification = classification
        }

        /// Prompts de classification : marqueur `<user_query>` de `QueryClassifier.buildPrompt`.
        var classifierPrompts: [String] {
            receivedGeneratePrompts.filter { $0.contains("<user_query>") }
        }

        func generate(prompt: String) async throws -> String {
            receivedGeneratePrompts.append(prompt)
            if let classification, prompt.contains("<user_query>") {
                return classification
            }
            return chunks.joined()
        }

        func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
            receivedStreamPrompts.append(prompt)
            return AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                if let midStreamFailure {
                    continuation.finish(throwing: midStreamFailure)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    /// Provider dont le flux est piloté par le test (`continuation`), pour
    /// observer le ViewModel ENTRE deux snapshots. Chaque `streamGenerate`
    /// remplace `continuation` : un 2e envoi s'attend sur `receivedPrompts.count`.
    final class ControllableStreamingAIGenerating: AIGenerating {
        private(set) var receivedPrompts: [String] = []
        private(set) var continuation: AsyncThrowingStream<String, Error>.Continuation?

        func generate(prompt: String) async throws -> String { "" }

        func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
            receivedPrompts.append(prompt)
            return AsyncThrowingStream { continuation in
                self.continuation = continuation
            }
        }
    }

    /// Provider dont tout appel HORS classification lève : la génération des
    /// suggestions échoue (quota, réseau coupé) APRÈS une réponse réussie.
    final class SuggestionsFailingProvider: AIGenerating {
        private(set) var failedSuggestionCalls = 0

        func generate(prompt: String) async throws -> String {
            guard prompt.contains("<user_query>") else {
                failedSuggestionCalls += 1
                throw MockError.midStreamFailure
            }
            return ""
        }

        func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("Réponse complète.")
                continuation.finish()
            }
        }
    }

    // MARK: - Doublures du pipeline

    /// Similarité identique partout : le classement garde l'ordre du moteur.
    struct ConstantSimilarityScorer: TextSimilarityScoring {
        func similarities(of reference: String, against candidates: [String]) async -> [Double] {
            Array(repeating: 0.5, count: candidates.count)
        }
    }

    /// Rien n'est un quasi-doublon : des extraits de test courts se
    /// ressemblent trop pour le vrai scorer lexical.
    struct NeverDuplicateScorer: TextSimilarityScoring {
        func similarities(of reference: String, against candidates: [String]) async -> [Double] {
            Array(repeating: 0, count: candidates.count)
        }
    }

    /// Aucune langue reconnue : un seul groupe, aucune fusion FR/EN.
    struct UnknownLanguageIdentifier: TextLanguageIdentifying {
        func dominantLanguage(of text: String) -> String? { nil }
    }

    /// Aucun scrape réel : le mode Rapide n'a pas de planner, et le planner des
    /// autres modes retombe sur `done` (sortie non JSON des doublures).
    struct FailingScrapeService: ScrapeServing {
        func scrape(url: String) async -> ScrapedPage {
            ScrapedPage(url: url, title: "", content: "", succeeded: false)
        }
    }

    /// Widget à sortie fixe, déclenché par le drapeau de son type.
    struct FixedOutputWidget: SearchWidget {
        let output: SearchWidgetOutput

        var kind: SearchWidgetKind { output.kind }

        func shouldExecute(for classification: QueryClassification) -> Bool {
            switch output.kind {
            case .weather: classification.showWeatherWidget
            case .calculation: classification.showCalculationWidget
            }
        }

        func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
            output
        }
    }

    /// Recherche média factice : enregistre chaque requête, rend une liste fixe
    /// ou lève. Sert AUSSI de recherche média de l'orchestrateur, pour prouver
    /// que l'envoi ne cherche jamais de médias (décision (a)).
    actor RecordingMediaSearcher {
        private(set) var imageQueries: [String] = []
        private(set) var videoQueries: [String] = []
        private let images: [ImageSearchResult]
        private let videos: [VideoSearchResult]
        private let failure: MockError?

        init(images: [ImageSearchResult] = [], videos: [VideoSearchResult] = [], failure: MockError? = nil) {
            self.images = images
            self.videos = videos
            self.failure = failure
        }
    }

    /// Lecture de fichier factice : un fragment texte fixe, sans disque.
    struct StubAttachmentPreparer: AttachmentPreparing {
        static let text = "Le rapport annuel indique une hausse de 12 % des ventes."

        func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
            IndexedAttachment(
                fileName: url.lastPathComponent,
                kind: .plainText,
                pageCount: nil,
                characterCount: Self.text.count,
                isTruncated: false,
                isCopyRestricted: false,
                chunks: [AttachmentChunk(index: 0, text: Self.text, pageRange: nil)]
            )
        }
    }

    // MARK: - Enregistreurs

    /// Ce que le ViewModel relit à CHAQUE envoi (mode mémorisé, budget du
    /// moteur), modifiable entre deux envois — sans jamais toucher
    /// `UserDefaults.standard`, que l'app hôte des tests partage.
    @MainActor
    final class SendSettings {
        var mode: ResponseMode = .quick
        var configuration: SearchPipelineConfiguration = .cloud
    }

    /// Entrées reçues par la fabrique d'orchestrateur, une par échange : la
    /// preuve que mode et budget arrivent au pipeline (bug 6, 1.13).
    @MainActor
    final class OrchestratorFactoryRecorder {
        private(set) var modes: [ResponseMode] = []
        private(set) var configurations: [SearchPipelineConfiguration] = []

        func record(_ inputs: ChatViewModel.OrchestratorInputs) {
            modes.append(inputs.responseMode)
            configurations.append(inputs.configuration)
        }
    }

    /// Générateur de suggestions injecté PARTOUT : le service réel ferait des
    /// appels `generate` après le retour de `send`, et décalerait les comptes de
    /// prompts. `delays` retarde les appels successifs (annulation par l'envoi
    /// suivant) ; `cancellationByQuestion` dit si la tâche était annulée au
    /// moment de rendre la main.
    @MainActor
    final class SuggestionsRecorder {
        private(set) var histories: [[ClassifierChatMessage]] = []
        private(set) var cancellationByQuestion: [String: Bool] = [:]
        private let result: [String]
        private var delays: [Duration]

        init(result: [String] = [], delays: [Duration] = []) {
            self.result = result
            self.delays = delays
        }

        func generate(_ provider: any AIGenerating, _ history: [ClassifierChatMessage]) async -> [String] {
            histories.append(history)
            if !delays.isEmpty {
                let delay = delays.removeFirst()
                try? await Task.sleep(for: delay)
            }
            let question = history.last { $0.role == .user }?.content ?? ""
            cancellationByQuestion[question] = Task.isCancelled
            return result
        }
    }

    /// Historique et favoris de l'app, sur le MÊME conteneur en mémoire neuf
    /// (comme `TrivaSharedStores`) — jamais `TrivaModelContainer.shared`.
    @MainActor
    struct PersistenceStores {
        let history: ChatHistoryStore
        let favorites: FavoritesStore

        init() throws {
            let container = try TrivaModelContainer.makeInMemory()
            let locale = Locale(identifier: "fr_FR")
            history = ChatHistoryStore(container: container, locale: locale)
            favorites = FavoritesStore(container: container, locale: locale)
        }

        func onlyConversation() throws -> StoredConversation? {
            let conversations = try history.conversations()
            return conversations.count == 1 ? conversations.first : nil
        }
    }
}

extension ChatViewModelTests.MockSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedQueries.append(query)
        if shouldFail {
            throw ChatViewModelTests.MockError.searchFailed
        }
        return response
    }
}

extension ChatViewModelTests.ControllableSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fail(with error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

extension ChatViewModelTests.RecordingMediaSearcher: MediaSearching {
    func searchImages(query: String) async throws -> [ImageSearchResult] {
        imageQueries.append(query)
        if let failure { throw failure }
        return images
    }

    func searchVideos(query: String) async throws -> [VideoSearchResult] {
        videoQueries.append(query)
        if let failure { throw failure }
        return videos
    }
}
