//
//  HandoffReceiverTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : ce que le receveur fait d'une activité Handoff qui propose une discussion :
//  flux réussi = conversation enregistrée puis ouverte ; flux en échec = repli sur le brouillon (comportement de H1)
//  et un message clair. Les flux sont factices ici ; la vraie paire de flux est essayée dans HandoffStreamTransferTests.
//

import Foundation
import Testing
@testable import Triva

@MainActor
private final class FakeFetcher: HandoffConversationFetching {
    var result: Result<HandoffConversationSnapshot, any Error>
    private(set) var calls = 0
    init(_ result: Result<HandoffConversationSnapshot, any Error>) { self.result = result }
    func fetch(expectedID: UUID) async throws -> HandoffConversationSnapshot {
        calls += 1
        return try result.get()
    }
}

@MainActor
private final class FakeImporter: HandoffConversationImporting {
    var failure: (any Error)?
    private(set) var imported: [(HandoffConversationSnapshot, Bool)] = []
    var assignedID: UUID?
    func importHandoff(_ snapshot: HandoffConversationSnapshot, isHeldByAWindow: Bool) throws -> HandoffImportResult {
        if let failure { throw failure }
        imported.append((snapshot, isHeldByAWindow))
        let resolved = assignedID ?? snapshot.id
        return HandoffImportResult(conversationID: resolved, disposition: resolved == snapshot.id ? .created : .createdAsCopy)
    }
}

@MainActor
@Suite("Handoff conversation : réception")
struct HandoffReceiverTests {
    private let id = HandoffFixtures.conversationID

    private func payload(draft: String = "Ma question", typed: Bool = true, conversation: Bool = true) throws -> HandoffPayload {
        try #require(HandoffPayload(draft: draft, conversationID: conversation ? id : nil, draftIsTyped: typed))
    }

    @Test("Sans discussion proposée : le texte va dans la barre, le flux n'est même pas demandé")
    func draftOnly() async throws {
        let fetcher = FakeFetcher(.success(HandoffFixtures.snapshot()))
        let importer = FakeImporter()
        let result = await HandoffReceiver.receive(
            payload: try payload(conversation: false), fetcher: fetcher, importer: importer, isHeldByAWindow: { _ in false }
        )
        #expect(result == .draft("Ma question"))
        #expect(fetcher.calls == 0)
        #expect(importer.imported.isEmpty)
    }

    @Test("Flux réussi : la discussion est enregistrée puis ouverte, le texte tapé va dans la barre")
    func conversationReceived() async throws {
        let snapshot = HandoffFixtures.snapshot()
        let fetcher = FakeFetcher(.success(snapshot))
        let importer = FakeImporter()
        let result = await HandoffReceiver.receive(
            payload: try payload(draft: "Suite à écrire"), fetcher: fetcher, importer: importer, isHeldByAWindow: { _ in false }
        )
        #expect(result == .conversation(id: id, draft: "Suite à écrire"))
        #expect(importer.imported.count == 1)
        #expect(importer.imported[0].0 == snapshot)
        #expect(importer.imported[0].1 == false)
        #expect(HandoffReceiver.routes(for: result) == [.conversation(id), .draft("Suite à écrire")])
    }

    @Test("Le « texte » n'était que la dernière question : elle est déjà dans la discussion, la barre reste vide")
    func lastQuestionIsNotRepeated() async throws {
        let result = await HandoffReceiver.receive(
            payload: try payload(draft: "Question 2", typed: false),
            fetcher: FakeFetcher(.success(HandoffFixtures.snapshot())), importer: FakeImporter(), isHeldByAWindow: { _ in false }
        )
        #expect(result == .conversation(id: id, draft: nil))
        #expect(HandoffReceiver.routes(for: result) == [.conversation(id)])
    }

    @Test("Une fenêtre tient déjà la conversation : l'enregistrement le sait et la copie s'ouvre")
    func heldConversationIsCopied() async throws {
        let copyID = UUID()
        let importer = FakeImporter()
        importer.assignedID = copyID
        let result = await HandoffReceiver.receive(
            payload: try payload(draft: "x", typed: false),
            fetcher: FakeFetcher(.success(HandoffFixtures.snapshot())), importer: importer, isHeldByAWindow: { $0 == HandoffFixtures.conversationID }
        )
        #expect(importer.imported.first?.1 == true)
        #expect(result == .conversation(id: copyID, draft: nil))
    }

    @Test("Flux en échec (délai, coupure, refus, contenu hostile) : repli sur le texte de H1, jamais une erreur technique")
    func fetchFailureFallsBack() async throws {
        let failures: [any Error] = [
            HandoffTransferError.timedOut, HandoffTransferError.closedEarly, HandoffTransferError.badFrame,
            HandoffTransferError.invalidSnapshot(.malformed), HandoffSnapshotError.tooLarge, CancellationError(),
        ]
        for failure in failures where !(failure is CancellationError) {
            let importer = FakeImporter()
            let result = await HandoffReceiver.receive(
                payload: try payload(draft: "Ma question"), fetcher: FakeFetcher(.failure(failure)),
                importer: importer, isHeldByAWindow: { _ in false }
            )
            #expect(result == .fellBack(draft: "Ma question"))
            #expect(importer.imported.isEmpty)
            #expect(HandoffReceiver.routes(for: result) == [.draft("Ma question")])
        }
    }

    @Test("Annulation : rien n'est enregistré ni placé")
    func cancellationPlacesNothing() async throws {
        let importer = FakeImporter()
        let result = await HandoffReceiver.receive(
            payload: try payload(), fetcher: FakeFetcher(.failure(CancellationError())),
            importer: importer, isHeldByAWindow: { _ in false }
        )
        #expect(result == .cancelled)
        #expect(HandoffReceiver.routes(for: result).isEmpty)
        #expect(importer.imported.isEmpty)
    }

    @Test("Pas de flux (getContinuationStreams a échoué) : même repli")
    func missingStreamsFallBack() async throws {
        let source = FailingStreamSource()
        let result = await HandoffReceiver.receive(
            payload: try payload(), fetcher: HandoffStreamFetcher(source: source), importer: FakeImporter(), isHeldByAWindow: { _ in false }
        )
        #expect(result == .fellBack(draft: "Ma question"))
    }

    @Test("La discussion reçue porte un autre identifiant que l'en-tête : refusée, repli")
    func mismatchedSnapshotFallsBack() async throws {
        let importer = FakeImporter()
        let result = await HandoffReceiver.receive(
            payload: try payload(), fetcher: FakeFetcher(.success(HandoffFixtures.snapshot(id: UUID()))),
            importer: importer, isHeldByAWindow: { _ in false }
        )
        #expect(result == .fellBack(draft: "Ma question"))
        #expect(importer.imported.isEmpty)
    }

    @Test("Enregistrement impossible (base indisponible) : repli, le texte n'est pas perdu")
    func importFailureFallsBack() async throws {
        let importer = FakeImporter()
        importer.failure = ChatHistoryStoreError.storageUnavailable
        let result = await HandoffReceiver.receive(
            payload: try payload(), fetcher: FakeFetcher(.success(HandoffFixtures.snapshot())),
            importer: importer, isHeldByAWindow: { _ in false }
        )
        #expect(result == .fellBack(draft: "Ma question"))
    }

    @Test("Seules des routes sûres sortent : conversation ou texte, jamais un envoi")
    func routesNeverSend() {
        let all: [HandoffReceiveResult] = [
            .conversation(id: id, draft: "a"), .conversation(id: id, draft: nil), .draft("a"), .fellBack(draft: "a"), .cancelled,
        ]
        for result in all {
            for route in HandoffReceiver.routes(for: result) {
                switch route {
                case .draft, .conversation: break
                default: Issue.record("Route inattendue : \(route)")
                }
            }
        }
    }

    @Test("Le message de repli existe, est court et ne parle pas de technique")
    func fallbackMessage() {
        let message = HandoffReceiver.fallbackNotice
        #expect(!message.isEmpty && message.count < 160)
        #expect(!message.lowercased().contains("stream") && !message.lowercased().contains("flux"))
    }
}

private struct FailingStreamSource: HandoffStreamSource {
    func streams() async throws -> HandoffStreamPair { throw HandoffTransferError.noStreams }
}

@MainActor
@Suite("Handoff conversation : de l'envoi à la réception, sur de vraies paires de flux", .timeLimit(.minutes(1)))
struct HandoffEndToEndTests {
    private struct ImmediateSource: HandoffStreamSource {
        let pair: HandoffStreamPair
        func streams() async throws -> HandoffStreamPair { pair }
    }

    @Test("L'envoyeur lit sa base, le receveur enregistre : la discussion se retrouve à l'identique")
    func fullRoundTrip() async throws {
        // Appareil A : une conversation enregistrée avec une réponse et ses sources.
        let sender = try historyMakeStore()
        let conversation = try sender.createConversation(title: "Les volcans", now: historyDate(0))
        try sender.appendUserMessage(to: conversation, text: "Comment naît un volcan ?", now: historyDate(1))
        try sender.appendAssistantMessage(
            to: conversation, text: "Par la remontée du magma [1].",
            sources: [historyMakeSource(0, content: "Un extrait")], now: historyDate(2)
        )
        let data = try #require(HandoffSnapshotSource.data(for: conversation.id, isEnabled: true, store: sender))

        // Deux tuyaux, comme ceux du système.
        var aIn: InputStream?, bOut: OutputStream?, bIn: InputStream?, aOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4_096, inputStream: &aIn, outputStream: &bOut)
        Stream.getBoundStreams(withBufferSize: 4_096, inputStream: &bIn, outputStream: &aOut)
        let originator = HandoffStreamPair(input: aIn!, output: aOut!)
        let receiverStreams = HandoffStreamPair(input: bIn!, output: bOut!)

        // Appareil B : une base vide.
        let receiver = try historyMakeStore()
        let header = try #require(HandoffPayload(draft: "Comment naît un volcan ?", conversationID: conversation.id, draftIsTyped: false))
        async let served: Void = HandoffStreamTransfer.serve(over: originator, timeout: .seconds(5)) { data }
        let result = await HandoffReceiver.receive(
            payload: header, fetcher: HandoffStreamFetcher(source: ImmediateSource(pair: receiverStreams), timeout: .seconds(5)),
            importer: receiver, isHeldByAWindow: { _ in false }
        )
        try await served

        #expect(result == .conversation(id: conversation.id, draft: nil))
        let stored = try #require(try receiver.conversation(with: conversation.id))
        #expect(stored.title == "Les volcans")
        #expect(stored.orderedMessages.map(\.text) == ["Comment naît un volcan ?", "Par la remontée du magma [1]."])
        #expect(stored.orderedMessages[1].orderedSources.map(\.title) == ["Source 0"])
    }
}
