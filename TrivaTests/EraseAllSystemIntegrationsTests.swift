//
//  EraseAllSystemIntegrationsTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : « Tout effacer » vide aussi ce que l'app a publié hors d'elle (widget, boîte de partage,
//  recherche de l'appareil, activités en direct). Faux d'un bout à l'autre : jamais le vrai App Group du Mac, jamais
//  le vrai index Spotlight.
//

import Foundation
import Testing
@testable import Triva

@MainActor
private final class FakeIntegrationsEraser: SystemIntegrationsErasing {
    private(set) var callCount = 0
    private(set) var historyWasAlreadyErased: Bool?
    private let result: Bool
    private let history: CountingHistory?

    init(result: Bool = true, history: CountingHistory? = nil) {
        self.result = result
        self.history = history
    }

    func eraseAll() async -> Bool {
        callCount += 1
        historyWasAlreadyErased = history.map { $0.callCount > 0 }
        return result
    }
}

@MainActor
private final class CountingHistory: AllDeleting {
    private(set) var callCount = 0
    func deleteAll() throws { callCount += 1 }
}

@MainActor
private func makeEraser(
    history: CountingHistory = CountingHistory(),
    integrations: (any SystemIntegrationsErasing)?
) -> LocalDataEraser {
    LocalDataEraser(
        chatHistory: history,
        favorites: CountingHistory(),
        discoverCache: DiscoverNoCache(),
        urlCache: URLCache(memoryCapacity: 0, diskCapacity: 0),
        storage: nil,
        clearBrowserData: { .completed },
        previewDismissDelay: .zero,
        systemIntegrations: integrations
    )
}

@MainActor
@Suite("Tout effacer : intégrations système")
struct EraseAllSystemIntegrationsTests {
    @Test("Les intégrations sont vidées, et APRÈS l'historique (ce qu'elles publiaient en vient)")
    func integrationsAreErasedAfterHistory() async throws {
        let history = CountingHistory()
        let integrations = FakeIntegrationsEraser(history: history)

        try await makeEraser(history: history, integrations: integrations).eraseAll()

        #expect(integrations.callCount == 1)
        #expect(integrations.historyWasAlreadyErased == true)
    }

    @Test("Une intégration qui n'a pas tout retiré : .incomplete([intégrations système]), le reste a été effacé")
    func failureIsReported() async {
        let history = CountingHistory()
        let integrations = FakeIntegrationsEraser(result: false)

        do {
            try await makeEraser(history: history, integrations: integrations).eraseAll()
            Issue.record("Un effacement incomplet doit lever une erreur.")
        } catch {
            #expect(error == .incomplete(failedSteps: [.systemIntegrations]))
        }
        #expect(history.callCount == 1)
    }

    @Test("Sans intégrations injectées (tests, aperçus) : rien n'est touché, aucune erreur")
    func nilIntegrationsDoNothing() async throws {
        try await makeEraser(integrations: nil).eraseAll()
    }

    @Test("Le message d'échec nomme les intégrations système, seules ou avec le reste")
    func incompleteMessageMentionsIntegrations() {
        let alone = LocalDataEraseSection.incompleteMessage(failedSteps: [.systemIntegrations])
        #expect(alone.contains("widget"))
        #expect(alone.contains("Le reste a été effacé"))

        let withHistory = LocalDataEraseSection.incompleteMessage(failedSteps: [.history, .systemIntegrations])
        #expect(withHistory.contains("widget"))
        #expect(withHistory.contains("conversations"))
    }
}
