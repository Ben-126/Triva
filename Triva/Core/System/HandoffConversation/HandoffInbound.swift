//
//  HandoffInbound.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : le point d'entrée d'une activité Handoff reçue (appelé par `continuesHandoff`).
//  Entrée EXTERNE. Il lit l'en-tête (version, texte, identifiant), demande la discussion par les flux quand elle est
//  annoncée, puis pose le résultat : Mac = fenêtre au premier plan si elle est vide, sinon nouvelle fenêtre ; iPhone et
//  iPad = la file des routes du système. Rien n'est jamais envoyé.
//

import Foundation

@MainActor
final class HandoffInbound {
    static let shared = HandoffInbound()

    /// Attente avant d'afficher le message de repli : le temps que la route (texte, fenêtre neuve) soit posée.
    static let noticeDelay: Duration = .milliseconds(300)

    private var duplicateGuard = HandoffDuplicateGuard(window: 3)
    private var currentTask: Task<Void, Never>?

    init() {}

    func receive(_ activity: NSUserActivity, store: ChatHistoryStore) {
        guard let payload = HandoffRoute.payload(forActivityType: activity.activityType, userInfo: activity.userInfo) else { return }
        guard duplicateGuard.shouldHandle(key: "\(payload.conversationID?.uuidString ?? "-")|\(payload.draft)", now: Date()) else { return }
        // Les flux se demandent ICI, de façon synchrone, avant tout `await` (voir `HandoffActivityStreams`).
        let fetcher = payload.conversationID == nil
            ? nil
            : HandoffStreamFetcher(source: HandoffActivityStreams(activity: activity))
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            let result = await HandoffReceiver.receive(
                payload: payload,
                fetcher: fetcher,
                importer: store,
                isHeldByAWindow: { WindowConversationRegistry.shared.isHeld($0, excluding: UUID()) }
            )
            await self?.place(result)
        }
    }

    private func place(_ result: HandoffReceiveResult) async {
        let routes = HandoffReceiver.routes(for: result)
        guard !routes.isEmpty else { return }
        #if os(macOS)
        if !HandoffWindowPlacement.shared.placeInForegroundEmptyWindow(routes) {
            HandoffReceiver.routesForNewWindow(routes).forEach { SystemRouteCenter.shared.submit($0) }
        }
        #else
        routes.forEach { SystemRouteCenter.shared.submit($0) }
        #endif
        if case .fellBack = result {
            try? await Task.sleep(for: Self.noticeDelay)
            HandoffNoticeCenter.shared.post(HandoffReceiver.fallbackNotice)
        }
    }
}
