//
//  ResponseModeSelector.swift
//  Triva
//
//  Created by ben podrojsky on 03/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Présentation (logique pure, testable)

/// Textes et règles d'affichage du sélecteur de mode (tâche 1.13), isolés de
/// la vue pour être vérifiables sans interface.
///
/// PAS `nonisolated`, contrairement à `SuggestionsPresentation` : ces règles
/// lisent `ResponseMode.title` et `ResponseMode.explanation`, et
/// `ResponseMode.swift` ne marque pas l'enum `nonisolated`. Sous
/// `-default-isolation=MainActor`, ses membres sont donc isolés au main actor
/// (voir le commentaire de tête de `PromptTemplates`) : les lire depuis un
/// contexte non isolé ne compilerait pas. Sans conséquence ici, seule une vue
/// s'en sert ; une suite de tests `@MainActor` peut les vérifier.
enum ResponseModeSelectorPresentation {

    /// Nom du contrôle pour VoiceOver, et titre de la liste des options.
    static let controlTitle = "Mode de réponse"

    /// Le titre du mode s'affiche-t-il à côté de son icône ?
    ///
    /// Oui partout, SAUF en largeur compacte (iPhone, iPad en Split View
    /// étroit) : la barre de saisie y garde sa place pour le champ de texte,
    /// qui est l'élément principal, et « Approfondie » mangerait à lui seul
    /// une centaine de points. `nil` est traité comme une largeur confortable :
    /// c'est ce que peut rendre macOS, qui n'a pas de classe de taille, et une
    /// fenêtre Mac a la place d'afficher le titre.
    static func showsTitle(for horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass != .compact
    }

    /// Infobulle macOS : le mode actif et ce qu'il fait. Elle porte
    /// l'explication si le menu macOS n'affiche pas le sous-titre des options.
    static func helpText(for mode: ResponseMode) -> String {
        "\(controlTitle) : \(mode.title). \(mode.explanation)"
    }
}

// MARK: - Vue

/// Sélecteur du mode de réponse (tâche 1.13 : Rapide, Approfondie, Fiable), à
/// poser dans la barre de saisie, à côté du champ de texte.
///
/// Port de `src/components/MessageInputActions/ResponseMode.tsx` (web), qui
/// aligne quatre boutons-icônes dans une pilule à bordure et ne montre
/// l'explication d'un mode qu'au survol (`title=`). Le 4e mode, « Débat », est
/// hors périmètre V1 (décision de Ben) : `ResponseMode` n'en a que trois.
/// Libellés, explications et symboles viennent tous de `ResponseMode`, aucun
/// n'est réécrit ici.
///
/// ## Pourquoi un `Menu` plutôt que trois boutons
/// Le plan évoque « 3 boutons/icônes ». Choix retenu : un `Menu` natif dont
/// l'étiquette est l'icône du mode actif.
/// - Largeur : trois boutons en verre (environ 44 pt chacun, plus deux
///   espacements) occupent près d'un tiers de la barre de saisie d'un iPhone,
///   au détriment du champ de texte.
/// - Explication accessible : un bouton-icône n'a pas de survol au doigt. Ici,
///   chaque option affiche son explication en sous-titre (second `Text` de
///   l'étiquette). Si le menu macOS ne montre pas ce sous-titre, l'infobulle
///   (`help`) et l'indice VoiceOver portent l'explication du mode actif.
/// - VoiceOver : un seul contrôle, « Mode de réponse, Rapide », dont les
///   options sont cochées nativement par le `Picker`. Trois boutons
///   obligeraient à recomposer l'état sélectionné à la main.
/// - C'est l'idiome Apple pour un choix exclusif peu fréquent (le tri dans
///   Fichiers, par exemple).
///
/// ## Aucun état, aucune persistance ici
/// La vue reçoit un `Binding`. Source de vérité UNIQUE :
/// `ResponseModeSettingsStore` (clé `chat.responseMode.selected`), branché
/// via `init(store:)`. Volontairement pas de `@AppStorage` sur cette clé :
/// il n'écrit rien tant que l'utilisateur n'a pas touché au menu, et le store,
/// qui ne lit la clé qu'à son initialisation, retomberait alors sur son propre
/// défaut. Deux défauts, deux vérités : l'interface pourrait afficher
/// « Rapide » pendant que le pipeline lance une recherche « Approfondie ».
///
/// Le défaut décidé par Ben (Rapide, qui remplace le défaut « deep » repris du
/// web) et le repli d'une valeur inconnue relèvent donc du store :
/// `ResponseModeSettingsStore.defaultMode` DOIT valoir `.quick`, et c'est la
/// suite de tests du store qui le garantit. Ne jamais compenser ici un défaut
/// erroné du store (`@AppStorage` avec `.quick`, valeur forcée au premier
/// affichage) : ce serait recréer la double vérité décrite ci-dessus.
///
/// ## Verre
/// `.buttonStyle(.glass)` : action secondaire (DESIGN.md), jamais
/// `.glassProminent`, réservé au bouton d'envoi. Pas de `GlassEffectContainer`
/// propre : la vue se pose dans celui de la barre de saisie, avec le champ et
/// le bouton d'envoi, ses frères de verre.
struct ResponseModeSelector: View {
    @Binding var selection: ResponseMode

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Menu {
            Picker(ResponseModeSelectorPresentation.controlTitle, selection: $selection) {
                ForEach(ResponseMode.allCases, id: \.self) { mode in
                    option(for: mode)
                        .tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel
        }
        .menuStyle(.button)
        // Ordre déclaré conservé (Rapide, Approfondie, Fiable) : par défaut,
        // iOS inverse un menu qui s'ouvre vers le haut, ce qui est le cas
        // depuis une barre de saisie en bas d'écran. Les trois modes forment
        // une gradation, ils se lisent toujours dans le même ordre.
        .menuOrder(.fixed)
        .buttonStyle(.glass)
        .accessibilityLabel(ResponseModeSelectorPresentation.controlTitle)
        .accessibilityValue(selection.title)
        .accessibilityHint(selection.explanation)
        .accessibilityIdentifier("chat.responseMode")
        #if os(macOS)
        // Seulement sur macOS : sur iOS, l'infobulle doublerait l'indice VoiceOver.
        .help(ResponseModeSelectorPresentation.helpText(for: selection))
        #endif
    }

    /// Une option du menu : titre, explication en sous-titre, symbole du mode.
    private func option(for mode: ResponseMode) -> some View {
        Label {
            Text(mode.title)
            Text(mode.explanation)
        } icon: {
            Image(systemName: mode.systemImage)
        }
    }

    /// Icône seule en largeur compacte, icône et titre ailleurs (voir
    /// `ResponseModeSelectorPresentation.showsTitle(for:)`). Le libellé
    /// VoiceOver ne dépend pas de cette variante : il est posé sur le menu.
    @ViewBuilder
    private var menuLabel: some View {
        if ResponseModeSelectorPresentation.showsTitle(for: horizontalSizeClass) {
            Label(selection.title, systemImage: selection.systemImage)
        } else {
            Label(selection.title, systemImage: selection.systemImage)
                .labelStyle(.iconOnly)
        }
    }
}

extension ResponseModeSelector {
    /// Branchement recommandé, sur le store partagé :
    /// `ResponseModeSelector(store: responseModeStore)`.
    ///
    /// Le store doit être UNE instance partagée (créée au niveau racine puis
    /// transmise), commune au chat et aux Réglages (1.15) : il ne lit
    /// `UserDefaults` qu'à son initialisation, et deux instances ne verraient
    /// pas les changements l'une de l'autre.
    init(store: ResponseModeSettingsStore) {
        self.init(selection: Bindable(store).selectedMode)
    }
}

// MARK: - Previews

#Preview("Dans la barre de saisie") {
    @Previewable @State var mode = ResponseMode.quick
    @Previewable @State var draft = ""
    GlassEffectContainer(spacing: 12) {
        HStack(spacing: 12) {
            ResponseModeSelector(selection: $mode)
            TextField("Pose ta question…", text: $draft)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            Button {} label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Envoyer")
        }
    }
    .padding(20)
}

#Preview("Chaque mode — compact puis large") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(ResponseMode.allCases, id: \.self) { mode in
            HStack(spacing: 12) {
                ResponseModeSelector(selection: .constant(mode))
                    .environment(\.horizontalSizeClass, .compact)
                ResponseModeSelector(selection: .constant(mode))
                    .environment(\.horizontalSizeClass, .regular)
            }
        }
    }
    .padding(20)
}

#Preview("Sombre") {
    @Previewable @State var mode = ResponseMode.reliable
    ResponseModeSelector(selection: $mode)
        .padding(20)
        .preferredColorScheme(.dark)
}

#Preview("Très grand texte") {
    @Previewable @State var mode = ResponseMode.deep
    ResponseModeSelector(selection: $mode)
        .padding(20)
        .dynamicTypeSize(.accessibility3)
}

/// Repli sur une valeur stockée inconnue (ancien cas « debate » du web) : le
/// store retombe sur `ResponseModeSettingsStore.defaultMode`. Cette preview
/// doit afficher Rapide (décision de Ben) ; si elle affiche Approfondie, c'est
/// `defaultMode` qui n'a pas été mis à jour, pas cette vue. La clé est recopiée
/// du store, où elle est privée. « debate » n'est écrit que dans une suite
/// dédiée, jamais dans `.standard`.
#Preview("Valeur stockée inconnue") {
    let defaults = UserDefaults(suiteName: "preview.responseModeSelector.unknownValue")
    defaults?.set("debate", forKey: "chat.responseMode.selected")
    return ResponseModeSelector(store: ResponseModeSettingsStore(userDefaults: defaults ?? .standard))
        .padding(20)
}
