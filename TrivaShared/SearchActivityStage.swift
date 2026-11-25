//
//  SearchActivityStage.swift
//  TrivaShared
//
//  Chantier 2.1 (mission D) : les étapes affichées par l'activité en direct, et la règle PURE qui passe d'une
//  étape à la suivante. Aucun framework d'interface ni ActivityKit ici : l'app (qui émet les événements), les tests
//  et l'extension Widgets (qui affiche l'état) partagent ce même fichier.
//

import Foundation

/// Les six étapes d'une recherche vues de l'extérieur de l'app.
nonisolated enum SearchActivityStage: String, Codable, Hashable, Sendable {
    case searching
    case reading
    case writing
    case ready
    case interrupted
    case failed
}

/// État dynamique de l'activité (le `ContentState` d'ActivityKit). Très petit : l'activité refuse plus de 4 Ko.
nonisolated struct SearchActivityState: Codable, Hashable, Sendable {
    var stage: SearchActivityStage
    var sourceCount: Int

    static let initial = SearchActivityState(stage: .searching, sourceCount: 0)

    /// Texte de l'étape, tel qu'affiché (écran verrouillé et Dynamic Island).
    var statusText: String {
        switch stage {
        case .searching: "Recherche…"
        case .reading: sourceCount == 1 ? "Lecture d'une source" : "Lecture de \(sourceCount) sources"
        case .writing: "Rédaction…"
        case .ready: "Réponse prête"
        case .interrupted: "Recherche interrompue"
        case .failed: "La recherche n'a pas abouti"
        }
    }

    /// Ce que l'écran montre : une activité devenue PÉRIMÉE (plus aucune mise à jour depuis 2 minutes, l'app n'a
    /// plus la main) ne doit pas prétendre chercher encore.
    func displayed(isStale: Bool) -> SearchActivityState {
        guard isStale, !stage.isTerminal else { return self }
        return SearchActivityState(stage: .interrupted, sourceCount: sourceCount)
    }
}

/// Ce que `ChatViewModel` raconte d'un échange. Le contrôleur d'activité en tire un `SearchActivityState`.
nonisolated enum SearchProgressEvent: Sendable, Equatable {
    case started(question: String, conversationID: UUID?)
    case searching
    case sources(count: Int)
    case writing
    case completed
    case interrupted
    case failed
}

nonisolated extension SearchActivityStage {
    /// Prête, interrompue ou échouée : plus rien ne change après.
    var isTerminal: Bool {
        switch self {
        case .ready, .interrupted, .failed: true
        case .searching, .reading, .writing: false
        }
    }

    /// Rang dans le déroulé : une étape ne revient jamais en arrière.
    private var rank: Int {
        switch self {
        case .searching: 0
        case .reading: 1
        case .writing: 2
        case .ready, .interrupted, .failed: 3
        }
    }

    /// État suivant `state` après `event`.
    ///
    /// - Recherche en cours : « Recherche ». Des sources lues (au moins une) : « Lecture de N sources ».
    /// - Le PREMIER instantané non vide du flux de texte : « Rédaction ». C'est le flux qui compte, pas l'affichage :
    ///   en mode Fiable, le texte est retenu tant qu'il ne cite rien, mais le modèle écrit bel et bien.
    /// - Une étape ne recule jamais, et une étape finale (prête, interrompue, échouée) est définitive.
    static func next(_ state: SearchActivityState, event: SearchProgressEvent) -> SearchActivityState {
        if case .started = event { return .initial }
        guard !state.stage.isTerminal else { return state }
        switch event {
        case .started, .searching:
            return state
        case .sources(let count):
            guard count > 0, state.stage.rank < SearchActivityStage.reading.rank else { return state }
            return SearchActivityState(stage: .reading, sourceCount: count)
        case .writing:
            guard state.stage.rank < SearchActivityStage.writing.rank else { return state }
            return SearchActivityState(stage: .writing, sourceCount: state.sourceCount)
        case .completed:
            return SearchActivityState(stage: .ready, sourceCount: state.sourceCount)
        case .interrupted:
            return SearchActivityState(stage: .interrupted, sourceCount: state.sourceCount)
        case .failed:
            return SearchActivityState(stage: .failed, sourceCount: state.sourceCount)
        }
    }
}
