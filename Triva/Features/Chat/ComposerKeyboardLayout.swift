//
//  ComposerKeyboardLayout.swift
//  Triva
//
//  Mission I1 (2.0, iPhone Duo plié).
//

import CoreGraphics

/// Faut-il un bouton explicite « Fermer le clavier » au-dessus du clavier de la Recherche ?
///
/// Constat D0 : sur l'écran extérieur de l'iPhone Duo (466 x 678 pt), clavier ouvert, la barre d'onglets et le
/// bouton « Nouvelle conversation » disparaissent, et le fil ne montre plus qu'une ligne : aucun geste trouvé
/// pour fermer le clavier, et le toucher suivant a fini par ENVOYER le brouillon. Sur un iPhone ordinaire, le
/// toucher dans le fil (`ChatView`) ferme déjà le clavier : rien n'est ajouté.
///
/// Règle fondée sur la hauteur MESURÉE (jamais sur le modèle d'appareil), comme `EngineHeaderLayout` : la
/// hauteur de la zone de chat baisse quand le clavier s'ouvre. En hauteur compacte (iPhone en paysage), la
/// barre d'outils du clavier ne se justifie pas non plus : le fil y est déjà défilable et le clavier plus bas.
nonisolated enum ComposerKeyboardLayout {
    /// En dessous de cette hauteur offerte au chat (clavier ouvert), le bouton est montré. Mesuré (mission I1),
    /// chat vide, clavier ouvert : 220 pt sur l'iPhone Duo plié, 285 pt sur l'iPhone 18 Pro. 250 pt tombe
    /// entre les deux (environ 30 pt de marge de chaque côté). Clavier fermé, les deux offrent plus de 500 pt.
    static let dismissButtonMaximumHeight: CGFloat = 250

    /// En dessous, la hauteur n'est pas une vraie mesure (état transitoire de la première mise en page,
    /// même repère que `EngineHeaderLayout.minimumMeasuredHeight`).
    static let minimumMeasuredHeight: CGFloat = 40

    /// - Parameter hasHinge: l'appareil a une charnière (`\.trivaHasHinge`). Sans charnière (iPhone ordinaire,
    ///   iPad, Mac) le bouton n'est JAMAIS ajouté, même si la hauteur offerte est basse (iPad en Split View,
    ///   petit iPhone clavier ouvert) : correction C6 de la revue R1.
    static func showsDismissButton(hasHinge: Bool, isVerticallyCompact: Bool, availableHeight: CGFloat) -> Bool {
        guard hasHinge, !isVerticallyCompact, availableHeight >= minimumMeasuredHeight else { return false }
        return availableHeight < dismissButtonMaximumHeight
    }
}
