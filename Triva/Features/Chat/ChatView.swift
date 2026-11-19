import SwiftUI

// MARK: - Vue

/// Écran de chat complet : le fil (une `MessageBubbleView` par message, avec
/// autour les widgets, les médias à la demande et la relance en mode Rapide),
/// les suggestions de la dernière réponse, la barre de saisie (fichiers
/// joints, mode de réponse, champ, envoi/arrêt) et le bouton « Nouvelle
/// conversation » de la barre d'outils.
///
/// Erreurs : `ChatViewModel.errorDescription` est la SEULE source du bandeau
/// d'erreur d'échange (jamais recopié dans une bulle, pour ne pas le
/// dupliquer) ; `persistenceErrorDescription` (historique, favoris) a sa
/// propre ligne et ne l'écrase jamais. Sous le bandeau, quand toutes les
/// sources de recherche ont échoué : `SearchKeyInvitationView`.
///
/// Ne crée jamais son `ChatViewModel` lui-même : reçu en paramètre, pour que
/// l'appelant (`ContentView.swift`) reste seul responsable de résoudre le
/// provider IA et le `FailoverManager` actifs et de mettre ce ViewModel en
/// cache — un par écran, jamais recréé à chaque re-render.
///
/// Quand une réponse n'a ni widget, ni média, ni raisonnement, l'écran est
/// exactement celui d'avant : la question, la bulle de réponse, ses sources.
struct ChatView: View {
    let viewModel: ChatViewModel
    private let injectedResponseModeStore: ResponseModeSettingsStore?
    /// Moteur IA posé dans la barre de saisie (iPhone en paysage, AX3, clavier ouvert) : voir
    /// `ComposerEngineAccessory`. `nil` partout ailleurs.
    private let engineAccessory: ComposerEngineAccessory?

    /// - Parameter responseModeStore: le store PARTAGÉ du mode de réponse
    ///   (1.13), le même que celui des Réglages. `nil` : l'instance unique du
    ///   processus (`sharedResponseModeStore`). Pas de valeur par défaut
    ///   `= ChatView.sharedResponseModeStore` : une expression par défaut est
    ///   évaluée hors du main actor (même piège que `EngineStatusView.init`).
    init(
        viewModel: ChatViewModel,
        responseModeStore: ResponseModeSettingsStore? = nil,
        engineAccessory: ComposerEngineAccessory? = nil
    ) {
        self.viewModel = viewModel
        self.injectedResponseModeStore = responseModeStore
        self.engineAccessory = engineAccessory
    }

    /// Brouillon de la session (`SearchDraft`, `ContentView.swift`) : il
    /// survit au démontage de cette vue (changement de destination en
    /// sidebar, bascule de classe de taille) et reçoit le texte de Découvrir >
    /// « Chercher dans Triva ». Lecture OPTIONNELLE, contrat d'I4b : les
    /// aperçus n'en injectent pas, une lecture non optionnelle les ferait
    /// planter — repli sur `localDraft`.
    @Environment(SearchDraft.self) private var sessionDraft: SearchDraft?
    @State private var localDraft = ""
    // La `Task` de la génération n'est PAS ici : `ChatViewModel.startSend` la garde (voir « La
    // génération appartient au modèle »). Cette vue est démontée à chaque bascule de classe de taille
    // et à chaque changement de destination ; une génération liée à elle s'arrêtait à chaque fois.
    /// Position de lecture de la session (`TranscriptScrollState`, mission I1) : dernière conversation dont
    /// le début de réponse a été montré, le fil suit-il le bas (`ChatScrollFollowing`), message en haut de
    /// la zone visible. Elle survit au démontage de cette vue (iPhone Duo plié / déplié). Lecture OPTIONNELLE
    /// comme `SearchDraft` : les aperçus n'en injectent pas, repli sur `localScroll`.
    @Environment(TranscriptScrollState.self) private var sessionScroll: TranscriptScrollState?
    @State private var localScroll = TranscriptScrollState()
    private var scroll: TranscriptScrollState { sessionScroll ?? localScroll }
    /// Dernière phase de défilement connue, lue par l'observateur de
    /// géométrie (aucun défilement programmatique pendant un geste).
    @State private var scrollPhase: ScrollPhase = .idle
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Charnière (iPhone Duo) : « Fermer le clavier » n'existe que là (`ComposerKeyboardLayout`).
    @Environment(\.trivaHasHinge) private var hasHinge
    /// Voir `EnvironmentValues.openSearchKeySettings`.
    @Environment(\.openSearchKeySettings) private var openSearchKeySettings
    @FocusState private var isDraftFocused: Bool
    /// Hauteur offerte à ce chat (baisse quand le clavier s'ouvre) : voir `ComposerKeyboardLayout`.
    @State private var availableHeight: CGFloat = 0
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    // Le consentement cloud en attente (mission C2) vit dans `ChatViewModel.pendingConsent` depuis la
    // mission I1 : une feuille et un envoi tenus par la vue étaient perdus au pliage de l'iPhone Duo.

    /// Repli tant que `TrivaSharedStores` ne porte pas le store du mode :
    /// UNE instance par processus, partagée par toutes les fenêtres (iPad,
    /// Mac). Une instance par vue afficherait un mode périmé dans une fenêtre
    /// après un changement dans une autre — alors que l'envoi relit
    /// `UserDefaults` : l'interface dirait « Rapide » pendant que la
    /// recherche part en « Fiable ».
    private static let sharedResponseModeStore = ResponseModeSettingsStore()

    private var responseModeStore: ResponseModeSettingsStore {
        injectedResponseModeStore ?? Self.sharedResponseModeStore
    }

    /// Largeur de contenu plafonnée en `regular` (iPad/Mac) — même principe
    /// que `TrivaHomeReferenceView` (padding horizontal de 20 partout), pour
    /// éviter des bulles de chat qui s'étirent sur toute la largeur d'un
    /// écran Mac.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    /// Texte de la barre de saisie : celui de la session quand elle en
    /// fournit un.
    private var draftText: String {
        sessionDraft?.text ?? localDraft
    }

    private var draftBinding: Binding<String> {
        guard let sessionDraft else { return $localDraft }
        @Bindable var bindableDraft = sessionDraft
        return $bindableDraft.text
    }

    private var isSendDisabled: Bool {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isGenerating
    }

    /// Suggestions de la DERNIÈRE réponse, une fois sa génération terminée
    /// (même règle que la version web d'origine) ; `nil` pendant une génération.
    private var lastAnswerSuggestions: [String]? {
        guard !viewModel.isGenerating,
              let last = viewModel.messages.last,
              last.role == .assistant,
              !last.suggestions.isEmpty else { return nil }
        return last.suggestions
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            composer
        }
        .environment(\.readPageAction, ReadPageAction(isEnabled: viewModel.canReadPage) { url in
            await readPageAndRegenerate(url: url)
        })
        // Coup d'œil sur les sources tirées d'une pièce jointe (chantier 2.2, M5).
        .environment(\.attachmentFileLookup, AttachmentFileLookup { [attachments = viewModel.attachmentController] in
            attachments.previewURL(for: $0)
        })
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .sheet(item: pendingConsentBinding) { pending in
            CloudConsentSheet(
                request: pending.request,
                onAllow: {
                    // L'accord repart avec l'envoi interrompu (porté par le modèle) ; seul le brouillon,
                    // qui appartient à la session, est vidé ici.
                    if case .send? = viewModel.allowPendingConsent() { clearDraft() }
                },
                onCancel: { viewModel.declinePendingConsent() }
            )
        }
        .onChange(of: viewModel.userNewConversationCount) { userStartedNewConversation() }
        .toolbar {
            // Décision 1 de Ben : les questions s'enchaînent dans la même
            // conversation jusqu'à ce bouton ; l'ancienne reste dans la
            // Bibliothèque. Raccourci ⇧⌘O (menu Fichier) plutôt que ⌘N,
            // qui ouvre une nouvelle fenêtre sur Mac et iPad.
            ToolbarItem(placement: .primaryAction) {
                Button("Nouvelle conversation", systemImage: "square.and.pencil") {
                    viewModel.startNewConversationFromUser()
                }
                .disabled(viewModel.messages.isEmpty)
                // ⇧⌘O est déclaré UNE seule fois, dans le menu Fichier (`TrivaCommands`) : deux
                // déclarations du même raccourci se disputaient la touche.
                .accessibilityIdentifier("chat.newConversation")
                #if os(macOS)
                .help("Nouvelle conversation")
                #endif
            }
        }
    }

    /// Ancre fixe placée après le dernier message ET le bandeau d'erreur (s'il
    /// y en a un) : le scroll automatique cible TOUJOURS cette ancre plutôt
    /// que l'id du dernier message, pour que le bandeau d'erreur — quand il
    /// apparaît juste après un échec, donc juste après le dernier message
    /// assistant — soit systématiquement révélé par le scroll au lieu de
    /// rester au-dessus de la zone visible (le bandeau était auparavant en
    /// TÊTE de liste, hors du chemin du scroll qui, lui, ancre en bas).
    private static let bottomAnchorID = "chat-bottom-anchor"

    /// Nom du repère du contenu défilant, voir `TranscriptScrollState.rowTops`.
    private static let contentSpace = "chat-transcript-content"

    /// Hauteur de l'ancre de bas de liste — porte elle-même la marge visuelle
    /// sous la dernière bulle (bug corrigé le 2026-09-15 : cette marge vivait
    /// avant dans un `.padding(.bottom, 20)` placé APRÈS l'ancre dans le
    /// VStack. Or `scrollTo(bottomAnchorID, anchor: .bottom)` aligne le BAS de
    /// l'ancre sur le bas du viewport — tout ce qui suit spatialement l'ancre
    /// se retrouve donc scrollé sous le viewport, invisible. Résultat : la
    /// marge existait dans le layout mais jamais à l'écran, et la dernière
    /// bulle apparaissait collée à la barre de saisie sans marge ni indice de
    /// scroll. En donnant cette hauteur à l'ancre elle-même (qui précède
    /// désormais le point d'ancrage), la marge reste au-dessus du bas du
    /// viewport et donc visible.)
    private static let bottomAnchorHeight: CGFloat = 20

    /// Hauteur FIXE du fondu en haut de la liste (DESIGN.md, exception
    /// "fondu de bord de scroll" du 2026-09-15) — pas relative à la hauteur
    /// totale de la liste, pour un rendu cohérent quelle que soit la taille
    /// de fenêtre. Valeur de la grille d'espacement (24pt).
    private static let topFadeHeight: CGFloat = 24

    private var messagesList: some View {
        GeometryReader { containerGeometry in
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.messages.isEmpty, !viewModel.isGenerating {
                        ChatEmptyStateView(onSelect: { example in sendSuggestion(example) })
                    }

                    // UN seul conteneur pour tout le verre du fil : bulles,
                    // widgets, boutons des médias et de relance (DESIGN.md).
                    // Les suggestions ouvrent le leur, donc restent dehors.
                    GlassEffectContainer(spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.messages) { message in
                                ChatTranscriptRow(
                                    message: message,
                                    viewModel: viewModel,
                                    onRetry: { messageID in retryInQuickMode(messageID: messageID) },
                                    onTopChange: { [scroll] top in scroll.rowTops[message.id] = top },
                                    topCoordinateSpace: Self.contentSpace
                                )
                            }
                        }
                    }

                    if let suggestions = lastAnswerSuggestions {
                        SuggestionsView(suggestions: suggestions, onSelect: { suggestion in sendSuggestion(suggestion) })
                    }

                    if let persistenceError = viewModel.persistenceErrorDescription {
                        Label(persistenceError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("chat.persistenceError")
                    }

                    if let errorDescription = viewModel.errorDescription {
                        Label("Erreur : \(errorDescription)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("chat.error")
                    }

                    if let notice = viewModel.offlineNotice {
                        OfflineNoticeView(
                            reason: notice.reason,
                            canRelaunch: viewModel.canRelaunchAfterReconnect,
                            canAnswerWithoutSource: viewModel.canAnswerWithoutSourceOffline,
                            onRelaunch: { relaunchAfterOffline(quickMode: $0) }
                        )
                    }

                    if let invitation = viewModel.searchKeyInvitation, let openSearchKeySettings {
                        SearchKeyInvitationView(invitation: invitation, onOpen: { openSearchKeySettings() })
                    }

                    Color.clear
                        .frame(height: Self.bottomAnchorHeight)
                        .id(Self.bottomAnchorID)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                // Repère du contenu défilant (après la marge haute, donc origine = décalage 0 du défilement) :
                // les hauts des messages y sont indépendants du défilement (`TranscriptScrollState`).
                .coordinateSpace(.named(Self.contentSpace))
            }
            // Une conversation rouverte (Bibliothèque, favori) s'ouvre au DÉBUT de sa dernière
            // réponse (`showLastAnswerStart`, mission C1) : sur sa fin, on tombait sur les
            // sources et pas sur la réponse (QA Q1, pt 14). L'ancrage par défaut en bas reste
            // pour le premier rendu, avant que la réponse ne soit posée.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Seulement quand la conversation affichée a changé depuis le dernier positionnement : `onAppear`
            // se rejoue à chaque retour sur l'onglet, et ramenait au début de la réponse un lecteur
            // descendu jusqu'aux sources (revue R3-5).
            .onAppear {
                switch TranscriptScrollState.appearanceAction(
                    currentConversationID: viewModel.currentConversationID,
                    lastPositionedConversationID: scroll.lastPositionedConversationID,
                    isPinnedToBottom: scroll.isPinnedToBottom,
                    anchorMessageID: scroll.anchorMessageID
                ) {
                case .showLastAnswerStart:
                    showLastAnswerStart(proxy: proxy)
                case .stayAtBottom:
                    break
                case .restore(let messageID):
                    restorePosition(of: messageID, proxy: proxy)
                }
            }
            // Sur iPhone, le clavier cache la barre d'onglets, et Retour ENVOIE dès qu'un brouillon
            // existe : sans ces gestes, impossible de quitter l'écran sans envoyer ni tout effacer,
            // ou de lire la réponse (constaté à l'écran, QA Q1). Un fil vide ne défile pas, d'où le
            // toucher, avec `.contentShape` pour sa zone vide. `.immediately` : `.interactively` exige
            // de glisser jusqu'au clavier. iOS seulement : sur Mac, sélectionner du texte dans le fil
            // ne doit pas retirer le focus du champ.
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded { isDraftFocused = false })
            #endif
            .mask(topFadeMask(containerHeight: containerGeometry.size.height))
            .onScrollPhaseChange { oldPhase, newPhase, context in
                scrollPhase = newPhase
                let distance = ChatScrollFollowing.Metrics(context.geometry).distanceFromBottom
                let pinned = ChatScrollFollowing.isPinnedAfterPhaseChange(
                    from: oldPhase,
                    to: newPhase,
                    distanceFromBottom: distance,
                    wasPinned: scroll.isPinnedToBottom
                )
                setPinned(pinned)
                if ChatScrollFollowing.needsCatchUp(from: oldPhase, to: newPhase, isPinned: pinned, distanceFromBottom: distance) {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            // LE déclencheur du suivi (le `.onChange(of: messages.last?.text)`
            // d'avant faisait doublon). `onScrollGeometryChange` passe APRÈS
            // que SwiftUI a posé la géométrie réelle (`contentSize` inclut déjà
            // la bulle à sa hauteur finale) : c'est ce qui avait corrigé, le
            // 2026-09-15, la réponse restée tronquée au milieu d'une phrase —
            // un changement de texte précède la mise en page, une hauteur qui
            // augmente la suit. Sans animation : il se déclenche à chaque
            // palier de texte, des transactions animées en rafale saccadaient.
            .onScrollGeometryChange(for: ChatScrollFollowing.Metrics.self) { geometry in
                ChatScrollFollowing.Metrics(geometry)
            } action: { oldMetrics, newMetrics in
                let pinned = ChatScrollFollowing.isPinnedAfterGeometryChange(
                    from: oldMetrics,
                    to: newMetrics,
                    phase: scrollPhase,
                    wasPinned: scroll.isPinnedToBottom
                )
                setPinned(pinned)
                // La position ne sert qu'à un lecteur qui a remonté : collé en bas, il y retourne de lui-même.
                if !scroll.isPinnedToBottom {
                    scroll.recordPosition(orderedIDs: viewModel.messages.map(\.id), offsetY: newMetrics.offsetY)
                }
                if ChatScrollFollowing.shouldFollowContent(from: oldMetrics, to: newMetrics, phase: scrollPhase, isPinned: pinned) {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onChange(of: viewModel.messages.count) {
                // Un nouvel échange (nouvelle question envoyée) reprend toujours le suivi, même
                // si l'utilisateur avait remonté pour relire. Une conversation rouverte (aucune
                // génération en cours) s'ouvre au début de sa dernière réponse.
                if viewModel.isGenerating || viewModel.messages.isEmpty {
                    scroll.lastPositionedConversationID = viewModel.currentConversationID
                    setPinned(true)
                    scrollToBottom(proxy: proxy)
                } else {
                    showLastAnswerStart(proxy: proxy)
                }
            }
            .onChange(of: viewModel.errorDescription) { _, newValue in
                scrollToBottom(proxy: proxy)
                if let newValue {
                    announce("Erreur : \(newValue)")
                }
            }
            .onChange(of: viewModel.persistenceErrorDescription) { _, newValue in
                if let newValue {
                    announce(newValue)
                }
            }
        }
        }
    }

    /// Masque de fondu en haut de la liste (DESIGN.md, exception "fondu de
    /// bord de scroll") : les premiers `topFadeHeight` points du viewport
    /// passent de transparent à opaque, le reste (tout le bas, où vit la
    /// quasi-totalité du contenu) reste pleinement opaque. Hauteur FIXE
    /// (fraction recalculée depuis `containerHeight`, pas un pourcentage fixe
    /// du viewport) pour un fondu de taille constante quelle que soit la
    /// taille de fenêtre.
    private func topFadeMask(containerHeight: CGFloat) -> some View {
        let fadeFraction = containerHeight > 0
            ? min(Self.topFadeHeight / containerHeight, 0.5)
            : 0
        return LinearGradient(
            stops: [
                Gradient.Stop(color: .clear, location: 0),
                Gradient.Stop(color: .black, location: fadeFraction),
                Gradient.Stop(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func setPinned(_ pinned: Bool) {
        if scroll.isPinnedToBottom != pinned {
            scroll.isPinnedToBottom = pinned
        }
    }

    /// Conversation rouverte, rien en cours : début de la dernière réponse en haut de l'écran,
    /// suivi du bas coupé (sinon le premier changement de géométrie ramènerait aux sources).
    private func showLastAnswerStart(proxy: ScrollViewProxy) {
        scroll.lastPositionedConversationID = viewModel.currentConversationID
        guard !viewModel.isGenerating,
              let last = viewModel.messages.last(where: { $0.role == .assistant }) else { return }
        setPinned(false)
        proxy.scrollTo(ChatTranscriptRow.answerStartID(last.id), anchor: .top)
    }

    /// Remontage de la même conversation avec un lecteur qui avait remonté (iPhone Duo plié / déplié, mission
    /// I1) : retour au message qui était en haut de la zone visible. Message disparu : on reste en bas.
    private func restorePosition(of messageID: UUID, proxy: ScrollViewProxy) {
        guard let message = viewModel.messages.first(where: { $0.id == messageID }) else { return }
        proxy.scrollTo(ChatTranscriptRow.scrollID(for: message), anchor: .top)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// Annonce une erreur à VoiceOver dès qu'elle survient : sans ceci, un
    /// utilisateur VoiceOver n'a aucun moyen de savoir qu'une erreur vient de
    /// s'afficher (le bandeau est un `Label` statique, pas un élément qui
    /// prend le focus tout seul).
    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: Barre de saisie

    /// Voir `ChatComposerView` (sortie de ce fichier, mission C1).
    private var composer: some View {
        ChatComposerView(
            attachmentController: viewModel.attachmentController,
            responseModeStore: responseModeStore,
            draft: draftBinding,
            isDraftFocused: $isDraftFocused,
            isGenerating: viewModel.isGenerating,
            isSendDisabled: isSendDisabled,
            contentMaxWidth: contentMaxWidth,
            onSend: send,
            onStop: { viewModel.stop() },
            engineAccessory: engineAccessory,
            showsKeyboardDismissButton: showsKeyboardDismissButton
        )
    }

    private var showsKeyboardDismissButton: Bool {
        #if os(iOS)
        ComposerKeyboardLayout.showsDismissButton(hasHinge: hasHinge, isVerticallyCompact: verticalSizeClass == .compact, availableHeight: availableHeight)
        #else
        false
        #endif
    }

    // MARK: Actions

    private func send() {
        guard !isSendDisabled else { return }
        // Avant de vider le brouillon : si l'utilisateur annule la feuille, sa saisie reste.
        request(.send(query: draftText))
    }

    private func clearDraft() {
        if let sessionDraft {
            sessionDraft.text = ""
        } else {
            localDraft = ""
        }
    }

    /// Lance `action` tout de suite, ou après l'accord de l'utilisateur si un envoi à une IA cloud n'a pas
    /// encore été autorisé pour ce fournisseur (aucun envoi sans accord). L'attente est tenue par le modèle
    /// (`ChatViewModel.pendingConsent`), pas par cette vue.
    private func request(_ action: PendingSendAction) {
        if case .send(let query) = action, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if viewModel.requestConsent(resuming: action) { return }
        if case .send = action { clearDraft() }
        // `Task.immediate` pour `.send` dans `startSend` (pourquoi : son commentaire).
        viewModel.start(action)
    }

    private var pendingConsentBinding: Binding<PendingCloudConsent?> {
        Binding(
            get: { viewModel.pendingConsent },
            // Volontairement sans effet : « Autoriser » et « Annuler » vident eux-mêmes l'attente du modèle, et la
            // feuille refuse le geste de fermeture. Une écriture de `nil` à la destruction de la vue (pliage de
            // l'iPhone Duo) ne doit surtout pas annuler l'envoi en attente.
            set: { _ in }
        )
    }

    /// Suggestion touchée : envoyée comme une nouvelle question (le bouton Stop l'arrête comme un
    /// envoi tapé).
    private func sendSuggestion(_ suggestion: String) {
        request(.suggestion(suggestion))
    }

    /// Décision (c) : même question, en mode Rapide, à la place de la réponse
    /// sans source fiable. Pas de nouveau message : le suivi est réactivé à
    /// la main, le contenu qui grandit fera le reste.
    private func retryInQuickMode(messageID: UUID) {
        guard !viewModel.isGenerating else { return }
        setPinned(true)
        request(.retryInQuickMode(messageID: messageID))
    }

    /// « Lire cette page » (mission C5) : la page lue, la réponse est refaite avec elle, comme pour toute
    /// génération (accord IA cloud d'abord). Lecture échouée : rien n'est relancé.
    private func readPageAndRegenerate(url: String) async {
        guard await viewModel.readPage(url: url) == .readyToRegenerate else { return }
        setPinned(true)
        request(.regenerateWithReadPages)
    }

    /// Envoi bloqué hors connexion (tâche 1.16) : même question, relancée (le bouton Stop l'arrête
    /// comme un envoi tapé).
    private func relaunchAfterOffline(quickMode: Bool) {
        guard !viewModel.isGenerating else { return }
        setPinned(true)
        request(.retryAfterOffline(quickMode: quickMode))
    }

    /// L'utilisateur vient de demander une nouvelle conversation (bouton ou menu ⇧⌘O). Le brouillon en cours
    /// est gardé : il servira de première question.
    private func userStartedNewConversation() {
        // Le volet de sources (Duo déplié) repart sur la dernière réponse de la conversation qui commence.
        scroll.focusedAnswerID = nil
        isDraftFocused = true
    }
}

// MARK: - Previews

/// Client SearXNG factice pour les previews uniquement — jamais de vrai
/// réseau dans une préview. Même principe que `MockSearXNGClient` dans
/// `TrivaTests/SearchOrchestratorTests.swift` (un `actor`, requis par
/// `SearXNGSearching: Sendable`), dupliqué ici car `private` est scopé au
/// fichier.
private actor PreviewSearXNGClient: SearXNGSearching {
    static let instance = URL(string: "https://searxng.preview.example")!

    static let sampleResults: [SearXNGSearchResult] = [
        SearXNGSearchResult(
            title: "Documentation Swift Concurrency",
            url: "https://developer.apple.com/documentation/swift/concurrency",
            content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        ),
        SearXNGSearchResult(
            title: "SearXNG — moteur de recherche",
            url: "https://docs.searxng.org",
            content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        ),
    ]

    private let results: [SearXNGSearchResult]

    init(results: [SearXNGSearchResult]) {
        self.results = results
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Provider IA factice pour les previews : une seule réponse fixe, streamée
/// via l'implémentation par défaut de `streamGenerate` (un seul yield, voir
/// `AppleIntelligenceProvider.swift`). Même principe que `MockAIGenerating`
/// dans `TrivaTests/SearchOrchestratorTests.swift` (une `final class` simple,
/// pas d'acteur), dupliqué ici car `private` est scopé au fichier.
private final class PreviewAIProvider: AIGenerating {
    private let response: String

    init(response: String) {
        self.response = response
    }

    func generate(prompt: String) async throws -> String { response }
}

/// Source de recherche factice en panne, pour l'aperçu de l'invitation : la
/// chaîne de repli lève alors `WebSearchChainError.allSourcesFailed`.
private struct PreviewFailingSearchProvider: WebSearchProviding {
    let kind: WebSearchSourceKind = .searxng

    func search(query: String, options: WebSearchOptions) async throws -> SearXNGSearchResponse {
        throw WebSearchError.unavailable
    }
}

private func previewViewModel(response: String, sources: [SearXNGSearchResult]) -> ChatViewModel {
    ChatViewModel(
        resolveProvider: { PreviewAIProvider(response: response) },
        resolveFailoverManager: {
            FailoverManager(client: PreviewSearXNGClient(results: sources), instances: [PreviewSearXNGClient.instance])
        }
    )
}

#Preview("Vide") {
    ChatView(viewModel: previewViewModel(response: "", sources: []))
}

#Preview("Avec sources — clair") {
    let viewModel = previewViewModel(
        response: "Voici un résumé basé sur plusieurs sources récentes.",
        sources: PreviewSearXNGClient.sampleResults
    )
    return NavigationStack {
        ChatView(viewModel: viewModel)
    }
    .task { await viewModel.send(query: "Résume l'actualité tech d'aujourd'hui.") }
}

#Preview("Sans sources — sombre") {
    let viewModel = previewViewModel(
        response: "Réponse directe, sans recherche associée.",
        sources: []
    )
    return ChatView(viewModel: viewModel)
        .task { await viewModel.send(query: "Explique-moi un concept.") }
        .preferredColorScheme(.dark)
}

#Preview("Une seule source") {
    let viewModel = previewViewModel(
        response: "Réponse générée via un fournisseur cloud personnel.",
        sources: [PreviewSearXNGClient.sampleResults[0]]
    )
    return ChatView(viewModel: viewModel)
        .task { await viewModel.send(query: "Compare deux produits.") }
}

/// `FailoverManager` factice qui réussit une première fois, puis échoue
/// systématiquement ensuite (aucune instance configurée à partir du 2e appel)
/// — jamais vu par le processus de previews normal jusqu'ici (finding 16 de la
/// revue 0.8) : sert à vérifier à quoi ressemble réellement le bandeau
/// d'erreur quand un échange précédent existe déjà dans la liste (police,
/// alignement, cohabitation avec le scroll auto-ancré en bas).
private final class FlakyFailoverManagerFactory: @unchecked Sendable {
    private var callCount = 0

    func make() -> FailoverManager {
        defer { callCount += 1 }
        if callCount == 0 {
            return FailoverManager(
                client: PreviewSearXNGClient(results: PreviewSearXNGClient.sampleResults),
                instances: [PreviewSearXNGClient.instance]
            )
        }
        return FailoverManager(client: PreviewSearXNGClient(results: []), instances: [])
    }
}

#Preview("Toutes les sources en échec — invitation") {
    let viewModel = ChatViewModel(
        resolveProvider: { PreviewAIProvider(response: "Jamais affiché.") },
        resolveFailoverManager: {
            FailoverManager(client: PreviewSearXNGClient(results: []), instances: [PreviewSearXNGClient.instance])
        },
        resolveWebSearchChain: { _ in
            WebSearchChain(searxng: PreviewFailingSearchProvider(), openSourceProviders: { _ in [] })
        }
    )
    return ChatView(viewModel: viewModel)
        .environment(\.openSearchKeySettings, OpenSearchKeySettingsAction(owner: viewModel, handler: {}))
        .task { await viewModel.send(query: "Quelle est la hauteur de la tour Eiffel ?") }
}

#Preview("Erreur — après un échange déjà réussi") {
    let factory = FlakyFailoverManagerFactory()
    let viewModel = ChatViewModel(
        resolveProvider: { PreviewAIProvider(response: "Voici une première réponse, qui réussit.") },
        resolveFailoverManager: factory.make
    )
    return ChatView(viewModel: viewModel)
        .task {
            await viewModel.send(query: "Première question, qui réussit.")
            await viewModel.send(query: "Deuxième question, qui échoue.")
        }
}

// MARK: - Duo déplié (mission I2)

/// Recherche à l'écran intérieur du Duo déplié en paysage (951 x 669) : la conversation à gauche, les sources de
/// la réponse à droite. Mêmes briques que `EngineStatusView` (`DuoTwoPanes`, `SearchSourcesPane`, bulles sans
/// leur liste de sources), sans l'en-tête moteur ni la session, qui demandent un vrai moteur.
private struct DuoUnfoldedSearchPreview: View {
    let viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            DuoTwoPanes {
                ChatView(viewModel: viewModel)
                    .environment(\.sourcesShownInPane, true)
            } secondary: {
                SearchSourcesPane(messages: viewModel.messages, focusedAnswerID: nil)
            }
        }
        .environment(\.trivaHasHinge, true)
        .environment(\.horizontalSizeClass, .regular)
    }
}

#Preview("Duo déplié — Recherche, conversation | sources (951 x 669)", traits: .fixedLayout(width: 951, height: 669)) {
    let viewModel = previewViewModel(
        response: "Voici un résumé basé sur plusieurs sources récentes[1], dont la documentation officielle[2].",
        sources: PreviewSearXNGClient.sampleResults
    )
    DuoUnfoldedSearchPreview(viewModel: viewModel)
        .task { await viewModel.send(query: "Résume l'actualité tech d'aujourd'hui.") }
}

#Preview("Duo déplié — Recherche, sources à droite, sombre", traits: .fixedLayout(width: 951, height: 669)) {
    let viewModel = previewViewModel(
        response: "Réponse directe, sans recherche associée.",
        sources: []
    )
    DuoUnfoldedSearchPreview(viewModel: viewModel)
        .task { await viewModel.send(query: "Explique-moi un concept.") }
        .preferredColorScheme(.dark)
}

/// Portrait déplié (669 x 951) : une seule colonne, les sources restent sous la réponse.
#Preview("Duo déplié — Recherche, portrait (669 x 951)", traits: .fixedLayout(width: 669, height: 951)) {
    let viewModel = previewViewModel(
        response: "Voici un résumé basé sur plusieurs sources récentes[1].",
        sources: PreviewSearXNGClient.sampleResults
    )
    NavigationStack { ChatView(viewModel: viewModel) }
        .environment(\.trivaHasHinge, true)
        .environment(\.horizontalSizeClass, .regular)
        .task { await viewModel.send(query: "Résume l'actualité tech d'aujourd'hui.") }
}
