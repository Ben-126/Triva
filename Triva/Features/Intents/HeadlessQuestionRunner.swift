//
//  HeadlessQuestionRunner.swift
//  Triva
//
//  Chantier 2.1 (mission B) : pose UNE question à Triva sans fenêtre (Siri, Raccourcis) et rend ce qui en sort.
//  Le travail est celui du `ChatViewModel` (le même pipeline que l'écran de recherche, la même conversation dans
//  l'historique) ; ce lanceur ajoute ce qu'une action sans écran exige : une question assainie, la garde du
//  consentement cloud AVANT tout envoi, la progression, l'annulation, et un résultat simple à rendre.
//

import Foundation

/// Ce que Siri et Raccourcis reçoivent d'une réponse.
nonisolated struct HeadlessAnswer: Sendable, Equatable {
    let question: String
    /// Texte complet, sans marques [n] ni mise en forme.
    let text: String
    /// Extrait lu à voix haute.
    let spoken: String
    let sourceTitles: [String]
    /// Adresses web (http, https) seulement.
    let sourceLinks: [URL]
    let conversationID: UUID?
}

nonisolated enum HeadlessQuestionOutcome: Sendable, Equatable {
    case answered(HeadlessAnswer)
    /// Pas d'accord pour ce fournisseur cloud : RIEN n'est parti.
    case consentRequired(providerName: String)
    case failed(message: String)
    case noReliableSources
    case interrupted

    /// Texte quand la recherche s'arrête avant sa fin sans cause plus précise (à valider par Ben).
    static let interruptedMessage = "La recherche a été interrompue."
    /// Texte quand la question est vide ou illisible (à valider par Ben).
    static let unreadableQuestionMessage = "Triva n'a pas compris ta question. Réessaie."
    /// Texte quand l'échec n'a laissé aucun message (à valider par Ben).
    static let unknownFailureMessage = "La recherche n'a pas abouti. Réessaie."
}

/// Étape annoncée au système pendant la recherche.
nonisolated enum HeadlessProgressStage: Sendable, Equatable {
    case searching
    case reading(sourceCount: Int)
    case writing

    /// Étape d'après ce que la réponse en cours porte. Les sources sont connues avant le premier texte :
    /// entre les deux, « Lecture de N sources ».
    static func stage(generationStage: GenerationStage, sourceCount: Int, hasText: Bool) -> HeadlessProgressStage {
        switch generationStage {
        case .analyzing, .searching:
            return .searching
        case .writing:
            if hasText || sourceCount == 0 { return .writing }
            return .reading(sourceCount: sourceCount)
        }
    }

    var description: String {
        switch self {
        case .searching: "Recherche…"
        case .reading(let count): count == 1 ? "Lecture d'une source" : "Lecture de \(count) sources"
        case .writing: "Rédaction…"
        }
    }

    /// Plage de la barre de progression pour cette étape : elle part de `start` et s'approche de `cap` sans
    /// jamais l'atteindre tout à fait.
    var band: (start: Int64, cap: Int64) {
        switch self {
        case .searching: (20, 300)
        case .reading: (300, 450)
        case .writing: (450, 950)
        }
    }
}

/// Ce que le lanceur annonce : l'étape et l'avancement de la barre, à CHAQUE battement.
nonisolated struct HeadlessProgressUpdate: Sendable, Equatable {
    let stage: HeadlessProgressStage
    let completedUnits: Int64
}

/// Fait avancer la barre de progression d'un cran à chaque battement, sans jamais reculer. Le système exige un
/// avancement RÉGULIER d'une action longue (sans quoi il peut l'annuler) : la rédaction d'un modèle local dure
/// 20 à 60 s sans changer d'étape, la barre doit pourtant bouger. Logique pure.
nonisolated struct HeadlessProgressMeter: Sendable, Equatable {
    static let totalUnits: Int64 = 1_000
    /// À chaque battement, la barre avance de (distance restante au plafond de l'étape) / ce diviseur, au moins 1.
    static let creepDivisor: Int64 = 100

    private(set) var completedUnits: Int64 = 0

    /// Un battement dans cette étape ; rend l'avancement.
    @discardableResult
    mutating func tick(stage: HeadlessProgressStage) -> Int64 {
        let band = stage.band
        if completedUnits < band.start {
            completedUnits = band.start
        } else if completedUnits < band.cap {
            let step = max(1, (band.cap - completedUnits) / Self.creepDivisor)
            completedUnits = min(band.cap, completedUnits + step)
        }
        return completedUnits
    }
}

@MainActor
final class HeadlessQuestionRunner {
    private let chatViewModel: ChatViewModel
    /// Garde en vie ce dont le modèle de chat dépend (la session sans fenêtre : ses closures ne la retiennent pas).
    private let owner: AnyObject?
    private let pollInterval: Duration

    init(chatViewModel: ChatViewModel, retaining owner: AnyObject? = nil, pollInterval: Duration = .milliseconds(250)) {
        self.chatViewModel = chatViewModel
        self.owner = owner
        self.pollInterval = pollInterval
    }

    /// Pose la question et attend la fin. `onProgress` reçoit l'étape et l'avancement à CHAQUE battement
    /// (`pollInterval`), jamais une étape ni un avancement en arrière.
    func run(
        question: String,
        onProgress: @escaping @MainActor (HeadlessProgressUpdate) -> Void
    ) async -> HeadlessQuestionOutcome {
        guard let cleaned = ExternalQuerySanitizer.sanitize(question) else {
            return .failed(message: HeadlessQuestionOutcome.unreadableQuestionMessage)
        }
        // Garde du consentement cloud : AVANT tout, rien n'est écrit ni envoyé sans l'accord.
        if let request = chatViewModel.consentRequestBeforeSending() {
            return .consentRequired(providerName: request.titleName)
        }
        chatViewModel.startSend(query: cleaned)
        guard let sendTask = chatViewModel.sendTask else { return .interrupted }

        let ticker = Task { @MainActor in await self.reportProgress(onProgress) }
        await withTaskCancellationHandler {
            await sendTask.value
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        ticker.cancel()
        return outcome(for: cleaned)
    }

    /// Arrête la recherche en cours ; la réponse partielle est gardée dans l'historique, comme avec « Stop ».
    func cancel() {
        chatViewModel.stop()
    }

    // MARK: - Progression

    private func reportProgress(_ onProgress: @MainActor (HeadlessProgressUpdate) -> Void) async {
        var meter = HeadlessProgressMeter()
        var last: HeadlessProgressStage?
        while !Task.isCancelled {
            var stage = currentStage()
            if let last, stage.band.start < last.band.start { stage = last }
            let units = meter.tick(stage: stage)
            onProgress(HeadlessProgressUpdate(stage: stage, completedUnits: units))
            last = stage
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func currentStage() -> HeadlessProgressStage {
        guard let answer = chatViewModel.messages.last, answer.role == .assistant else { return .searching }
        return HeadlessProgressStage.stage(
            generationStage: answer.generationStage,
            sourceCount: answer.sources.count,
            hasText: !answer.text.isEmpty
        )
    }

    // MARK: - Résultat

    private func outcome(for question: String) -> HeadlessQuestionOutcome {
        guard let answer = chatViewModel.messages.last, answer.role == .assistant else { return .interrupted }
        switch answer.status {
        case .completed:
            return completedOutcome(for: answer, question: question)
        case .failed:
            if let notice = chatViewModel.offlineNotice { return .failed(message: notice.reason.message) }
            return .failed(message: chatViewModel.errorDescription ?? HeadlessQuestionOutcome.unknownFailureMessage)
        case .noReliableSources:
            return .noReliableSources
        case .interrupted, .streaming:
            return .interrupted
        }
    }

    private func completedOutcome(for answer: ChatViewModel.Message, question: String) -> HeadlessQuestionOutcome {
        let visible = ChatViewModel.visibleText(of: answer.segments)
        let text = AnswerPlainText.plain(from: visible)
        guard !text.isEmpty else {
            return .failed(message: chatViewModel.errorDescription ?? HeadlessQuestionOutcome.unknownFailureMessage)
        }
        return .answered(HeadlessAnswer(
            question: question,
            text: text,
            spoken: AnswerPlainText.spoken(from: visible),
            sourceTitles: answer.sources.map(\.title),
            sourceLinks: answer.sources.compactMap { Self.webURL($0.url) },
            conversationID: chatViewModel.currentConversationID
        ))
    }

    /// Une adresse web seulement : Raccourcis ne reçoit jamais `file:`, `javascript:` ni autre schéma.
    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }
}
