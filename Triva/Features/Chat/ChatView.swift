import SwiftUI

// MARK: - Suivi du bas de liste (bug 7)

/// Quand le fil suit-il le bas de la liste ? Logique pure, testée dans
/// `MessageBubblePresentationTests.swift`.
///
/// ## Le bug 7 de la revue
/// L'ancrage était DÉDUIT DE LA POSITION (« à moins de 80 pt du bas »), alors
/// que la croissance du contenu déplace elle-même le bas : pendant un
/// streaming, l'utilisateur qui remontait doucement était ramené en bas à
/// chaque morceau, et un gros saut de contenu (5 sources d'un coup, une
/// réponse arrivée en un bloc) pouvait au contraire faire décrocher le suivi,
/// la réponse s'écrivant alors sous la zone visible.
///
/// ## La règle
/// L'intention se lit dans le GESTE (`ScrollPhase`), pas dans la position :
/// - le doigt (ou le trackpad) fait défiler → le suivi s'arrête aussitôt ;
/// - le geste se termine (lâcher, fin d'inertie) → le suivi reprend si l'on
///   s'est arrêté près du bas, sinon la vue reste où l'utilisateur l'a
///   laissée ;
/// - un simple toucher (`.tracking`, par exemple sur un badge de citation) ne
///   compte pas comme un geste de défilement ;
/// - un défilement sans phase de geste (molette de souris, flèches du
///   clavier) se reconnaît à l'offset qui remonte : même effet ;
/// - jamais de défilement programmatique pendant un geste ;
/// - le suivi se déclenche après la mise en page (`onScrollGeometryChange`),
///   quand la hauteur défilable augmente : contenu qui grandit OU conteneur
///   qui rétrécit (clavier iPhone, fenêtre Mac raccourcie).
nonisolated enum ChatScrollFollowing {
    /// Distance au bas (pt) sous laquelle on est « en bas » à la fin d'un
    /// geste. Même valeur que l'ancien seuil validé à la main.
    static let nearBottomThreshold: CGFloat = 80
    /// Écarts d'offset ignorés : arrondis de mise en page, pas un geste.
    static let offsetTolerance: CGFloat = 1

    /// Les trois mesures utiles d'une `ScrollGeometry`.
    nonisolated struct Metrics: Sendable, Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat

        init(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) {
            self.offsetY = offsetY
            self.contentHeight = contentHeight
            self.containerHeight = containerHeight
        }

        /// Même calcul que l'ancien observateur, validé à la main.
        init(_ geometry: ScrollGeometry) {
            self.init(
                offsetY: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height
            )
        }

        var distanceFromBottom: CGFloat { contentHeight - offsetY - containerHeight }
        /// Défilement maximal : grandit quand le contenu grandit, ou quand le
        /// conteneur rétrécit.
        var scrollableHeight: CGFloat { contentHeight - containerHeight }
    }

    /// Changement de phase de défilement.
    static func isPinnedAfterPhaseChange(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        distanceFromBottom: CGFloat,
        wasPinned: Bool
    ) -> Bool {
        switch newPhase {
        case .interacting:
            return false
        case .idle where oldPhase == .interacting || oldPhase == .decelerating:
            return distanceFromBottom < nearBottomThreshold
        default:
            // `.animating` -> `.idle` (fin d'un `scrollTo` animé) : rien ne
            // change. Réévaluer ici décrocherait un échange tout neuf dont le
            // contenu grandit pendant l'animation.
            return wasPinned
        }
    }

    /// Fin d'un toucher ou d'une animation alors que le suivi est actif :
    /// le contenu a pu grandir pendant ce temps sans être suivi (le suivi est
    /// suspendu pendant `.tracking`) — sans ce rattrapage, le DERNIER morceau
    /// d'une réponse reçu pendant un toucher resterait sous la zone visible.
    static func needsCatchUp(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        isPinned: Bool,
        distanceFromBottom: CGFloat
    ) -> Bool {
        isPinned
            && newPhase == .idle
            && (oldPhase == .tracking || oldPhase == .animating)
            && distanceFromBottom > offsetTolerance
    }

    /// Défilement sans phase de geste (molette, clavier). Un offset qui
    /// remonte loin du bas ne vient que de l'utilisateur : la croissance du
    /// contenu ne déplace pas l'offset, et un contenu qui rétrécit le ramène
    /// au bas, distance nulle.
    static func isPinnedAfterGeometryChange(
        from old: Metrics,
        to new: Metrics,
        phase: ScrollPhase,
        wasPinned: Bool
    ) -> Bool {
        let offsetDelta = new.offsetY - old.offsetY
        if wasPinned {
            let scrolledAway = offsetDelta < -offsetTolerance && new.distanceFromBottom > nearBottomThreshold
            return !scrolledAway
        }
        return phase == .idle && offsetDelta > offsetTolerance && new.distanceFromBottom < nearBottomThreshold
    }

    /// LE déclencheur du suivi, unique et après mise en page.
    static func shouldFollowContent(from old: Metrics, to new: Metrics, phase: ScrollPhase, isPinned: Bool) -> Bool {
        guard isPinned, allowsProgrammaticScroll(during: phase) else { return false }
        return new.scrollableHeight > old.scrollableHeight
    }

    static func allowsProgrammaticScroll(during phase: ScrollPhase) -> Bool {
        switch phase {
        case .idle, .animating:
            true
        case .tracking, .interacting, .decelerating:
            false
        }
    }
}

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

    /// - Parameter responseModeStore: le store PARTAGÉ du mode de réponse
    ///   (1.13), le même que celui des Réglages. `nil` : l'instance unique du
    ///   processus (`sharedResponseModeStore`). Pas de valeur par défaut
    ///   `= ChatView.sharedResponseModeStore` : une expression par défaut est
    ///   évaluée hors du main actor (même piège que `EngineStatusView.init`).
    init(viewModel: ChatViewModel, responseModeStore: ResponseModeSettingsStore? = nil) {
        self.viewModel = viewModel
        self.injectedResponseModeStore = responseModeStore
    }

    /// Brouillon de la session (`SearchDraft`, `ContentView.swift`) : il
    /// survit au démontage de cette vue (changement de destination en
    /// sidebar, bascule de classe de taille) et reçoit le texte de Découvrir >
    /// « Chercher dans Triva ». Lecture OPTIONNELLE, contrat d'I4b : les
    /// aperçus n'en injectent pas, une lecture non optionnelle les ferait
    /// planter — repli sur `localDraft`.
    @Environment(SearchDraft.self) private var sessionDraft: SearchDraft?
    @State private var localDraft = ""
    /// `Task` de la génération en cours, créée par `send()` — jamais une
    /// `Task {}` perdue (le handle serait alors immédiatement jeté) : gardée
    /// ici pour pouvoir l'annuler explicitement dans `.onDisappear`. Sans
    /// cela, quitter cet écran pendant une génération (ex. changement de
    /// moteur IA depuis `ContentView`) laisserait le flux tourner
    /// indéfiniment en arrière-plan, invisible et impossible à arrêter —
    /// alors que `ChatViewModel.send(query:)` réagit correctement à
    /// l'annulation de cette `Task` (voir son commentaire de tête). Les
    /// suggestions touchées et la relance en mode Rapide passent par elle
    /// aussi : le bouton Stop les arrête de la même façon.
    @State private var sendTask: Task<Void, Never>?
    /// Le fil suit-il le bas de la liste ? Voir `ChatScrollFollowing`.
    @State private var isPinnedToBottom = true
    /// Dernière phase de défilement connue, lue par l'observateur de
    /// géométrie (aucun défilement programmatique pendant un geste).
    @State private var scrollPhase: ScrollPhase = .idle
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Voir `EnvironmentValues.openSearchKeySettings`.
    @Environment(\.openSearchKeySettings) private var openSearchKeySettings
    @FocusState private var isDraftFocused: Bool

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
    /// (même règle que le web) ; `nil` pendant une génération.
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
        .toolbar {
            // Décision 1 de Ben : les questions s'enchaînent dans la même
            // conversation jusqu'à ce bouton ; l'ancienne reste dans la
            // Bibliothèque. ⇧⌘O plutôt que ⌘N, qui ouvre une nouvelle
            // fenêtre sur Mac et iPad.
            ToolbarItem(placement: .primaryAction) {
                Button("Nouvelle conversation", systemImage: "square.and.pencil") {
                    startNewConversation()
                }
                .disabled(viewModel.messages.isEmpty)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .accessibilityIdentifier("chat.newConversation")
                #if os(macOS)
                .help("Nouvelle conversation")
                #endif
            }
        }
        .onDisappear {
            sendTask?.cancel()
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
                    // UN seul conteneur pour tout le verre du fil : bulles,
                    // widgets, boutons des médias et de relance (DESIGN.md).
                    // Les suggestions ouvrent le leur, donc restent dehors.
                    GlassEffectContainer(spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.messages) { message in
                                ChatTranscriptRow(
                                    message: message,
                                    viewModel: viewModel,
                                    onRetry: { messageID in retryInQuickMode(messageID: messageID) }
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
            }
            // Une conversation rouverte (Bibliothèque, favori) s'ouvre sur
            // sa fin, comme Messages.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
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
                    wasPinned: isPinnedToBottom
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
                    wasPinned: isPinnedToBottom
                )
                setPinned(pinned)
                if ChatScrollFollowing.shouldFollowContent(from: oldMetrics, to: newMetrics, phase: scrollPhase, isPinned: pinned) {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
            .onChange(of: viewModel.messages.count) {
                // Un nouvel échange (nouvelle question envoyée), une
                // conversation rouverte ou vidée reprend toujours le suivi,
                // même si l'utilisateur avait remonté pour relire.
                setPinned(true)
                scrollToBottom(proxy: proxy)
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
        if isPinnedToBottom != pinned {
            isPinnedToBottom = pinned
        }
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

    /// Fichiers joints au-dessus (`FileAttachmentTray`, frère du conteneur :
    /// il ouvre le sien), puis la barre : trombone, mode de réponse, champ,
    /// envoi. Trombone et mode en `.glass` (actions secondaires), envoi seul en
    /// `.glassProminent` (DESIGN.md). Même largeur plafonnée que le fil.
    private var composer: some View {
        VStack(spacing: 0) {
            if !viewModel.attachmentController.isEmpty {
                FileAttachmentTray(controller: viewModel.attachmentController)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    // Le contrôleur du ViewModel, jamais un `@State` d'ici :
                    // ses fichiers n'atteindraient pas le pipeline.
                    FileAttachmentPicker(controller: viewModel.attachmentController)

                    ResponseModeSelector(store: responseModeStore)

                    TextField("Pose ta question…", text: draftBinding)
                        .focused($isDraftFocused)
                        .onSubmit(send)
                        .accessibilityIdentifier("chat.input")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        // PAS `.interactive()`, écart assumé avec DESIGN.md (« Barre de recherche ») :
                        // le verre interactif volait le toucher au menu du mode de réponse, ouvert
                        // par-dessus ce champ. Sur iPhone, toucher « Fiable » ne faisait rien, et le
                        // menu restait ouvert (constaté à l'écran, QA Q1).
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))

                    sendButton
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    private var sendButton: some View {
        Button {
            if viewModel.isGenerating {
                // Affordance d'annulation : sans elle, une génération qui ne
                // répond plus (ex. connexion BYOK qui pend) tourne jusqu'au
                // timeout réseau par défaut, sans aucun moyen de l'arrêter
                // autrement qu'en quittant l'écran (ce qui annule aussi via
                // `.onDisappear`, mais fait perdre l'écran).
                sendTask?.cancel()
            } else {
                send()
            }
        } label: {
            Image(systemName: viewModel.isGenerating ? "stop.fill" : "arrow.up")
        }
        .buttonStyle(.glassProminent)
        .disabled(viewModel.isGenerating ? false : isSendDisabled)
        .accessibilityLabel(viewModel.isGenerating ? "Arrêter la génération" : "Envoyer")
        .accessibilityIdentifier("chat.send")
        // Échap arrête la génération (clavier matériel, Mac et iPad) ; rien
        // le reste du temps, pour ne jamais envoyer par accident.
        .keyboardShortcut(viewModel.isGenerating ? KeyboardShortcut.cancelAction : nil)
    }

    // MARK: Actions

    private func send() {
        guard !isSendDisabled else { return }
        let query = draftText
        if let sessionDraft {
            sessionDraft.text = ""
        } else {
            localDraft = ""
        }
        sendTask = Task { await viewModel.send(query: query) }
    }

    /// Suggestion touchée : envoyée comme une nouvelle question, dans
    /// `sendTask` (le bouton Stop l'arrête comme un envoi tapé).
    private func sendSuggestion(_ suggestion: String) {
        guard !viewModel.isGenerating else { return }
        sendTask = Task { await viewModel.send(query: suggestion) }
    }

    /// Décision (c) : même question, en mode Rapide, à la place de la réponse
    /// sans source fiable. Pas de nouveau message : le suivi est réactivé à
    /// la main, le contenu qui grandit fera le reste.
    private func retryInQuickMode(messageID: UUID) {
        guard !viewModel.isGenerating else { return }
        setPinned(true)
        sendTask = Task { await viewModel.retryInQuickMode(messageID: messageID) }
    }

    /// Le brouillon en cours est gardé : il servira de première question.
    private func startNewConversation() {
        viewModel.startNewConversation()
        isDraftFocused = true
    }
}

// MARK: - Un message du fil

/// Un message et ce qui l'entoure, dans l'ordre de lecture : widgets
/// (au-dessus de la réponse), la bulle, les médias à la demande, puis la
/// relance en mode Rapide. Tous sont des éléments de verre FRÈRES de la
/// bulle, jamais dedans (pas de verre sur du verre), dans le conteneur du fil.
///
/// `Group` et non `VStack` : ses enfants s'insèrent directement dans le
/// `VStack(spacing: 16)` du fil, donc 16 pt entre deux éléments de verre
/// (en dessous, le conteneur les fondrait), et un message qui n'affiche rien
/// (échec avant tout contenu, bulle masquée) ne laisse aucun trou.
private struct ChatTranscriptRow: View {
    let message: ChatViewModel.Message
    let viewModel: ChatViewModel
    let onRetry: @MainActor (UUID) -> Void

    var body: some View {
        let answer = MessageBubbleView.answerSnapshot(of: message)
        let isAnswer = message.role == .assistant
        let messageID = message.id

        Group {
            if isAnswer {
                // Cartes sans conteneur propre : celui du fil sert (voir
                // `WeatherWidgetView`). Liste fixe pour un message donné.
                ForEach(message.widgets.indices, id: \.self) { index in
                    switch message.widgets[index] {
                    case .weather(let data):
                        WeatherWidgetView(data: data)
                    case .calculation(let data):
                        CalculationWidgetView(data: data)
                    }
                }
            }

            if !isAnswer || MessageBubblePresentation.showsBubble(answer) {
                // `.equatable()` (voir `MessageBubbleView`) : la bulle n'est
                // réévaluée que si son message ou son étoile change, pas à
                // chaque snapshot reçu par une AUTRE bulle. `isFavorite` est
                // lu ICI, dans un `body` : il observe la révision des favoris.
                MessageBubbleView(
                    message: message,
                    isFavorite: viewModel.isFavorite(message),
                    canToggleFavorite: viewModel.canToggleFavorite(message),
                    onToggleFavorite: { viewModel.toggleFavorite(messageID: messageID) }
                )
                .equatable()
            }

            if isAnswer, MessageBubblePresentation.showsMediaSearch(answer) {
                // Décision (a) : rien n'est cherché tant que l'utilisateur
                // n'appuie pas. `onSearch` capture l'identifiant, jamais le
                // message (il servira aussi à « Réessayer »).
                ImageResultsView(phase: message.images, onSearch: { viewModel.searchImages(messageID: messageID) })
                VideoResultsView(phase: message.videos, onSearch: { viewModel.searchVideos(messageID: messageID) })
            }

            if viewModel.canRetryInQuickMode(message) {
                // Décision (c) : jamais de réponse sans source en mode
                // Fiable ; on propose la relance, en verre (action
                // secondaire), hors de la bulle.
                Button(ChatViewModel.retryInQuickModeTitle, systemImage: ResponseMode.quick.systemImage) {
                    onRetry(messageID)
                }
                .font(.subheadline)
                .buttonStyle(.glass)
                .accessibilityIdentifier("chat.retryQuickMode")
            }
        }
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
