//
//  SearchHistoryIntent.swift
//  Triva
//
//  Chantier 2.1 (mission B) : « Chercher dans l'historique » (Raccourcis, Siri). Rend des conversations (titre et
//  date) : jamais le texte des réponses.
//

import AppIntents
import Foundation

struct SearchHistoryIntent: AppIntent {
    static var title: LocalizedStringResource { "Chercher dans l'historique" }
    static var description: IntentDescription {
        IntentDescription("Retrouve des conversations de ton historique Triva.")
    }

    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Recherche", requestValueDialog: "Que veux-tu retrouver ?")
    var query: String

    @Dependency var services: TrivaAppServices

    init() {}

    init(query: String) {
        self.query = query
    }

    /// Les conversations dont le titre ou le texte contient `query` (20 au plus, les plus récentes d'abord) ;
    /// une recherche vide ne trouve rien.
    @MainActor
    static func search(_ query: String, in store: ChatHistoryStore) throws -> [ConversationEntity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try ConversationQuery.entities(matching: trimmed, in: store)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ConversationEntity]> {
        .result(value: try Self.search(query, in: services.stores.chatHistory))
    }
}
