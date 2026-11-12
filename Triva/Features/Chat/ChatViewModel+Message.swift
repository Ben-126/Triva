//
//  ChatViewModel+Message.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation

// Sorti tel quel de `ChatViewModel.swift` (mission RI2), qui dépassait 800 lignes.
extension ChatViewModel {
    /// Un message du fil, `Equatable` pour `MessageBubbleView.equatable()`.
    /// L'affichage y est PRÉ-CALCULÉ (segments, widgets typés).
    struct Message: Identifiable, Sendable, Equatable {
        enum Role: Sendable, Equatable {
            case user
            case assistant
        }

        /// Issue d'une réponse : l'historique du classifieur ne garde que les
        /// succès, `isStreaming` seul ne les distinguait pas.
        enum Status: Sendable, Equatable {
            case streaming
            case completed
            /// Texte partiel conservé, message dans `errorDescription`.
            case failed
            /// Stop, écran quitté, nouvelle conversation.
            case interrupted
            /// Décision (c) : mode Fiable sans source fiable, rien de généré.
            /// Afficher `noReliableSourcesMessage`, proposer `retryInQuickMode`.
            case noReliableSources
        }

        /// Fichier joint à la question : un résumé, jamais le texte indexé.
        struct AttachedFile: Sendable, Equatable, Identifiable {
            let id: UUID
            let fileName: String
            let kind: AttachmentKind
        }

        /// Widget abouti, au-dessus de la réponse. Typé ici :
        /// `SearchWidgetOutput` (charge utile existentielle) n'est pas `Equatable`.
        enum Widget: Sendable, Equatable {
            case weather(WeatherWidgetData)
            case calculation(CalculationWidgetData)

            init?(_ output: SearchWidgetOutput) {
                if let weather = output.weatherData {
                    self = .weather(weather)
                } else if let calculation = output.calculationData {
                    self = .calculation(calculation)
                } else {
                    return nil
                }
            }
        }

        let id: UUID
        let role: Role
        /// Texte BRUT, balises `<think>`/`<tldr>` comprises : c'est lui qui est
        /// persisté et mis en favori. La vue affiche `segments`.
        private(set) var text: String
        /// `ReasoningSegmenter` appliqué une fois par snapshot (passe linéaire).
        private(set) var segments: ReasoningSegments
        /// Pour « A réfléchi pendant N s » ; inconnu pour un message relu.
        private(set) var reasoningTiming = ReasoningTiming()
        private(set) var status: Status
        /// Ordre des citations : `[n]` désigne `sources[n - 1]`.
        var sources: [SearXNGSearchResult]
        /// Les N premières sources sont des fichiers joints (pas de lien).
        var attachmentSourceCount = 0
        var widgets: [Widget] = []
        /// À la demande (décision (a)) : `.idle` affiche le bouton.
        var images: ImageResultsPhase = .idle
        var videos: VideoResultsPhase = .idle
        /// Reformulation du classifieur, sujet des recherches médias.
        var searchQuery: String?
        /// Service qui a fourni les sources web, pour le dire sous la réponse
        /// (`MessageBubblePresentation.resultsOriginLabel`). Non persisté : un
        /// message relu ne le connaît plus, et n'affiche rien plutôt qu'une
        /// supposition.
        var webSourceKind: WebSearchSourceKind?
        /// Réponse rédigée sans aucune recherche ni widget, hors salutation :
        /// « Réponse sans recherche » sous la bulle (mission A2, décision 3,
        /// `SearchArtifacts.answeredWithoutSearch`). Non persisté, comme
        /// `webSourceKind` : un message relu n'affiche pas la mention.
        var answeredWithoutSearch = false
        /// Rédigée hors connexion, sans recherche ni source (tâche 1.16,
        /// `SearchArtifacts.answeredOffline`) : la mention « Hors connexion, sans source » remplace
        /// « Réponse sans recherche ». Non persistée non plus.
        var answeredOffline = false
        /// Aucune source n'a passé le test lexical de la chaîne : sources
        /// affichées « probablement hors sujet » (mission A2, décision 6,
        /// `WebSearchChainReport.matchesQuestion`). Non persisté non plus.
        var sourcesMayBeOffTopic = false
        /// Numéros `[n]` des sources affichées mais jamais LUES (`SearchArtifacts.uncitableSourceNumbers`,
        /// mission A1) : leur citation s'affiche en texte simple, pas en pastille, et la liste les
        /// marque « non lue » (mission C1). Non persisté : un message relu ne le sait plus.
        var uncitableSourceNumbers: Set<Int> = []
        /// SearXNG n'a pas répondu à cette recherche (`ChatViewModel.searXNGUnreachable`) : les
        /// boutons « Rechercher des images / vidéos », qui ne passent que par SearXNG, sont masqués
        /// (décision de Ben, mission C1). Non persisté : un message relu montre les boutons.
        var searXNGUnreachable = false
        /// Étape affichée près de l'indicateur de génération (finding 31). Voir `GenerationStage`.
        var generationStage: GenerationStage = .searching
        /// Seule la dernière réponse terminée en porte.
        var suggestions: [String] = []
        var attachedFiles: [AttachedFile] = []
        /// `id` du `StoredMessage` : SEULE clé des favoris, stable d'un
        /// lancement à l'autre. `nil` pendant le streaming ou sans historique.
        var storedMessageID: UUID?
        var storedConversationID: UUID?
        /// Diagnostic du validateur de structure, sans UI.
        var structureReport: ResponseStructureReport?

        var isStreaming: Bool { status == .streaming }

        init(
            id: UUID = UUID(),
            role: Role,
            text: String = "",
            sources: [SearXNGSearchResult] = [],
            isStreaming: Bool = false
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.sources = sources
            self.status = isStreaming ? .streaming : .completed
            self.segments = ReasoningSegmenter.segment(text, isStreaming: isStreaming)
        }

        /// Snapshot CUMULATIF : il remplace le texte, jamais de concaténation.
        mutating func apply(snapshot: String, at date: Date) {
            text = snapshot
            segments = ReasoningSegmenter.segment(snapshot, isStreaming: true)
            reasoningTiming = reasoningTiming.updated(for: segments.reasoningPhase, at: date)
        }

        /// Fin de flux : relâche les fragments retenus et fige la phase (un
        /// bloc resté ouvert devient `.interrupted`, jamais replié).
        mutating func finish(_ newStatus: Status, at date: Date) {
            status = newStatus
            segments = ReasoningSegmenter.segment(text, isStreaming: false)
            reasoningTiming = reasoningTiming.updated(for: segments.reasoningPhase, at: date)
        }

        mutating func attach(_ artifacts: SearchArtifacts) {
            sources = ChatViewModel.displayedSources(of: artifacts)
            attachmentSourceCount = artifacts.attachmentSourceCount
            uncitableSourceNumbers = artifacts.uncitableSourceNumbers
            searXNGUnreachable = ChatViewModel.searXNGUnreachable(artifacts.webSearchReport)
            widgets = artifacts.widgets.compactMap { Widget($0) }
            searchQuery = artifacts.searchQuery
            webSourceKind = artifacts.webSourceKind
            answeredWithoutSearch = artifacts.answeredWithoutSearch
            answeredOffline = artifacts.answeredOffline
            sourcesMayBeOffTopic = !artifacts.webSearchReport.matchesQuestion
        }

        /// État fixe « Aucune source fiable » : il ne porte RIEN d'autre que la
        /// requête (sujet d'une éventuelle relance). Depuis la mission A1, une
        /// réponse Fiable refusée en fin de flux peut avoir reçu des artefacts,
        /// voire du texte (refus cité) : tout est vidé, parce que
        /// `MessageBubbleView` affiche encore corps et sources s'ils ne sont
        /// pas vides, et qu'un diagnostic ou des suggestions n'ont pas de sens ici.
        mutating func markNoReliableSources(searchQuery: String, at date: Date) {
            text = ""
            reasoningTiming = ReasoningTiming()
            sources = []
            attachmentSourceCount = 0
            uncitableSourceNumbers = []
            searXNGUnreachable = false
            widgets = []
            webSourceKind = nil
            answeredWithoutSearch = false
            answeredOffline = false
            sourcesMayBeOffTopic = false
            structureReport = nil
            suggestions = []
            self.searchQuery = searchQuery
            finish(.noReliableSources, at: date)
        }
    }
}
