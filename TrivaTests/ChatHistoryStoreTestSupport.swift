//
//  ChatHistoryStoreTestSupport.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/09/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

// MARK: - Fabriques et outils

// Toutes les suites sont `@MainActor`, comme `ChatHistoryStore` et
// `TrivaModelContainer` qui travaillent sur le `mainContext` (isolation
// expliquée en tête de `ChatHistoryModels.swift`). Aucune ne mesure de temps
// réel écoulé, donc aucune n'a besoin de rester non isolée comme
// `WidgetExecutorTests`.

/// Store de test, adossé à un conteneur **en mémoire** neuf. Jamais
/// `TrivaModelContainer.shared` : un test ne doit ni lire ni toucher le fichier
/// réel de l'utilisateur. Locale imposée plutôt que `.current`, pour que le
/// repliement de casse et d'accents ne dépende pas de la machine de test.
@MainActor
func historyMakeStore() throws -> ChatHistoryStore {
    let container = try TrivaModelContainer.makeInMemory()
    return ChatHistoryStore(container: container, locale: Locale(identifier: "fr_FR"))
}

/// Date déterministe : les tests d'ordre chronologique doivent pouvoir
/// fabriquer un ordre exact sans jamais dormir ni dépendre de l'horloge.
func historyDate(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
}

/// Source reconnaissable à son index. `content` est explicite et sans valeur par
/// défaut : un extrait réellement absent (`nil`) doit être exprimable.
func historyMakeSource(_ index: Int, content: String?) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: "Source \(index)",
        url: "https://exemple\(index).fr/article",
        content: content,
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

func historyMakeSources(_ count: Int) -> [SearXNGSearchResult] {
    (1...count).map { historyMakeSource($0, content: "Extrait \($0)") }
}

/// Contexte **neuf** sur le même conteneur : l'outil central de ce fichier.
///
/// Le store désactive `autosaveEnabled` et relit tout par le `mainContext` : un
/// test qui vérifie une écriture depuis ce même contexte passerait même si
/// `save()` n'était jamais appelé. Un contexte neuf ne voit que ce qui a
/// réellement atteint le store — seule façon de prouver qu'une écriture a été
/// validée et qu'une cascade a bien effacé les enfants.
@MainActor
func historyFreshContext(_ store: ChatHistoryStore) -> ModelContext {
    ModelContext(store.container)
}

@MainActor
func historyStoredConversationCount(in store: ChatHistoryStore) throws -> Int {
    try historyFreshContext(store).fetchCount(FetchDescriptor<StoredConversation>())
}

@MainActor
func historyStoredMessages(in store: ChatHistoryStore) throws -> [StoredMessage] {
    try historyFreshContext(store).fetch(FetchDescriptor<StoredMessage>())
}

@MainActor
func historyStoredSources(in store: ChatHistoryStore) throws -> [StoredSource] {
    try historyFreshContext(store).fetch(FetchDescriptor<StoredSource>())
}
