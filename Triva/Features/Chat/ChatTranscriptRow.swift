//
//  ChatTranscriptRow.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

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
struct ChatTranscriptRow: View {
    let message: ChatViewModel.Message
    let viewModel: ChatViewModel
    let onRetry: @MainActor (UUID) -> Void
    /// « Réessayer » sous une réponse interrompue (mission M).
    let onRetryInterrupted: @MainActor (UUID) -> Void
    /// Reçoit le haut de la rangée dans le repère nommé `topCoordinateSpace` (mission I1) : sert à garder
    /// la position de lecture quand la vue est remplacée (`TranscriptScrollState`). `nil` : rien n'est mesuré.
    var onTopChange: (@MainActor (CGFloat) -> Void)?
    var topCoordinateSpace = ""

    /// Identifiant du DÉBUT d'une réponse (son premier widget, sinon sa bulle) : c'est là
    /// qu'une conversation rouverte s'ouvre (`ChatView`, mission C1), et non sur le bas de la
    /// bulle, c'est-à-dire sur les sources (QA Q1, pt 14).
    static func answerStartID(_ messageID: UUID) -> String {
        "answer-start-\(messageID.uuidString)"
    }

    /// Identifiant de défilement du HAUT de la rangée d'un message : celui qu'`.id` pose sur son premier élément
    /// (voir `body`). `ChatView` y revient pour restaurer la position de lecture.
    static func scrollID(for message: ChatViewModel.Message) -> String {
        scrollID(messageID: message.id, isAnswer: message.role == .assistant)
    }

    static func scrollID(messageID: UUID, isAnswer: Bool) -> String {
        isAnswer ? answerStartID(messageID) : messageID.uuidString
    }

    private static func isIdle(_ phase: ImageResultsPhase) -> Bool {
        if case .idle = phase { return true }
        return false
    }

    private static func isIdle(_ phase: VideoResultsPhase) -> Bool {
        if case .idle = phase { return true }
        return false
    }

    /// « Réponse interrompue » : sous le début de réponse gardé, ou seule quand rien n'était encore écrit (elle porte
    /// alors l'ancre de défilement que la bulle absente ne peut pas porter). Hors verre, même style que le bandeau
    /// d'erreur du fil, encre des légendes.
    @ViewBuilder
    private func interruptedNote(hasBubble: Bool) -> some View {
        let note = Text(ChatViewModel.interruptedAnswerMessage)
            .font(.footnote)
            .foregroundStyle(MessageBubbleView.legendStyle)
            .accessibilityIdentifier("chat.answerInterrupted")
        if hasBubble || !message.widgets.isEmpty {
            note
        } else {
            note
                .id(Self.answerStartID(message.id))
                .reportingTop(onTopChange, in: topCoordinateSpace)
        }
    }

    var body: some View {
        let answer = MessageBubbleView.answerSnapshot(of: message)
        let isAnswer = message.role == .assistant
        let messageID = message.id

        Group {
            if isAnswer {
                // Cartes sans conteneur propre : celui du fil sert (voir
                // `WeatherWidgetView`). Liste fixe pour un message donné.
                ForEach(message.widgets.indices, id: \.self) { index in
                    Group {
                        switch message.widgets[index] {
                        case .weather(let data):
                            WeatherWidgetView(data: data)
                        case .calculation(let data):
                            CalculationWidgetView(data: data)
                        }
                    }
                    .id(index == 0 ? Self.answerStartID(messageID) : "widget-\(index)-\(messageID.uuidString)")
                    .reportingTop(index == 0 ? onTopChange : nil, in: topCoordinateSpace)
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
                .id(isAnswer && message.widgets.isEmpty ? Self.answerStartID(messageID) : messageID.uuidString)
                .reportingTop(!isAnswer || message.widgets.isEmpty ? onTopChange : nil, in: topCoordinateSpace)
            }

            if isAnswer, MessageBubblePresentation.showsMediaSearch(answer) {
                // Décision (a) : rien n'est cherché tant que l'utilisateur
                // n'appuie pas. `onSearch` capture l'identifiant, jamais le
                // message (il servira aussi à « Réessayer »).
                let images = ImageResultsView(phase: message.images, onSearch: { viewModel.searchImages(messageID: messageID) })
                let videos = VideoResultsView(phase: message.videos, onSearch: { viewModel.searchVideos(messageID: messageID) })
                if Self.isIdle(message.images), Self.isIdle(message.videos) {
                    // Deux boutons seuls : côte à côte s'ils tiennent (Mac, iPad : ≈190 pt chacun
                    // dans 640 pt), empilés sinon (QA Q3, finding 48). Dès qu'une recherche est
                    // lancée, ses résultats prennent toute la largeur : empilés.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { images; videos }
                        VStack(alignment: .leading, spacing: 16) { images; videos }
                    }
                } else {
                    images
                    videos
                }
            }

            if isAnswer, message.status == .interrupted {
                interruptedNote(hasBubble: MessageBubblePresentation.showsBubble(answer))
            }

            if viewModel.canRetryInterrupted(message) {
                Button(ChatViewModel.retryInterruptedTitle, systemImage: "arrow.clockwise") {
                    onRetryInterrupted(messageID)
                }
                .font(.subheadline)
                .buttonStyle(.glass)
                .accessibilityIdentifier("chat.retryInterrupted")
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

private extension View {
    /// Rapporte le haut de la vue (repère `space`) à chaque changement de mise en page, pas à chaque image de
    /// défilement : le repère est celui du contenu. `nil` : aucun effet.
    @ViewBuilder
    func reportingTop(_ report: (@MainActor (CGFloat) -> Void)?, in space: String) -> some View {
        if let report {
            onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(space)).minY } action: { report($0) }
        } else {
            self
        }
    }
}
