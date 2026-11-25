//
//  SearchActivityStage.swift
//  TrivaShared
//
//  Chantier 2.1 (missions D puis I) : les étapes affichées par l'activité en direct, et la règle PURE qui passe d'une
//  étape à la suivante. Aucun framework d'interface ni ActivityKit ici : l'app (qui émet les événements), les tests
//  et l'extension Widgets (qui affiche l'état) partagent ce même fichier.
//
//  Mission I (Ben, 25/11) : les étapes sont dites précisément, avec les mêmes mots que l'écran de la recherche dans l'app
//  (« Réflexion… », « Recherche des sources… », « Lecture de N sources », « Rédaction… »). Seul le NOM de l'étape est
//  montré, jamais le contenu du raisonnement du modèle. Et la question est une partie de l'ÉTAT (pas un attribut fixe) :
//  une mise à jour peut la retirer de l'écran quand le réglage « Afficher la question » est éteint.
//

import Foundation

/// Les étapes d'une recherche vues de l'extérieur de l'app. Une étape absente d'un échange n'est simplement pas affichée
/// (par exemple « Recherche des sources » hors connexion).
nonisolated enum SearchActivityStage: String, Codable, Hashable, Sendable {
    /// La question est analysée, ou le modèle réfléchit (raisonnement) avant d'écrire.
    case thinking
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
    /// La question, ramenée à une ligne ; `nil` = elle n'est pas affichée (réglage éteint). Pas de question = aucune
    /// trace sur l'écran verrouillé, dans l'île ni sur la montre : rien ne la remplace.
    var question: String?

    init(stage: SearchActivityStage, sourceCount: Int, question: String? = nil) {
        self.stage = stage
        self.sourceCount = sourceCount
        self.question = question
    }

    static let initial = SearchActivityState(stage: .thinking, sourceCount: 0)

    /// La question tient sur une ligne et 140 caractères au plus (l'activité refuse plus de 4 Ko, et deux lignes
    /// suffisent à l'écran).
    static let maxQuestionLength = 140

    /// La question ramenée à UNE ligne et à 140 caractères au plus.
    static func oneLineQuestion(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Bornée aussi en scalaires : 4 Ko au plus pour toute l'activité, quelle que soit la question.
        let scalarBudget = maxQuestionLength * 4
        guard WidgetSnapshot.clip(flattened, maxCharacters: maxQuestionLength, maxScalars: scalarBudget).wasClipped else {
            return flattened
        }
        return WidgetSnapshot.clip(flattened, maxCharacters: maxQuestionLength - 1, maxScalars: scalarBudget).text + "…"
    }

    /// Le même état avec cette question (ou sans question si `nil`).
    func showing(question: String?) -> SearchActivityState {
        SearchActivityState(stage: stage, sourceCount: sourceCount, question: question)
    }

    func removingQuestion() -> SearchActivityState {
        showing(question: nil)
    }

    /// Texte de l'étape, tel qu'affiché (écran verrouillé et Dynamic Island).
    var statusText: String {
        switch stage {
        case .thinking: "Réflexion…"
        case .searching: "Recherche des sources…"
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
        return SearchActivityState(stage: .interrupted, sourceCount: sourceCount, question: question)
    }
}

/// Ce que `ChatViewModel` raconte d'un échange. Le contrôleur d'activité en tire un `SearchActivityState`.
nonisolated enum SearchProgressEvent: Sendable, Equatable {
    case started(question: String, conversationID: UUID?)
    /// La recherche de sources commence (la classification de la question est finie).
    case searching
    case sources(count: Int)
    /// Le modèle raisonne avant d'écrire (bloc de raisonnement ouvert, aucun mot de réponse encore).
    case reasoning
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
        case .thinking, .searching, .reading, .writing: false
        }
    }

    /// Rang dans le déroulé : une étape ne revient jamais en arrière (seule la réflexion du modèle, qui SUIT la lecture
    /// des sources, fait exception : voir `next`).
    private var rank: Int {
        switch self {
        case .thinking: 0
        case .searching: 1
        case .reading: 2
        case .writing: 3
        case .ready, .interrupted, .failed: 4
        }
    }

    /// État suivant `state` après `event`. La question de `state` est conservée.
    ///
    /// - Début : « Réflexion » (l'analyse de la question). La recherche des sources : « Recherche des sources ». Des
    ///   sources lues (au moins une) : « Lecture de N sources ».
    /// - Le modèle qui raisonne avant d'écrire : « Réflexion » de nouveau, même après la lecture des sources (c'est une
    ///   vraie étape du flux, qui les suit), sans perdre le nombre de sources. Jamais pendant ou après la rédaction.
    /// - Le premier MOT de la réponse (hors raisonnement) : « Rédaction ». C'est le flux qui compte, pas l'affichage :
    ///   en mode Fiable, le texte est retenu tant qu'il ne cite rien, mais le modèle écrit bel et bien.
    /// - Une étape ne recule jamais, et une étape finale (prête, interrompue, échouée) est définitive.
    static func next(_ state: SearchActivityState, event: SearchProgressEvent) -> SearchActivityState {
        if case .started = event { return .initial }
        guard !state.stage.isTerminal else { return state }
        switch event {
        case .started:
            return state
        case .searching:
            guard state.sourceCount == 0, state.stage.rank < SearchActivityStage.searching.rank else { return state }
            return state.moving(to: .searching)
        case .sources(let count):
            // Déjà des sources lues (ou réflexion qui les suit) : on ne relit pas.
            guard count > 0, state.sourceCount == 0, state.stage.rank < SearchActivityStage.reading.rank else { return state }
            return SearchActivityState(stage: .reading, sourceCount: count, question: state.question)
        case .reasoning:
            guard state.stage != .thinking, state.stage.rank < SearchActivityStage.writing.rank else { return state }
            return state.moving(to: .thinking)
        case .writing:
            guard state.stage.rank < SearchActivityStage.writing.rank else { return state }
            return state.moving(to: .writing)
        case .completed:
            return state.moving(to: .ready)
        case .interrupted:
            return state.moving(to: .interrupted)
        case .failed:
            return state.moving(to: .failed)
        }
    }
}

private nonisolated extension SearchActivityState {
    func moving(to stage: SearchActivityStage) -> SearchActivityState {
        SearchActivityState(stage: stage, sourceCount: sourceCount, question: question)
    }
}
