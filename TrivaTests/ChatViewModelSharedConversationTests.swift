//
//  ChatViewModelSharedConversationTests.swift
//  TrivaTests
//
//  Mission F2 (26/11), point 1 : une conversation affichée dans une fenêtre B pendant que la fenêtre A y répond montre
//  la réponse quand elle arrive (Mac et iPad à plusieurs fenêtres : chaque fenêtre a son `ChatViewModel`, l'historique
//  et `ActiveExchangeRegistry` sont partagés).
//

import Foundation
import Testing
@testable import Triva

extension ChatViewModelTests {
    /// Le fournisseur que la fenêtre A utilise pour son prochain envoi.
    private final class ProviderBox {
        var current: any AIGenerating
        init(_ provider: any AIGenerating) { current = provider }
    }

    @Test("Fenêtre B ouverte pendant que A répond : B montre la réponse dès qu'elle arrive (F2)")
    func otherWindowShowsTheAnswerWhenItArrives() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let windowA = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        windowA.startSend(query: "Question A")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        let id = try #require(windowA.currentConversationID)
        let windowB = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        #expect(windowB.loadConversation(id: id))
        #expect(windowB.messages.map(\.text) == ["Question A"])

        continuation.yield("Réponse A")
        continuation.finish()
        await waitUntil("A finie") { !windowA.isGenerating }

        #expect(windowB.messages.map(\.text) == ["Question A", "Réponse A"])
        #expect(windowB.messages.last?.status == .completed)
        #expect(windowB.currentConversationID == id)
    }

    @Test("Conversation déjà affichée au repos dans B : la nouvelle question de A apparaît, puis sa réponse (F2)")
    func otherWindowAtRestFollowsANewQuestion() async throws {
        let stores = try PersistenceStores()
        let first = MockStreamingAIGenerating(chunks: ["Réponse 1"])
        let box = ProviderBox(first)
        let windowA = makeViewModel(resolveProvider: { box.current }, stores: stores)
        await windowA.send(query: "Question 1")
        let id = try #require(windowA.currentConversationID)
        let windowB = makeViewModel(resolveProvider: { first }, stores: stores)
        #expect(windowB.loadConversation(id: id))
        #expect(windowB.messages.map(\.text) == ["Question 1", "Réponse 1"])

        let second = ControllableStreamingAIGenerating()
        box.current = second
        windowA.startSend(query: "Question 2")
        guard let continuation = await waitForContinuation(second) else { return }
        // La question est déjà dans l'historique : B la montre, sans « Réponse interrompue » (A y répond).
        #expect(windowB.messages.map(\.text) == ["Question 1", "Réponse 1", "Question 2"])

        continuation.yield("Réponse 2")
        continuation.finish()
        await waitUntil("A finie") { !windowA.isGenerating }
        #expect(windowB.messages.map(\.text) == ["Question 1", "Réponse 1", "Question 2", "Réponse 2"])
    }

    @Test("La fenêtre qui répond n'est pas rechargée à la fin de SA réponse : sa bulle garde son identité (F2)")
    func ownAnswerIsNotReloaded() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let window = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        window.startSend(query: "Question")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        let bubbleID = try #require(window.messages.last?.id)

        continuation.yield("Réponse")
        continuation.finish()
        await waitUntil("réponse finie") { !window.isGenerating }

        #expect(window.messages.map(\.text) == ["Question", "Réponse"])
        #expect(window.messages.last?.id == bubbleID)
    }

    @Test("Une autre conversation affichée dans B n'est pas touchée (F2)")
    func unrelatedConversationIsUntouched() async throws {
        let stores = try PersistenceStores()
        let other = try stores.history.createConversation(firstQuestion: "Autre")
        try stores.history.appendUserMessage(to: other, text: "Autre")
        try stores.history.appendAssistantMessage(to: other, text: "Autre réponse.", sources: [])
        let aiProvider = ControllableStreamingAIGenerating()
        let windowA = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        let windowB = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        #expect(windowB.loadConversation(id: other.id))
        let shown = windowB.messages.map(\.id)

        windowA.startSend(query: "Question A")
        guard let continuation = await waitForContinuation(aiProvider) else { return }
        continuation.yield("Réponse A")
        continuation.finish()
        await waitUntil("A finie") { !windowA.isGenerating }

        #expect(windowB.messages.map(\.id) == shown)
        #expect(windowB.currentConversationID == other.id)
    }

    @Test("B qui génère elle-même dans cette conversation n'est pas remplacée sous ses yeux (F2)")
    func generatingWindowIsNotReplaced() async throws {
        let stores = try PersistenceStores()
        let providerA = ControllableStreamingAIGenerating()
        let providerB = ControllableStreamingAIGenerating()
        let windowA = makeViewModel(resolveProvider: { providerA }, stores: stores)
        windowA.startSend(query: "Question A")
        guard let continuationA = await waitForContinuation(providerA) else { return }
        let id = try #require(windowA.currentConversationID)
        let windowB = makeViewModel(resolveProvider: { providerB }, stores: stores)
        #expect(windowB.loadConversation(id: id))
        windowB.startSend(query: "Question B")
        guard let continuationB = await waitForContinuation(providerB) else { return }
        let bubbleB = try #require(windowB.messages.last?.id)

        continuationA.yield("Réponse A")
        continuationA.finish()
        await waitUntil("A finie") { !windowA.isGenerating }
        #expect(windowB.isGenerating)
        #expect(windowB.messages.last?.id == bubbleB)

        continuationB.yield("Réponse B")
        continuationB.finish()
        await waitUntil("B finie") { !windowB.isGenerating }
        #expect(windowB.messages.last?.text == "Réponse B")
        #expect(windowB.messages.last?.id == bubbleB)
    }
}

@MainActor
@Suite("Fil en retard sur l'historique (mission F2)")
struct ThreadBehindHistoryTests {
    typealias Message = ChatViewModel.Message

    private func answer(_ text: String) -> Message {
        var message = Message(role: .assistant, isStreaming: true)
        message.apply(snapshot: text, at: .now)
        message.finish(.completed, at: .now)
        return message
    }

    private var interruptedMarker: Message {
        var message = Message(role: .assistant)
        message.finish(.interrupted, at: .now)
        return message
    }

    @Test("Historique plus long que le fil : en retard")
    func storedLongerIsBehind() {
        #expect(ChatViewModel.isBehindHistory(displayed: [Message(role: .user, text: "Q")], storedCount: 2))
        #expect(ChatViewModel.isBehindHistory(displayed: [], storedCount: 1))
    }

    @Test("Même longueur, ou fil plus long (réponse en échec non écrite) : pas en retard")
    func sameOrLongerIsNotBehind() {
        let thread = [Message(role: .user, text: "Q"), answer("R")]
        #expect(!ChatViewModel.isBehindHistory(displayed: thread, storedCount: 2))
        #expect(!ChatViewModel.isBehindHistory(displayed: thread, storedCount: 1))
        #expect(!ChatViewModel.isBehindHistory(displayed: [], storedCount: 0))
    }

    @Test("Les « Réponse interrompue » reconstruites ne comptent pas : elles ne sont pas dans l'historique")
    func interruptedMarkersAreNotCounted() {
        let thread = [Message(role: .user, text: "Q1"), interruptedMarker, Message(role: .user, text: "Q2")]
        #expect(!ChatViewModel.isBehindHistory(displayed: thread, storedCount: 2))
        #expect(ChatViewModel.isBehindHistory(displayed: thread, storedCount: 3))
    }
}
