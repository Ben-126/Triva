//
//  HeadlessQuestionPolicy.swift
//  Triva
//
//  Chantier 2.1 (mission B) : ce que « Poser une question à Triva » (Siri, Raccourcis) a le droit de faire SANS
//  fenêtre. Logique pure : elle ne regarde que ce que le contexte lui dit, jamais un store.
//
//  Règle d'or : une question n'est JAMAIS envoyée à une IA cloud sans l'accord de l'utilisateur pour ce
//  fournisseur. Ici, ce qui n'est pas clairement « accordé » vaut « manquant » (on échoue du côté sûr).
//

import Foundation

nonisolated enum HeadlessPlatform: Sendable, Equatable {
    case iOS
    case mac

    static var current: HeadlessPlatform {
        #if os(macOS)
        return .mac
        #else
        return .iOS
        #endif
    }
}

/// Accord d'envoi au fournisseur cloud du moteur.
nonisolated enum HeadlessCloudConsent: Sendable, Equatable {
    /// Le moteur n'est pas un moteur cloud.
    case notApplicable
    case granted
    /// Pas d'accord : le nom du fournisseur à citer dans le message.
    case missing(providerName: String)
}

nonisolated struct HeadlessQuestionContext: Sendable, Equatable {
    /// L'utilisateur a vu l'écran « Triva répond avec une IA » (AI Act art. 50(1)) : sur une installation neuve il
    /// passe avant le choix du moteur ; une app installée avant cet écran peut avoir un moteur choisi sans l'avoir vu.
    var noticeAcknowledged: Bool
    /// Moteur choisi par l'utilisateur, `nil` tant qu'il n'en a pas choisi.
    var engine: AIEngineOption?
    /// Le moteur est utilisable (modèle MLX choisi, fournisseur cloud choisi). Sans objet pour Apple Intelligence.
    var isEngineReady: Bool
    var cloudConsent: HeadlessCloudConsent
    var platform: HeadlessPlatform
}

/// Comment exécuter la question une fois autorisée.
nonisolated enum HeadlessExecution: Sendable, Equatable {
    /// Temps d'exécution prolongé, sans exigence particulière.
    case standard
    /// Modèle local sur iPhone ou iPad : le calcul demande le GPU en arrière-plan (NON VÉRIFIÉ sur appareil).
    case backgroundWithGPU
}

nonisolated enum HeadlessDecision: Sendable, Equatable {
    case run(HeadlessExecution)
    /// L'information « Triva répond avec une IA » n'a pas encore été lue : l'utilisateur doit ouvrir Triva.
    case needsAINotice
    /// Aucun moteur utilisable : l'utilisateur doit ouvrir Triva.
    case needsEngineChoice
    /// Pas d'accord pour ce fournisseur : rien n'est envoyé, la question attend dans la barre de saisie.
    case needsCloudConsent(providerName: String)
}

nonisolated enum HeadlessQuestionPolicy {
    /// Nom cité quand le contexte ne sait pas dire quel fournisseur (ne devrait pas arriver).
    static let unknownProviderName = "ton fournisseur d'IA"

    static let engineChoiceDialog = "Ouvre Triva pour choisir ton moteur d'IA."
    /// Texte « à valider par Ben ».
    static let aiNoticeDialog = "Ouvre Triva pour lire l'information sur l'IA, avant ta première question."

    static func consentDialog(providerName: String) -> String {
        "Ouvre Triva pour autoriser l'envoi à \(providerName)."
    }

    static func decide(_ context: HeadlessQuestionContext) -> HeadlessDecision {
        guard context.noticeAcknowledged else { return .needsAINotice }
        guard let engine = context.engine else { return .needsEngineChoice }
        switch engine {
        case .appleIntelligence:
            return .run(.standard)
        case .mlxLocal:
            guard context.isEngineReady else { return .needsEngineChoice }
            return .run(context.platform == .iOS ? .backgroundWithGPU : .standard)
        case .cloudBYOK:
            guard context.isEngineReady else { return .needsEngineChoice }
            switch context.cloudConsent {
            case .granted:
                return .run(.standard)
            case .missing(let providerName):
                return .needsCloudConsent(providerName: providerName)
            case .notApplicable:
                // Un moteur cloud dont l'accord est « sans objet » est une erreur de contexte : on s'arrête.
                return .needsCloudConsent(providerName: unknownProviderName)
            }
        }
    }
}
