//
//  OpenConversationIntent.swift
//  Triva
//
//  Chantier 2.1 (mission A) : « Ouvrir une conversation » (Raccourcis, Siri, résultat Spotlight). Ne fait que
//  naviguer.
//

import AppIntents
import Foundation

struct OpenConversationIntent: OpenIntent {
    static var title: LocalizedStringResource { "Ouvrir une conversation" }
    static var description: IntentDescription {
        IntentDescription("Ouvre une conversation de ton historique dans Triva.")
    }

    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Conversation", requestValueDialog: "Quelle conversation ouvrir ?")
    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        let id = target.id
        await SystemRouteDispatcher.shared.submit(.conversation(id))
        return .result()
    }
}
