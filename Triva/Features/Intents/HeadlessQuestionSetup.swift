//
//  HeadlessQuestionSetup.swift
//  Triva
//
//  Chantier 2.1 (mission B) : prépare une question posée sans fenêtre. Lit l'état des stores de l'app, bâtit une
//  session SANS fenêtre (sa propre `SearchSession` et son propre fil de messages), et dit ce que la politique en
//  conclut. Un lanceur n'existe QUE si la politique autorise l'envoi.
//

import Foundation

@MainActor
struct HeadlessQuestionSetup {
    let decision: HeadlessDecision
    /// La session sans fenêtre : seulement quand `decision` est `.run`.
    let session: SearchSession?
    /// Seulement quand `decision` est `.run` : sinon rien ne doit pouvoir partir.
    let runner: HeadlessQuestionRunner?

    static func prepare(
        stores: TrivaSharedStores,
        responseMode: ResponseMode?,
        noticeAcknowledged: Bool = AIUseNoticeStore.isAcknowledged(),
        platform: HeadlessPlatform = .current
    ) -> HeadlessQuestionSetup {
        guard noticeAcknowledged else {
            // Avant l'information sur l'IA, aucune session n'est même construite.
            let context = HeadlessQuestionContext(
                noticeAcknowledged: false, engine: nil, isEngineReady: false, cloudConsent: .notApplicable, platform: platform
            )
            return HeadlessQuestionSetup(decision: HeadlessQuestionPolicy.decide(context), session: nil, runner: nil)
        }
        guard let engine = stores.engineSettings.selectedOption else {
            let context = HeadlessQuestionContext(
                noticeAcknowledged: true, engine: nil, isEngineReady: false, cloudConsent: .notApplicable, platform: platform
            )
            return HeadlessQuestionSetup(decision: HeadlessQuestionPolicy.decide(context), session: nil, runner: nil)
        }
        let session = SearchSession(engine: engine, stores: stores)
        session.responseModeOverride = responseMode
        session.generatesSuggestions = false
        session.loadMLXCatalogIfNeeded()
        let decision = HeadlessQuestionPolicy.decide(context(for: session, stores: stores, platform: platform))
        guard case .run = decision else {
            // Rien ne part : la session (et son enregistrement auprès du pool MLX) est relâchée tout de suite.
            return HeadlessQuestionSetup(decision: decision, session: nil, runner: nil)
        }
        // Le système affiche déjà la progression de l'action : jamais d'activité en direct en doublon.
        session.progressObserver = nil
        session.ensureChatViewModel()
        guard let chatViewModel = session.chatViewModel else {
            return HeadlessQuestionSetup(decision: .needsEngineChoice, session: nil, runner: nil)
        }
        let runner = HeadlessQuestionRunner(chatViewModel: chatViewModel, retaining: session)
        return HeadlessQuestionSetup(decision: decision, session: session, runner: runner)
    }

    private static func context(
        for session: SearchSession,
        stores: TrivaSharedStores,
        platform: HeadlessPlatform
    ) -> HeadlessQuestionContext {
        switch session.engine {
        case .appleIntelligence:
            return HeadlessQuestionContext(noticeAcknowledged: true, engine: .appleIntelligence, isEngineReady: true, cloudConsent: .notApplicable, platform: platform)
        case .mlxLocal:
            return HeadlessQuestionContext(
                noticeAcknowledged: true,
                engine: .mlxLocal,
                isEngineReady: session.validatedMLXModel != nil,
                cloudConsent: .notApplicable,
                platform: platform
            )
        case .cloudBYOK:
            // Pas de demande de consentement = accord déjà donné pour le fournisseur choisi.
            let consent: HeadlessCloudConsent = session.cloudConsentRequestForSending().map {
                .missing(providerName: $0.titleName)
            } ?? .granted
            return HeadlessQuestionContext(
                noticeAcknowledged: true,
                engine: .cloudBYOK,
                isEngineReady: stores.cloudSelection.selection != nil,
                cloudConsent: consent,
                platform: platform
            )
        }
    }
}

extension TrivaAppServices {
    /// Fabrique de la session sans fenêtre des intents (spec 2.1, §2).
    func prepareHeadlessQuestion(
        responseMode: ResponseMode?,
        noticeAcknowledged: Bool = AIUseNoticeStore.isAcknowledged()
    ) -> HeadlessQuestionSetup {
        HeadlessQuestionSetup.prepare(stores: stores, responseMode: responseMode, noticeAcknowledged: noticeAcknowledged)
    }
}
