//
//  OpenComposerIntent.swift
//  TrivaShared
//
//  Chantier 2.1 (mission A) : « Ouvrir une nouvelle recherche » (Raccourcis, Siri, bouton Action, Centre de
//  contrôle). Compilé dans l'app ET dans l'extension Widgets (la commande l'utilise) : rien d'ici ne doit
//  nommer un type de l'app. L'intent ne fait que NAVIGUER : il n'envoie jamais une question.
//

import AppIntents
import Foundation

/// Mode de saisie proposé par l'intent. `.keyboard` seul en 2.1 ; le cas `.voice` s'ajoutera avec le chantier 2.7.
nonisolated enum ComposerEntryAppEnum: String, AppEnum {
    case keyboard

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Mode de saisie")
    }

    static var caseDisplayRepresentations: [ComposerEntryAppEnum: DisplayRepresentation] {
        [.keyboard: DisplayRepresentation(title: "Clavier")]
    }

    /// Le mode de saisie correspondant dans les routes.
    var kind: ComposerEntryKind {
        switch self {
        case .keyboard: .keyboard
        }
    }
}

struct OpenComposerIntent: OpenIntent {
    static var title: LocalizedStringResource { "Ouvrir une nouvelle recherche" }
    static var description: IntentDescription {
        IntentDescription("Ouvre Triva sur une recherche vide, prête à écrire.")
    }

    /// Fixé dans l'app : la navigation s'exécute là où vivent les fenêtres (jamais dans une extension).
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    /// Valeur par défaut : sans elle, Raccourcis et Siri demanderaient quel mode choisir à chaque fois.
    @Parameter(title: "Saisie", default: .keyboard)
    var target: ComposerEntryAppEnum

    init() {}

    init(target: ComposerEntryAppEnum) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        let kind = target.kind
        await SystemRouteDispatcher.shared.submit(.newQuestion(kind))
        return .result()
    }
}
