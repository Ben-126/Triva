//
//  DuoPaneContainer.swift
//  Triva
//
//  Mission I2 (2.0, iPhone Duo déplié).
//

import SwiftUI

/// Mesure la largeur offerte à son contenu et lui dit combien de colonnes montrer (`DuoPaneLayout`).
///
/// Le contenu reçoit 1 ou 2. La mesure porte sur ce conteneur, qui remplit toujours l'espace offert : elle ne
/// dépend donc pas du contenu, et passer de 1 à 2 colonnes ne peut pas la faire osciller. Sans charnière
/// (`\.trivaHasHinge` faux : iPad, Mac, iPhone ordinaire), le contenu reçoit toujours 1.
struct DuoPaneContainer<Content: View>: View {
    @ViewBuilder let content: (_ columnCount: Int) -> Content

    @Environment(\.trivaHasHinge) private var hasHinge
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var width: CGFloat = 0

    private var columnCount: Int {
        #if os(iOS)
        let vertical = verticalSizeClass
        #else
        let vertical: UserInterfaceSizeClass? = nil
        #endif
        return DuoPaneLayout.columnCount(
            hasHinge: hasHinge,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: vertical,
            detailWidth: width
        )
    }

    var body: some View {
        content(columnCount)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Deux volets côte à côte (`ArrangementView`, 27.1), le second à droite ; le premier seul sous 27.1.
/// Le fractionnement se fait côte à côte uniquement (`.split.axes(.horizontal)`) : sur le Duo déplié en
/// paysage il tombe de part et d'autre du pli quand l'appareil est entrouvert. La navigation reste EN DEHORS
/// (HIG : « Keep navigation outside of arrangement views »).
struct DuoTwoPanes<Primary: View, Secondary: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    var body: some View {
        if #available(iOS 27.1, macOS 27.1, *) {
            ArrangementView(primary: primary, secondary: secondary)
                .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            primary()
        }
    }
}
