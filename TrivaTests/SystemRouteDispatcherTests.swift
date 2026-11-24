//
//  SystemRouteDispatcherTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission A) : un intent peut s'exécuter avant que l'app ait branché son routeur (lancement à
//  froid) ; la route ne doit pas se perdre.
//

import AppIntents
import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Pont intents -> routeur")
struct SystemRouteDispatcherTests {
    @Test("Routes reçues avant le routeur : gardées, puis livrées dans l'ordre dès son branchement")
    func buffersUntilInstalled() {
        let dispatcher = SystemRouteDispatcher()
        let id = UUID()
        dispatcher.submit(.newQuestion(.keyboard))
        dispatcher.submit(.conversation(id))
        #expect(dispatcher.bufferedCount == 2)

        var received: [SystemRoute] = []
        dispatcher.install { received.append($0) }

        #expect(received == [.newQuestion(.keyboard), .conversation(id)])
        #expect(dispatcher.bufferedCount == 0)
    }

    @Test("Routeur branché : livraison immédiate, rien n'est gardé")
    func deliversImmediately() {
        let dispatcher = SystemRouteDispatcher()
        var received: [SystemRoute] = []
        dispatcher.install { received.append($0) }

        dispatcher.submit(.newQuestion(.keyboard))

        #expect(received == [.newQuestion(.keyboard)])
        #expect(dispatcher.bufferedCount == 0)
    }

    @Test("Mémoire bornée : au-delà de la capacité, les plus anciennes sont oubliées")
    func bufferIsBounded() {
        let dispatcher = SystemRouteDispatcher()
        let ids = (0..<(SystemRouteDispatcher.bufferCapacity + 3)).map { _ in UUID() }
        for id in ids { dispatcher.submit(.conversation(id)) }
        #expect(dispatcher.bufferedCount == SystemRouteDispatcher.bufferCapacity)

        var received: [SystemRoute] = []
        dispatcher.install { received.append($0) }

        #expect(received == ids.suffix(SystemRouteDispatcher.bufferCapacity).map { .conversation($0) })
    }
}

/// Les intents et la requête d'entités restent isolés au main actor (un type qui porte `@Parameter` ou
/// `@Dependency` ne peut pas être `nonisolated`). Le système cherche leurs conformances HORS du main actor : si
/// une conformance isolée n'y était pas visible, Raccourcis et Siri ne trouveraient jamais l'intent.
@Suite("Conformances App Intents hors du main actor")
struct IntentConformanceOffMainActorTests {
    @Test("OpenComposerIntent, OpenConversationIntent et ConversationQuery sont reconnus depuis une tâche détachée")
    func conformancesAreVisibleOffMainActor() async {
        let results = await Task.detached {
            [
                (OpenComposerIntent.self as Any.Type) is any AppIntent.Type,
                (OpenConversationIntent.self as Any.Type) is any AppIntent.Type,
                (ConversationQuery.self as Any.Type) is any EntityStringQuery.Type,
                (ConversationEntity.self as Any.Type) is any AppEntity.Type,
            ]
        }.value
        #expect(results == [true, true, true, true])
    }
}
