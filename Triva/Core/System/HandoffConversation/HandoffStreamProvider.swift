//
//  HandoffStreamProvider.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : le côté ENVOI. Quand l'autre appareil demande les flux de continuation de l'activité, le
//  système appelle le délégué de l'activité (`userActivity(_:didReceive:outputStream:)`) ; ce délégué sert la discussion.
//
//  SwiftUI possède l'`NSUserActivity` annoncée par `.userActivity(...)` et peut l'avoir prise comme délégué (pour rappeler
//  la mise à jour du contenu, `userActivityWillSave`). Le nôtre s'intercale donc comme RELAIS : il garde le délégué
//  d'origine (référence faible) et lui renvoie les rappels qu'il ne traite pas, sinon les mises à jour du brouillon de
//  H1 s'arrêteraient. NON VÉRIFIÉ sur appareil réel : si SwiftUI réinstalle son délégué, les flux ne sont jamais proposés
//  et le receveur se replie sur le texte (H1) au bout du délai.
//

import Foundation
#if os(iOS)
import UIKit
#endif

nonisolated final class HandoffStreamProvider: NSObject, NSUserActivityDelegate, @unchecked Sendable {
    /// Donne la discussion codée pour l'identifiant ANNONCÉ par l'activité ; `nil` : rien n'est servi.
    typealias SnapshotData = @MainActor @Sendable (UUID?) -> Data?

    private let snapshotData: SnapshotData
    private let lock = NSLock()
    private weak var original: (any NSUserActivityDelegate)?

    init(snapshotData: @escaping SnapshotData) {
        self.snapshotData = snapshotData
        super.init()
    }

    // MARK: Installation

    /// Propose les flux de continuation sur cette activité, en gardant le délégué qui y était. Sans effet répété.
    func install(on activity: NSUserActivity) {
        lock.withLock {
            if let current = activity.delegate, current !== self { original = current }
        }
        activity.supportsContinuationStreams = true
        activity.delegate = self
    }

    /// Ne propose plus les flux et rend le délégué d'origine.
    func uninstall(from activity: NSUserActivity) {
        activity.supportsContinuationStreams = false
        let restored = lock.withLock { original }
        if activity.delegate === self { activity.delegate = restored }
    }

    // MARK: NSUserActivityDelegate

    func userActivityWillSave(_ userActivity: NSUserActivity) {
        lock.withLock { original }?.userActivityWillSave?(userActivity)
    }

    func userActivityWasContinued(_ userActivity: NSUserActivity) {
        lock.withLock { original }?.userActivityWasContinued?(userActivity)
    }

    func userActivity(_ userActivity: NSUserActivity, didReceive inputStream: InputStream, outputStream: OutputStream) {
        let pair = HandoffStreamPair(input: inputStream, output: outputStream)
        // L'identifiant lu est celui que CETTE activité a annoncé, pas celui de la fenêtre aujourd'hui.
        let advertised = (userActivity.userInfo?[HandoffPayload.Key.conversationID] as? String).flatMap { UUID(uuidString: $0) }
        guard let advertised else {
            Self.refuse(pair)
            return
        }
        let provider = snapshotData
        Task.detached {
            let assertion = await HandoffBackgroundAssertion.begin()
            defer { Task { await assertion.end() } }
            do {
                try await HandoffStreamTransfer.serve(over: pair) { provider(advertised) }
            } catch {
                Self.refuse(pair)
            }
        }
    }

    /// Ouvre puis ferme : l'autre côté voit une fin de flux franche, pas un silence jusqu'au délai.
    private static func refuse(_ pair: HandoffStreamPair) {
        pair.input.open()
        pair.output.open()
        pair.input.close()
        pair.output.close()
    }
}

/// Sur iPhone et iPad, l'app d'origine peut passer en arrière-plan pendant qu'elle écrit : une tâche de fond lui laisse le
/// temps de finir.
nonisolated struct HandoffBackgroundAssertion: Sendable {
    #if os(iOS)
    private let identifier: UIBackgroundTaskIdentifier

    @MainActor
    static func begin() -> HandoffBackgroundAssertion {
        HandoffBackgroundAssertion(identifier: UIApplication.shared.beginBackgroundTask(withName: "Handoff"))
    }

    @MainActor
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
    #else
    @MainActor
    static func begin() -> HandoffBackgroundAssertion { HandoffBackgroundAssertion() }

    @MainActor
    func end() {}
    #endif
}
