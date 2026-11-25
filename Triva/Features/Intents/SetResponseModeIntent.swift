//
//  SetResponseModeIntent.swift
//  Triva
//
//  Chantier 2.1 (mission B) : « Choisir le mode de réponse » (Raccourcis, Siri). Écrit dans l'instance PARTAGÉE
//  du store (`ResponseModeSettingsStore.shared`) : le sélecteur affiché dans l'app la lit aussi, il ne peut donc
//  pas montrer un mode périmé.
//

import AppIntents
import Foundation

struct SetResponseModeIntent: AppIntent {
    static var title: LocalizedStringResource { "Choisir le mode de réponse" }
    static var description: IntentDescription {
        IntentDescription("Change le mode de réponse de Triva : rapide, approfondie ou fiable.")
    }

    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    /// Un réglage de l'app ne se change pas depuis un téléphone verrouillé (mission X1, S1).
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Mode")
    var mode: ResponseModeAppEnum

    init() {}

    init(mode: ResponseModeAppEnum) {
        self.mode = mode
    }

    /// Le store que l'intent écrit : celui de l'app.
    @MainActor
    static var targetStore: ResponseModeSettingsStore { .shared }

    /// Phrase lue après le changement.
    static func dialog(for mode: ResponseMode) -> String {
        "Mode de réponse : \(mode.title)."
    }

    /// Écrit le mode dans `store` et rend la phrase à lire.
    @MainActor
    static func apply(_ mode: ResponseMode, to store: ResponseModeSettingsStore) -> String {
        store.selectedMode = mode
        return dialog(for: mode)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = Self.apply(mode.mode, to: Self.targetStore)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    }
}
