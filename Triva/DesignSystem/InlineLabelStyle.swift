//
//  InlineLabelStyle.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

/// Style de `Label` qui garde partout le même écart de 6 pt entre le symbole et le texte.
///
/// POURQUOI : dans un `Form` ou une `List`, un `Label` reçoit le style de liste du système, qui
/// aligne les symboles sur une colonne et double l'écart avec le texte. Le badge moteur (capsule en
/// verre) s'affichait donc autrement dans les Réglages que dans la Recherche, alors que ses
/// modificateurs étaient les mêmes (finding Q3 n°39). Ce style est posé par l'écran qui héberge le
/// badge dans une liste : `EngineBadge` reste inchangé.
struct InlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == InlineLabelStyle {
    static var inline: InlineLabelStyle { InlineLabelStyle() }
}
