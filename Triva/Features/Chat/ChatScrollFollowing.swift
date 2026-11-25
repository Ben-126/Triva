//
//  ChatScrollFollowing.swift
//  Triva
//
//  Sorti de `ChatView.swift` (mission I1) : ce fichier dépassait la limite de 800 lignes.
//

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
    ///
    /// Un écran VIDE (aucun message) ne suit jamais le bas : il se lit depuis le haut. Sans cette règle, dans une petite
    /// fenêtre, une image collée dans la saisie rétrécit la liste, le « suivi » descendait jusqu'au dernier exemple, et
    /// « Que veux-tu savoir ? » et « ESSAIE » sortaient du cadre (mission I, capture de Ben du 25/11).
    static func shouldFollowContent(from old: Metrics, to new: Metrics, phase: ScrollPhase, isPinned: Bool, hasMessages: Bool = true) -> Bool {
        guard hasMessages, isPinned, allowsProgrammaticScroll(during: phase) else { return false }
        return new.scrollableHeight > old.scrollableHeight
    }

    /// Où la liste s'ouvre : en haut tant qu'elle n'a aucun message (l'écran vide).
    static func initialScrollAnchor(hasMessages: Bool) -> UnitPoint { hasMessages ? .bottom : .top }

    /// Ce que fait la liste quand le NOMBRE de messages change.
    enum MessageCountChange: Equatable {
        case showTop
        case followBottom
        case showLastAnswerStart
    }

    /// Plus aucun message (nouvelle conversation) : le haut de l'écran vide. Un échange en cours : le bas. Sinon (une
    /// conversation rouverte) : le début de sa dernière réponse.
    static func action(afterMessageCountChange isGenerating: Bool, hasMessages: Bool) -> MessageCountChange {
        if !hasMessages { return .showTop }
        return isGenerating ? .followBottom : .showLastAnswerStart
    }

    /// `onAppear` ne recentre sur le début de la dernière réponse que pour une conversation que la vue
    /// n'a pas encore positionnée (ouverture depuis la Bibliothèque ou un favori). Un simple retour sur
    /// l'onglet Recherche garde la position de lecture.
    static func shouldPositionOnAppear(current: UUID?, lastPositioned: UUID?) -> Bool {
        current != lastPositioned
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
