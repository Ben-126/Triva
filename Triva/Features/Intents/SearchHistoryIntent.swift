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
    /// La recherche porte sur le TEXTE des messages et rend des titres : sur un téléphone verrouillé, elle servirait
    /// d'oracle sur le contenu de l'historique. Siri demande donc de déverrouiller (mission X1, S1).
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

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
    func perform() async throws -> some IntentResult & ReturnsValue<[ConversationEntity]> & ProvidesDialog {
        let found = try Self.search(query, in: services.stores.chatHistory)
        let dialog = SearchHistoryDialog.text(count: found.count, limit: ConversationQuery.searchLimit)
        return .result(value: found, dialog: IntentDialog(LocalizedStringResource(stringLiteral: dialog)))
    }
}

/// Phrase lue par Siri après une recherche dans l'historique (textes « à valider par Ben »). Logique pure.
nonisolated enum SearchHistoryDialog {
    static func text(count: Int, limit: Int) -> String {
        switch count {
        case ..<1: "Aucune conversation trouvée."
        case 1: "Une conversation trouvée."
        // Limite atteinte : il y en a peut-être d'autres, le nombre n'est pas un total.
        case limit...: "Voici les \(limit) conversations les plus récentes qui correspondent."
        default: "\(count) conversations trouvées."
        }
    }
}

