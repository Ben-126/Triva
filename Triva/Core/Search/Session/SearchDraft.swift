//
//  SearchDraft.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

/// Texte de la barre de saisie de la Recherche, détenu par la `SearchSession`
/// plutôt que par `ChatView` (mission I4b). Deux raisons :
/// 1. Découvrir > « Chercher dans Triva » doit pouvoir REMPLIR la barre depuis
///    un autre espace (`TrivaRootCoordinator.search(_:)`) ;
/// 2. `ChatView` est démontée à chaque changement de destination en
///    présentation sidebar (iPad, Mac), et à chaque bascule de classe de
///    taille (Split View, Stage Manager, iPhone Duo déplié) : un texte en
///    `@State` dans la vue serait perdu à chaque fois.
///
/// Transmis à `ChatView` par l'environnement (`EngineStatusView`). Contrat
/// côté `ChatView` : lecture OPTIONNELLE,
/// `@Environment(SearchDraft.self) private var draft: SearchDraft?` — ses
/// aperçus n'en injectent pas, une lecture non optionnelle les ferait planter —,
/// barre liée à `draft.text` quand il est présent, vidée après l'envoi.
@Observable
@MainActor
final class SearchDraft {
    var text = ""
}
