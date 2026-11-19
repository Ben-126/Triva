//
//  AnswerDragViews.swift
//  Triva
//
//  Chantier 2.2 (G2) : glisser SORTANT, côté interface. Logique pure : `AnswerDragPayload.swift`.
//
//  Pourquoi une poignée et pas la bulle entière : sur Mac comme sur iPad, un glisser qui part du texte
//  est un geste de SÉLECTION (et sur iPad l'appui long). `.draggable` sur toute la bulle entrerait en
//  concurrence avec lui, et avec les citations touchables. La poignée est une zone dédiée, à côté de
//  Copier et Partager : le texte reste libre pour la sélection, et le geste se découvre au même endroit
//  que les autres moyens d'emporter la réponse. Les sources, elles, n'ont pas de texte à sélectionner
//  dans la ligne (un lien) : la ligne elle-même se glisse, comme un lien dans Safari.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AnswerDragPlatform {
    /// iPhone : pas de glisser vers une autre app. Mac : jamais. Le Duo suit l'idiome que le système lui donne.
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

/// Poignée « glisser la réponse » : emporte le texte déjà marqué « générée par IA » (`AnswerShareText`).
struct AnswerDragHandle: View {
    /// Texte déjà marqué (`AnswerShareText.text`) : le même que celui de Copier et Partager.
    let text: String

    #if os(iOS)
    private static let minimumSide: CGFloat = 44
    #else
    private static let minimumSide: CGFloat = 28
    #endif

    var body: some View {
        if AnswerDragPayload.offersHandle(isPhone: AnswerDragPlatform.isPhone),
           let payload = AnswerDragPayload.text(fromShareText: text) {
            Label(AnswerDragPayload.handleTitle, systemImage: AnswerDragPayload.handleSystemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: Self.minimumSide, minHeight: Self.minimumSide)
                .contentShape(.rect)
                .draggable(payload) {
                    AnswerDragPreview(excerpt: AnswerDragPayload.previewExcerpt(of: payload))
                }
                .accessibilityIdentifier("chat.dragAnswer")
                #if os(macOS)
                .pointerStyle(.grabIdle)
                .help(AnswerDragPayload.handleTitle)
                #endif
        }
    }
}

/// Ce qui suit le pointeur pendant le glisser : le début de la réponse. Matière du système, pas de verre
/// (l'image n'est pas un conteneur de l'interface) ; rayon 20 comme tout conteneur (DESIGN.md).
private struct AnswerDragPreview: View {
    let excerpt: String

    var body: some View {
        Text(verbatim: excerpt)
            .font(.footnote)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(width: 280, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
    }
}

extension View {
    /// Rend une ligne de source glissable (vers Safari, Notes, le bureau…) avec son adresse. Sans effet
    /// quand l'adresse est `nil` (pièce jointe, URL non web) et sur iPhone.
    func sourceDraggable(_ url: URL?) -> some View {
        modifier(SourceDragModifier(url: url))
    }
}

private struct SourceDragModifier: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if AnswerDragPayload.offersHandle(isPhone: AnswerDragPlatform.isPhone), let url {
            content.draggable(url)
        } else {
            content
        }
    }
}
