//
//  OnboardingActionPlacement.swift
//  Triva
//
//  Mission I1 (2.0, iPhone Duo plié).
//

import CoreGraphics

/// Où poser les boutons d'action du premier lancement (« Continuer », « Commencer »…) : à la suite du
/// contenu, ou épinglés au bas de l'écran ?
///
/// Constat D0 : sur l'écran extérieur de l'iPhone Duo plié (466 x 678 pt), « Continuer » est coupé par le
/// bord bas de l'écran. Le bouton est dans le `ScrollView`, sous le pli. Quand le contenu déborde, les
/// boutons passent donc dans une barre du bas (`safeAreaBar`) qui reste visible ; quand il tient, ils restent
/// à leur place habituelle (iPad, Mac, iPhone dont l'écran est assez haut : rien ne change).
///
/// `contentHeight` et `actionsHeight` sont mesurés SÉPARÉMENT et chacun avec ses marges, pour que la
/// décision ne dépende pas de l'endroit où les boutons sont posés : sinon les mettre dans la barre changerait
/// la hauteur du contenu, qui ferait revenir les boutons, et la mise en page oscillerait. `viewportHeight`
/// est la hauteur de la zone de défilement, qu'une barre du bas ne réduit pas (elle réduit la zone sûre).
nonisolated enum OnboardingActionPlacement {
    /// Marges de la colonne quand les boutons suivent le contenu (valeurs de `AIEngineSelectionView` et
    /// `SearchKeyOnboardingView`) : à ajouter aux hauteurs MESURÉES.
    static let contentTopPadding: CGFloat = 24
    static let actionsLeadingSpacing: CGFloat = 32
    static let bottomPadding: CGFloat = 40

    /// En dessous, la hauteur n'est pas une vraie mesure (première mise en page).
    static let minimumMeasuredHeight: CGFloat = 40

    /// - Parameters:
    ///   - contentHeight: hauteur du contenu SANS les boutons, marge haute comprise ; 0 tant que non mesuré.
    ///   - actionsHeight: hauteur des boutons seuls, espacement avant eux et marge basse compris ; 0 tant que
    ///     non mesuré.
    ///   - viewportHeight: hauteur visible de la zone de défilement.
    /// - Returns: `true` quand le contenu et les boutons ne tiennent pas ensemble.
    static func isPinned(contentHeight: CGFloat, actionsHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight >= minimumMeasuredHeight, contentHeight > 0, actionsHeight > 0 else { return false }
        return contentHeight + actionsHeight > viewportHeight
    }
}
