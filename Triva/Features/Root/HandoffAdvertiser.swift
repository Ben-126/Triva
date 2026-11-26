//
//  HandoffAdvertiser.swift
//  Triva
//
//  Chantier 2.3 (missions H1 et H2) : Triva annonce au système la question en cours (Handoff), et propose la discussion
//  entière aux flux de continuation (décision de Ben, 2026-11-26). L'annonce vit dans une PETITE vue à part, posée en
//  arrière-plan de la coquille : elle lit le brouillon, qui change à chaque frappe, et la coquille entière n'a pas à être
//  réévaluée pour autant.
//
//  Portée : la fenêtre (scène) qui porte la vue. Plusieurs fenêtres (iPad, Mac) : seule la fenêtre active est proposée
//  aux autres appareils, c'est le comportement documenté de `userActivity(_:isActive:_:)`.
//

import SwiftUI

/// Ce que la fenêtre sait dire de sa question en cours.
struct HandoffAdvertiser: View {
    let session: SearchSession
    /// Cette fenêtre est-elle devant (Mac : fenêtre clé) ? Seule celle-là affiche le message de repli.
    let isForeground: @MainActor () -> Bool

    @AppStorage(SystemIntegrationPreferences.handoffKey) private var isEnabled = SystemIntegrationPreferences.handoffDefault
    @Environment(\.scenePhase) private var scenePhase
    @State private var provider: HandoffStreamProvider

    init(session: SearchSession, isForeground: @escaping @MainActor () -> Bool = { true }) {
        self.session = session
        self.isForeground = isForeground
        let history = session.stores.chatHistory
        // Réglage relu au moment de servir : éteint depuis l'annonce, rien n'est envoyé.
        _provider = State(initialValue: HandoffStreamProvider { advertisedID in
            HandoffSnapshotSource.data(
                for: advertisedID,
                isEnabled: SystemIntegrationPreferences().isHandoffEnabled,
                store: history
            )
        })
    }

    var body: some View {
        let chat = session.chatViewModel
        let payload = HandoffPlan.payload(
            isEnabled: isEnabled,
            draft: session.draft.text,
            lastQuestion: chat?.messages.last(where: { $0.role == .user })?.text,
            conversationID: chat?.currentConversationID
        )
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .advertisesHandoff(payload, provider: provider)
            .onAppear { showPendingNotice() }
            .onChange(of: HandoffNoticeCenter.shared.revision) { showPendingNotice() }
            .onChange(of: scenePhase) { showPendingNotice() }
    }

    /// La discussion n'est pas arrivée : un message clair sous la barre de saisie de la fenêtre active (une seule le prend).
    private func showPendingNotice() {
        guard scenePhase == .active, isForeground(), let message = HandoffNoticeCenter.shared.take() else { return }
        session.ensureChatViewModel()
        session.chatViewModel?.attachmentController.reportInformation(message)
    }
}

extension View {
    /// Annonce l'activité Handoff de la fenêtre. `nil` : rien n'est annoncé (réglage éteint, rien à dire).
    ///
    /// L'en-tête ne porte jamais les réponses. Avec un identifiant de conversation, l'activité propose aussi les flux de
    /// continuation (`provider`), par lesquels l'autre appareil peut demander la discussion entière.
    func advertisesHandoff(_ payload: HandoffPayload?, provider: HandoffStreamProvider) -> some View {
        userActivity(HandoffPayload.activityType, isActive: payload != nil) { activity in
            guard let payload else { return }
            activity.isEligibleForHandoff = true
            // Ni l'index de recherche, ni Siri : la question ne doit apparaître nulle part ailleurs.
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
            #if os(iOS)
            // N'existe pas sur macOS (erreur de compilation constatée par l'essai de la mission S23).
            activity.isEligibleForPrediction = false
            #endif
            // Aucun titre : le texte ne doit pas s'afficher ailleurs que dans l'app qui reprend la main.
            activity.title = nil
            activity.addUserInfoEntries(from: payload.userInfo)
            // SwiftUI réutilise l'activité : une clé d'un état précédent ne doit pas rester.
            if payload.conversationID == nil {
                activity.userInfo?[HandoffPayload.Key.conversationID] = nil
            }
            if payload.draftIsTyped {
                activity.userInfo?[HandoffPayload.Key.draftIsTyped] = nil
            }
            if payload.conversationID == nil {
                provider.uninstall(from: activity)
            } else {
                provider.install(on: activity)
            }
        }
    }

    /// Reçoit l'activité Handoff d'un autre appareil. ENTRÉE EXTERNE : seule une route qui navigue ou remplit la barre de
    /// saisie en sort (`HandoffInbound`) ; rien n'est jamais envoyé.
    ///
    /// - Parameter store: l'historique local, où la discussion reçue est enregistrée (fusion ou nouvelle conversation).
    func continuesHandoff(store: ChatHistoryStore) -> some View {
        onContinueUserActivity(HandoffPayload.activityType) { activity in
            HandoffInbound.shared.receive(activity, store: store)
        }
    }
}
