//
//  HandoffStreamProviderTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : le délégué de l'activité côté envoi. SwiftUI possède l'`NSUserActivity` et peut s'en servir
//  comme délégué : le nôtre s'intercale SANS lui prendre ses rappels (sinon les mises à jour du brouillon de H1 s'arrêteraient).
//

import Foundation
import Testing
@testable import Triva

private final class RecordingDelegate: NSObject, NSUserActivityDelegate {
    var willSaveCount = 0
    var wasContinuedCount = 0
    func userActivityWillSave(_ userActivity: NSUserActivity) { willSaveCount += 1 }
    func userActivityWasContinued(_ userActivity: NSUserActivity) { wasContinuedCount += 1 }
}

@MainActor
@Suite("Handoff conversation : délégué d'envoi", .timeLimit(.minutes(1)))
struct HandoffStreamProviderTests {
    private func activity(conversationID: UUID?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: HandoffPayload.activityType)
        if let payload = HandoffPayload(draft: "Texte", conversationID: conversationID) {
            activity.addUserInfoEntries(from: payload.userInfo)
        }
        return activity
    }

    @Test("Installé sur l'activité, il propose les flux et garde le délégué que SwiftUI y avait mis")
    func installKeepsTheOriginalDelegate() {
        let original = RecordingDelegate()
        let activity = activity(conversationID: HandoffFixtures.conversationID)
        activity.delegate = original
        let provider = HandoffStreamProvider { _ in nil }

        provider.install(on: activity)

        #expect(activity.supportsContinuationStreams)
        #expect(activity.delegate === provider)
        provider.userActivityWillSave(activity)
        provider.userActivityWasContinued(activity)
        #expect(original.willSaveCount == 1)
        #expect(original.wasContinuedCount == 1)
    }

    @Test("Installé plusieurs fois (SwiftUI rappelle la mise à jour à chaque frappe) : il ne s'enveloppe jamais lui-même")
    func installIsIdempotent() {
        let original = RecordingDelegate()
        let activity = activity(conversationID: HandoffFixtures.conversationID)
        activity.delegate = original
        let provider = HandoffStreamProvider { _ in nil }
        provider.install(on: activity)
        provider.install(on: activity)
        provider.install(on: activity)
        provider.userActivityWillSave(activity)
        #expect(original.willSaveCount == 1)
        #expect(activity.delegate === provider)
    }

    @Test("Sans délégué d'origine : rien à relayer, aucun plantage")
    func installWithoutOriginal() {
        let activity = activity(conversationID: nil)
        let provider = HandoffStreamProvider { _ in nil }
        provider.install(on: activity)
        provider.userActivityWillSave(activity)
        provider.userActivityWasContinued(activity)
        #expect(activity.supportsContinuationStreams)
    }

    @Test("Désinstallé (réglage éteint) : les flux ne sont plus proposés et le délégué d'origine revient")
    func uninstallRestores() {
        let original = RecordingDelegate()
        let activity = activity(conversationID: HandoffFixtures.conversationID)
        activity.delegate = original
        let provider = HandoffStreamProvider { _ in nil }
        provider.install(on: activity)
        provider.uninstall(from: activity)
        #expect(!activity.supportsContinuationStreams)
        #expect(activity.delegate === original)
    }

    @Test("Les flux reçus servent la conversation ANNONCÉE par l'activité, pas celle qui s'affiche maintenant")
    func servesTheAdvertisedConversation() async throws {
        let advertised = HandoffFixtures.conversationID
        let served = ServedIDs()
        let data = try #require(HandoffSnapshotCodec.encode(HandoffFixtures.snapshot())).data
        let provider = HandoffStreamProvider { id in served.record(id); return data }
        let activity = activity(conversationID: advertised)

        var aIn: InputStream?, bOut: OutputStream?, bIn: InputStream?, aOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4_096, inputStream: &aIn, outputStream: &bOut)
        Stream.getBoundStreams(withBufferSize: 4_096, inputStream: &bIn, outputStream: &aOut)
        let receiver = HandoffStreamPair(input: bIn!, output: bOut!)

        provider.userActivity(activity, didReceive: aIn!, outputStream: aOut!)
        let snapshot = try await HandoffStreamTransfer.fetchSnapshot(over: receiver, expectedID: advertised, timeout: .seconds(5))

        #expect(snapshot.id == advertised)
        #expect(served.ids == [advertised])
    }

    @Test("Activité sans identifiant de conversation : les flux sont refusés, rien n'est lu dans la base")
    func noAdvertisedConversationRefuses() async throws {
        let served = ServedIDs()
        let provider = HandoffStreamProvider { id in served.record(id); return Data("x".utf8) }
        let activity = activity(conversationID: nil)
        var aIn: InputStream?, bOut: OutputStream?, bIn: InputStream?, aOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4_096, inputStream: &aIn, outputStream: &bOut)
        Stream.getBoundStreams(withBufferSize: 4_096, inputStream: &bIn, outputStream: &aOut)
        let receiver = HandoffStreamPair(input: bIn!, output: bOut!)

        provider.userActivity(activity, didReceive: aIn!, outputStream: aOut!)
        await #expect(throws: HandoffTransferError.closedEarly) {
            try await HandoffStreamTransfer.fetchSnapshot(over: receiver, expectedID: HandoffFixtures.conversationID, timeout: .seconds(5))
        }
        #expect(served.ids.isEmpty)
    }
}

private final class ServedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID?] = []
    func record(_ id: UUID?) { lock.withLock { values.append(id) } }
    var ids: [UUID?] { lock.withLock { values } }
}
