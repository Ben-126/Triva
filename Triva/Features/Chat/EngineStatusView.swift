//
//  EngineStatusView.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

// Sorti de `ContentView.swift` (mission C1) : ce fichier dépassait la limite de 800 lignes, et
// l'en-tête moteur devait grandir (repli quand la hauteur manque, badge unique).

/// Destination "Recherche" de la coquille de navigation : affiche le moteur IA
/// de la session (badge + légende de confidentialité, DESIGN.md) et l'écran de
/// chat réel (`ChatView`, 0.8) pour ce moteur. Gère aussi tout ce qui est
/// spécifique au moteur et qui l'empêcherait de répondre
/// (`SearchSetupRequirement`) : choix/changement de modèle MLX,
/// indisponibilité d'Apple Intelligence, fournisseur cloud pas encore choisi.
/// Au premier lancement, l'utilisateur ne voit donc jamais un écran vide ni un
/// chat voué à l'échec : l'en-tête propose l'action qui débloque, une phrase
/// dit pourquoi.
///
/// Ne détient plus aucun état lourd : tout ce qui doit survivre à un
/// aller-retour vers une autre destination vit dans `SearchSession` (voir son
/// commentaire de tête). Ce qui reste ici en `@State` est strictement local à
/// l'affichage (présentation d'une feuille modale) et peut disparaître avec la
/// vue sans conséquence.
///
/// Plus de paramètre `selectedEngine` séparé : le badge lit `session.engine`,
/// la valeur même que l'envoi utilise. Deux sources auraient pu diverger — c'est
/// exactement la forme du bug 10.
struct EngineStatusView: View {
    let onChangeEngine: () -> Void
    /// « Configurer une clé API » (moteur cloud sans fournisseur choisi) :
    /// la coquille bascule sur les Réglages de la même fenêtre
    /// (`TrivaRootCoordinator.showSettings()`).
    let onOpenSettings: () -> Void

    /// Session injectée par le shell de `TrivaRootView` — surtout PAS de
    /// `@State` ici : cette vue est démontée/remontée à chaque changement de
    /// destination en présentation `NavigationSplitView`.
    let session: SearchSession

    /// `session` n'a volontairement PAS de valeur par défaut : `SearchSession`
    /// est `@MainActor`, et une expression de valeur par défaut est évaluée
    /// dans un contexte synchrone *nonisolated* au point d'appel — écrire
    /// `session: SearchSession = SearchSession()` ne compile donc pas
    /// (`call to main actor-isolated initializer ... in a synchronous
    /// nonisolated context`). Les previews ci-dessous, elles, s'exécutent sur
    /// le main actor et construisent leur session explicitement.
    init(onChangeEngine: @escaping () -> Void, onOpenSettings: @escaping () -> Void, session: SearchSession) {
        self.onChangeEngine = onChangeEngine
        self.onOpenSettings = onOpenSettings
        self.session = session
    }

    @State private var showingMLXSelection = false
    /// Force une relecture du `body` une fois le chat préparé. Constaté sur Mac au lancement : la
    /// création de `chatViewModel` ne relançait pas toujours le `body`, et seul le badge restait,
    /// sans barre de saisie, jusqu'au moindre autre changement d'état.
    @State private var chatPrepared = false

    /// Hauteur réellement disponible pour cet écran, mesurée (elle baisse quand le clavier
    /// s'ouvre). Voir `EngineHeaderLayout`.
    @State private var availableHeight: CGFloat = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// Badge réduit à son icône ? Voir `EngineHeaderLayout.badgeIsIconOnly`.
    private var isBadgeIconOnly: Bool {
        #if os(iOS)
        let isVerticallyCompact = verticalSizeClass == .compact
        #else
        let isVerticallyCompact = false
        #endif
        return EngineHeaderLayout.badgeIsIconOnly(
            isVerticallyCompact: isVerticallyCompact,
            dynamicTypeSize: dynamicTypeSize,
            availableHeight: availableHeight
        )
    }

    /// En-tête replié sur le seul badge ? Voir `EngineHeaderLayout.isCollapsed`.
    private var isHeaderCollapsed: Bool {
        EngineHeaderLayout.isCollapsed(
            availableHeight: availableHeight,
            hasMessages: session.chatViewModel?.messages.isEmpty == false,
            needsSetup: session.setupRequirement != nil,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    /// La rangée moteur (badge icône + « Changer de moteur ») quitte l'en-tête pour la barre de
    /// saisie : repliée, badge réduit à l'icône, et un chat à afficher pour l'accueillir. Une
    /// icône de 50 pt ne libère rien tant que la rangée existe : c'est la rangée entière, avec son
    /// espacement (63 pt), qui rend les 33 pt manquants (mesuré sur iPhone 18 Pro, paysage, AX3).
    private var engineRowIsInComposer: Bool {
        guard let chatViewModel = session.chatViewModel else { return false }
        return isHeaderCollapsed && isBadgeIconOnly
            && Self.showsChat(requirement: session.setupRequirement, hasMessages: !chatViewModel.messages.isEmpty)
    }

    private var composerEngineAccessory: ComposerEngineAccessory? {
        guard engineRowIsInComposer else { return nil }
        return ComposerEngineAccessory(icon: badge.icon, text: badge.text, onChangeEngine: onChangeEngine)
    }

    /// Le moteur affiché ET utilisé (voir `SearchSession.engine`).
    private var engine: AIEngineOption { session.engine }

    /// Badge du modèle que le prochain envoi utilisera (cloud privé d'Apple ou appareil, mission
    /// A4) : même calcul que l'envoi, il suit la connexion et la préférence partagée.
    private var badge: (icon: String, text: String, caption: String) {
        guard engine == .appleIntelligence else { return engine.privacyBadge }
        return engine.privacyBadge(appleRoute: session.appleModel.displayedRoute(isOffline: session.connectivity.isOffline))
    }

    /// Même plafond que `ChatView.contentMaxWidth` (640pt en `regular`,
    /// iPad/Mac) — sans lui, le badge moteur IA et le bouton "Changer de
    /// moteur" restaient collés au bord gauche pendant que `ChatView` juste en
    /// dessous centrait ses messages, sur le même écran.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    var body: some View {
        let _ = chatPrepared
        VStack(alignment: .leading, spacing: 12) {
            if !engineRowIsInComposer {
                header
            }

            if let message = session.setupRequirement?.message {
                // Même colonne que l'en-tête et que `ChatView` (640 pt en
                // `regular`, centrée), texte calé à gauche dans cette colonne.
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("search.setupRequirement")
            }

            if let plan = session.resolveOfflinePlan() {
                OfflineStatusLine(text: plan.statusText)
                    .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
            }

            if let chatViewModel = session.chatViewModel,
               Self.showsChat(requirement: session.setupRequirement, hasMessages: !chatViewModel.messages.isEmpty) {
                ChatView(viewModel: chatViewModel, engineAccessory: composerEngineAccessory)
                    // Brouillon de la session (voir `SearchDraft`) : survit au
                    // démontage de `ChatView` et reçoit le texte de
                    // Découvrir > « Chercher dans Triva ».
                    .environment(session.draft)
            }
        }
        // `minHeight: 0` ET `maxHeight` : avec les deux bornes, le cadre prend TOUJOURS la
        // hauteur offerte. Avec la seule borne haute, il prenait celle du contenu dès que ce
        // contenu débordait (iPhone en paysage à AX3, clavier ouvert) : la hauteur mesurée
        // restait au-dessus du seuil et l'en-tête ne se repliait jamais (constaté, test03).
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .padding(.top, isHeaderCollapsed ? 12 : 24)
        // Mesure qui ne dépend PAS de l'en-tête (le cadre remplit l'espace offert) : replier
        // l'en-tête ne change pas cette hauteur, donc aucune oscillation replié/déplié.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .sheet(isPresented: $showingMLXSelection) {
            MLXModelSelectionView { chosen in
                session.selectMLXModel(chosen)
                showingMLXSelection = false
            }
            #if os(macOS)
            // Une feuille Mac ne se ferme ni d'un geste ni d'un clic à côté : sans ce bouton, seul
            // Échap permettait d'en sortir sans choisir de modèle (constaté, mission Q2).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                mlxSelectionCloseBar
            }
            #endif
        }
        .task {
            session.refreshAppleIntelligenceAvailabilityIfNeeded()
            if engine == .appleIntelligence { session.appleModel.refreshStatus() }
            session.loadMLXCatalogIfNeeded()
            session.ensureChatViewModel()
            chatPrepared = true
        }
    }

    #if os(macOS)
    /// Barre « Fermer » propre à cette feuille Mac : fond opaque et séparateur, car la liste défile
    /// derrière ; Échap ferme aussi. (Les feuilles des Réglages, elles, utilisent un vrai titre de
    /// barre avec un bouton « Annuler » ou « Fermer » en `ToolbarItem(placement: .cancellationAction)`.)
    private var mlxSelectionCloseBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                Button("Fermer") {
                    showingMLXSelection = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.background)
    }
    #endif

    /// Le chat s'affiche quand le moteur est prêt — ou, même s'il ne l'est
    /// pas, dès que le fil contient des messages : une conversation rouverte
    /// depuis la Bibliothèque ou un favori reste lisible (la relire ne dépend
    /// pas du moteur), l'explication au-dessus dit pourquoi un nouvel envoi
    /// échouerait. Moteur pas prêt et fil vide : pas de chat, qui échouerait à
    /// coup sûr au premier envoi ; l'en-tête propose l'action qui débloque.
    /// Règle pure, testée sans interface.
    static func showsChat(requirement: SearchSetupRequirement?, hasMessages: Bool) -> Bool {
        requirement == nil || hasMessages
    }

    /// Badge moteur IA + légende de confidentialité, et pour MLX local le CTA
    /// de choix de modèle (ou le modèle actif + bouton pour en changer) — la
    /// seule partie de cet écran qui ne fait pas partie du chat lui-même.
    /// Tous les éléments de verre de ce bloc (badge, CTA "Choisir un modèle
    /// MLX" ou "Configurer une clé API", carte "Modèle actif", bouton "Changer
    /// de modèle MLX", bouton "Changer de moteur") partagent un seul
    /// `GlassEffectContainer` commun
    /// (DESIGN.md : "toujours envelopper des éléments de verre frères dans un
    /// `GlassEffectContainer`") — jamais de container imbriqué dans un autre.
    ///
    /// Ordre volontaire : le CTA "Choisir un modèle MLX" (`.glassProminent`,
    /// l'action OBLIGATOIRE sans laquelle le chat est inutilisable) est
    /// TOUJOURS rendu avant "Changer de moteur" (`.glass`, une simple
    /// échappatoire secondaire) — DESIGN.md réserve `.glassProminent` à
    /// l'action principale d'un écran, ce que contredirait le fait de la faire
    /// suivre visuellement une action secondaire en scannant l'écran de haut
    /// en bas.
    private var header: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                if isHeaderCollapsed {
                    collapsedRow
                } else {
                    EngineBadge(
                        badge: badge,
                        badgeIdentifier: "search.engineBadge",
                        captionIdentifier: "search.engineCaption"
                    )
                }

                if engine == .mlxLocal, session.validatedMLXModel == nil {
                    Button("Choisir un modèle MLX") {
                        showingMLXSelection = true
                    }
                    .buttonStyle(.glassProminent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("search.chooseMLXModel")
                }

                // Même rôle que « Choisir un modèle MLX » pour le moteur cloud
                // (l'action sans laquelle rien ne peut répondre), donc même
                // place et même style. Mène aux Réglages de cette fenêtre, où
                // vivent « Gérer les clés API » et « Fournisseur et modèle ».
                if session.setupRequirement == .cloudProvider {
                    Button("Configurer une clé API", action: onOpenSettings)
                        .buttonStyle(.glassProminent)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("search.configureAPIKey")
                }

                if !isHeaderCollapsed, engine == .mlxLocal, let validatedMLXModel = session.validatedMLXModel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Modèle actif : \(validatedMLXModel.displayName)")
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        Button("Changer de modèle MLX") {
                            showingMLXSelection = true
                        }
                        .buttonStyle(.glass)
                    }
                }

                if !isHeaderCollapsed {
                    Button("Changer de moteur", action: onChangeEngine)
                        .buttonStyle(.glass)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("search.changeEngine")
                }
            }
        }
        // Calé à gauche dans la colonne, comme `TrivaHomeReferenceView` et le chat juste en dessous.
        // Sans `alignment`, le bloc épousait son contenu et se centrait : le badge flottait à 76 pt du
        // bord sur iPhone au lieu de 20, et sautait de place dès qu'une carte « Modèle actif » remplissait
        // la colonne (constaté sur les captures iPhone, iPad et Mac, mission Q2).
        .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    /// En-tête replié : le badge seul (toujours visible, DESIGN.md), et « Changer de moteur »
    /// réduit à son icône sur la même ligne. Même identifiant que le bouton déplié : l'action
    /// reste trouvable, elle ne prend juste plus une ligne à elle pendant toute la conversation.
    private var collapsedRow: some View {
        HStack(alignment: .center, spacing: 12) {
            EngineBadge(badge: badge, showsCaption: false, badgeIdentifier: "search.engineBadge", iconOnly: isBadgeIconOnly)
            Spacer(minLength: 0)
            Button("Changer de moteur", systemImage: "arrow.triangle.2.circlepath", action: onChangeEngine)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .accessibilityIdentifier("search.changeEngine")
                #if os(macOS)
                .help("Changer de moteur")
                #endif
        }
    }
}

/// Quand replier l'en-tête moteur de la Recherche sur le seul badge (QA Q3, findings 4 et 5).
///
/// À AX3, l'en-tête fixe (badge, légende, « Changer de moteur » sur deux lignes) prenait un
/// tiers de l'écran : le fil ne montrait que la question et une ligne de réponse. Sur un
/// iPhone Duo plié, clavier ouvert, une seule rangée du fil restait visible, même à taille de
/// texte normale.
///
/// Règle fondée sur la hauteur MESURÉE, jamais sur le modèle d'appareil (consigne de la
/// mission) : elle baisse quand le clavier s'ouvre, en Split View, dans une petite fenêtre Mac.
/// Volontairement, aucune entrée ne dépend de la hauteur de l'en-tête lui-même : le replier la
/// changerait, et la règle oscillerait entre replié et déplié.
nonisolated enum EngineHeaderLayout {

    /// En dessous, une conversation en cours replie l'en-tête. 560 pt : un iPhone 18 Pro
    /// clavier fermé offre environ 700 pt à cet écran (en-tête déplié gardé, il y a la place),
    /// clavier ouvert environ 400 pt (replié : le fil passe avant une action rare).
    static let conversationMinimumHeight: CGFloat = 560

    /// En dessous, même un écran vide replie l'en-tête : il ne resterait sinon presque rien
    /// pour la barre de saisie et les exemples (Duo plié, clavier ouvert).
    static let emptyScreenMinimumHeight: CGFloat = 360

    /// En dessous, la hauteur n'est pas une vraie mesure : c'est un état transitoire de la
    /// première mise en page (constaté à la console, iPhone 18 Pro : 24 pt puis 12 pt, avant les
    /// 623 pt réels). La traiter comme réelle repliait l'en-tête une image, puis le redéployait
    /// aussitôt, et SwiftUI signalait « glassEffect() tried to update multiple times per frame »
    /// (QA Q2 point 12). Seuil volontairement bas (40 pt) : il ne doit écarter que ces
    /// valeurs de départ, jamais une vraie hauteur réduite (clavier ouvert en paysage).
    static let minimumMeasuredHeight: CGFloat = 40

    /// iPhone en paysage, texte AX3 ou plus : en dessous de cette hauteur offerte, le clavier est
    /// ouvert. Mesuré sur iPhone 18 Pro (402 pt de haut) : 260 pt clavier fermé, 100 pt clavier
    /// ouvert (le clavier en paysage prend 177 pt). 180 pt tombe entre les deux, avec de la marge
    /// des deux côtés pour un écran un peu plus ou moins haut.
    static let keyboardOpenMaximumHeight: CGFloat = 180

    /// Badge réduit à son icône (décision de Ben, mission E2c) : SEULEMENT en hauteur compacte
    /// (iPhone en paysage), à AX3 ou plus, clavier ouvert. À ce réglage la barre de saisie
    /// débordait d'environ 33 pt et le bouton d'envoi passait sous le clavier. Partout ailleurs
    /// (AX1, AX2, portrait, Mac, iPad, clavier fermé) le badge garde son texte.
    /// Clavier ouvert déduit de la hauteur MESURÉE, comme le repli de l'en-tête (jamais du modèle
    /// d'appareil) ; en dessous de `minimumMeasuredHeight`, ce n'est pas encore une mesure.
    static func badgeIsIconOnly(
        isVerticallyCompact: Bool,
        dynamicTypeSize: DynamicTypeSize,
        availableHeight: CGFloat
    ) -> Bool {
        isVerticallyCompact
            && dynamicTypeSize >= .accessibility3
            && availableHeight >= minimumMeasuredHeight
            && availableHeight < keyboardOpenMaximumHeight
    }

    /// - Parameters:
    ///   - availableHeight: hauteur offerte à l'écran de Recherche ; `0` tant qu'elle n'est pas
    ///     mesurée (premier rendu), et moins de `minimumMeasuredHeight` tant que la mise en page
    ///     n'est pas posée : l'en-tête reste alors déplié.
    ///   - hasMessages: une conversation est affichée.
    ///   - needsSetup: le moteur attend une action (choisir un modèle MLX, configurer une clé) :
    ///     jamais replié, c'est l'action sans laquelle rien ne répond.
    ///   - isAccessibilitySize: taille de texte AX1 à AX5 : une conversation replie toujours.
    static func isCollapsed(
        availableHeight: CGFloat,
        hasMessages: Bool,
        needsSetup: Bool,
        isAccessibilitySize: Bool
    ) -> Bool {
        guard !needsSetup, availableHeight >= minimumMeasuredHeight else { return false }
        if hasMessages {
            return isAccessibilitySize || availableHeight < conversationMinimumHeight
        }
        return availableHeight < emptyScreenMinimumHeight
    }
}

#Preview("Recherche — Apple Intelligence") {
    EngineStatusView(
        onChangeEngine: {},
        onOpenSettings: {},
        session: SearchSession(engine: .appleIntelligence, stores: .preview(engine: .appleIntelligence))
    )
}

#Preview("Recherche — MLX local") {
    EngineStatusView(
        onChangeEngine: {},
        onOpenSettings: {},
        session: SearchSession(engine: .mlxLocal, stores: .preview(engine: .mlxLocal))
    )
}

#Preview("Recherche — Cloud BYOK") {
    EngineStatusView(
        onChangeEngine: {},
        onOpenSettings: {},
        session: SearchSession(engine: .cloudBYOK, stores: .preview(engine: .cloudBYOK))
    )
}
