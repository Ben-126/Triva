//
//  LocalModelTurnQueueTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// File d'attente du modèle local (mission M3) : ordre d'arrivée, remise idempotente, annulation.
@Suite("LocalModelTurnQueue")
@MainActor
struct LocalModelTurnQueueTests {
    @Test("Modèle libre -> tour immédiat ; rendu -> libre")
    func freeQueueGrantsImmediately() async throws {
        let queue = LocalModelTurnQueue()
        let turn = try await queue.acquire(for: UUID())
        #expect(queue.holder == turn)
        queue.release(turn)
        #expect(queue.holder == nil)
    }

    @Test("Les tours sont donnés dans l'ordre d'arrivée")
    func turnsAreFIFO() async throws {
        let queue = LocalModelTurnQueue()
        let first = try await queue.acquire(for: UUID())
        let secondWindow = UUID()
        let thirdWindow = UUID()
        let second = Task { try await queue.acquire(for: secondWindow) }
        #expect(await waitForPool { queue.waitingRequesters.count == 1 })
        let third = Task { try await queue.acquire(for: thirdWindow) }
        #expect(await waitForPool { queue.waitingRequesters.count == 2 })
        #expect(queue.waitingRequesters == [secondWindow, thirdWindow])

        queue.release(first)
        #expect(queue.holder?.requester == secondWindow)
        queue.release(try await second.value)
        #expect(queue.holder?.requester == thirdWindow)
        queue.release(try await third.value)
        #expect(queue.holder == nil)
    }

    @Test("Rendre deux fois, ou un vieux tour, ne libère jamais le tour de quelqu'un d'autre")
    func releaseIsIdempotent() async throws {
        let queue = LocalModelTurnQueue()
        let first = try await queue.acquire(for: UUID())
        let second = Task { try await queue.acquire(for: UUID()) }
        #expect(await waitForPool { queue.waitingRequesters.count == 1 })

        queue.release(first)
        let secondTurn = try await second.value
        queue.release(first)
        #expect(queue.holder == secondTurn)
    }

    @Test("Sa propre tâche précédente n'est pas « une autre fenêtre »")
    func ownPreviousWorkIsNotAnotherWindow() async throws {
        let queue = LocalModelTurnQueue()
        let window = UUID()
        let busy = try await queue.acquire(for: window)
        let next = Task { try await queue.acquire(for: window) }
        #expect(await waitForPool { queue.waitingRequesters.count == 1 })

        #expect(!queue.isWaitingBehindAnother(window))
        queue.release(busy)
        queue.release(try await next.value)
    }

    @Test("Tâche déjà annulée -> CancellationError sans prendre de place")
    func alreadyCancelledTaskThrows() async {
        let queue = LocalModelTurnQueue()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.acquire(for: UUID())
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(queue.holder == nil)
    }
}
