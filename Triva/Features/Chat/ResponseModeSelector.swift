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

    /// Infobulle macOS : le mode actif et ce qu'il fait, avant même d'ouvrir
    /// le choix (le popover montre ensuite l'explication de chaque mode).
    static func helpText(for mode: ResponseMode) -> String {
        "\(controlTitle) : \(mode.title). \(mode.explanation)"
    }
}

// MARK: - Vue

/// Sélecteur du mode de réponse (tâche 1.13 : Rapide, Approfondie, Fiable), à
/// poser dans la barre de saisie, à côté du champ de texte.
///
/// Port du sélecteur de mode de la version web d'origine, qui
/// aligne quatre boutons-icônes dans une pilule à bordure et ne montre
/// l'explication d'un mode qu'au survol (`title=`). Le 4e mode, « Débat », est
/// hors périmètre V1 (décision de Ben) : `ResponseMode` n'en a que trois.
/// Libellés, explications et symboles viennent tous de `ResponseMode`, aucun
/// n'est réécrit ici.
///
/// ## Pourquoi un popover à nous plutôt qu'un `Menu` (mission C1)
/// Jusqu'à la mission C1, c'était un `Menu` natif. Deux défauts constatés :
/// - le verre INTERACTIF du champ voisin (DESIGN.md, « Barre de recherche »)
///   volait le toucher au menu, ouvert par-dessus ce champ : sur iPhone,
///   toucher « Fiable » ne faisait rien (QA Q1). Le champ avait dû perdre
///   `.interactive()` ;
/// - sur iOS, le menu n'affichait PAS l'explication de chaque mode en
///   sous-titre, contrairement à ce que cette doc affirmait (QA Q1, pt 13).
/// Le popover (`presentationCompactAdaptation(.popover)`, donc une bulle et
/// non une feuille même sur iPhone) se présente hors de la hiérarchie du
/// champ : le champ retrouve son verre interactif (décision de Ben,
/// 2026-11-11), et chaque option montre son titre ET son explication, sur
/// iPhone, iPad et Mac. L'état d'ouverture est connu (`isPresented`), ce qui
/// permettrait au besoin de couper l'interactivité du champ pendant le choix.
///
/// Toujours un seul bouton plutôt que trois : trois boutons en verre
/// (environ 44 pt chacun, plus deux espacements) occuperaient près d'un tiers
/// de la barre de saisie d'un iPhone, au détriment du champ de texte.
///
/// ## Aucun état persistant ici
/// La vue reçoit un `Binding`. Source de vérité UNIQUE :
/// `ResponseModeSettingsStore` (clé `chat.responseMode.selected`), branché
/// via `init(store:)`. Volontairement pas de `@AppStorage` sur cette clé :
/// il n'écrit rien tant que l'utilisateur n'a pas touché au choix, et le
/// store, qui ne lit la clé qu'à son initialisation, retomberait alors sur son
/// propre défaut. Deux défauts, deux vérités : l'interface pourrait afficher
/// « Rapide » pendant que le pipeline lance une recherche « Approfondie ».
///
/// Le défaut décidé par Ben (Rapide) et le repli d'une valeur inconnue
/// relèvent donc du store : `ResponseModeSettingsStore.defaultMode` DOIT
/// valoir `.quick`, et c'est la suite de tests du store qui le garantit.
///
/// ## Verre
/// `.buttonStyle(.glass)` : action secondaire (DESIGN.md), jamais
/// `.glassProminent`, réservé au bouton d'envoi. Pas de `GlassEffectContainer`
/// propre : la vue se pose dans celui de la barre de saisie. Le contenu du
/// popover n'a pas de verre : le popover est déjà une surface système (« jamais
/// de verre sur du texte statique »).
struct ResponseModeSelector: View {
    @Binding var selection: ResponseMode

    /// Ouverture du choix. `@State` local : rien hors de cette vue n'en a
    /// besoin tant que le verre interactif du champ ne vole pas le toucher.
    @State private var isPresented = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            buttonLabel
        }
        .buttonStyle(.glass)
        .accessibilityLabel(ResponseModeSelectorPresentation.controlTitle)
        .accessibilityValue(selection.title)
        .accessibilityHint(selection.explanation)
        .accessibilityIdentifier("chat.responseMode")
        #if os(macOS)
        // Seulement sur macOS : sur iOS, l'infobulle doublerait l'indice VoiceOver.
        .help(ResponseModeSelectorPresentation.helpText(for: selection))
        #endif
        // Le choix doit s'ouvrir VERS LE HAUT : la barre de saisie est au bas de l'écran. Les deux
        // plateformes lisent `arrowEdge` à l'inverse l'une de l'autre :
        // - macOS : bord du BOUTON où s'accroche le popover, donc `.top` ouvre vers le haut ;
        // - iOS/iPadOS (depuis 18.1, `popoverCore(arrowEdges:)` dans le swiftinterface) : bord du
        //   POPOVER qui porte la flèche, donc `.top` le plaçait SOUS le bouton. Sur iPad Pro 13 en
        //   portrait, il ne restait que 18,5 pt sous la barre : le `ScrollView` de repli a accepté
        //   cette hauteur et « Fiable » sortait de l'écran (test06 rouge, mission V, 2026-11-12).
        //   `.bottom` met la flèche en bas du popover, donc le popover au-dessus du bouton.
        .popover(isPresented: $isPresented, arrowEdge: Self.popoverArrowEdge) {
            ResponseModeChoiceList(selection: selection) { mode in
                selection = mode
                isPresented = false
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Bord de la flèche qui ouvre le choix au-dessus du bouton (voir le commentaire du `.popover`).
    #if os(macOS)
    static let popoverArrowEdge: Edge = .top
    #else
    static let popoverArrowEdge: Edge = .bottom
    #endif

    /// Icône seule en largeur compacte, icône et titre ailleurs (voir
    /// `ResponseModeSelectorPresentation.showsTitle(for:)`). Le libellé
    /// VoiceOver ne dépend pas de cette variante : il est posé sur le bouton.
    @ViewBuilder
    private var buttonLabel: some View {
        if ResponseModeSelectorPresentation.showsTitle(for: horizontalSizeClass) {
            Label(selection.title, systemImage: selection.systemImage)
        } else {
            Label(selection.title, systemImage: selection.systemImage)
                .labelStyle(.iconOnly)
        }
    }
}

/// Contenu du popover : les trois modes dans l'ordre déclaré (une gradation,
/// toujours lue dans le même sens), chacun avec son symbole, son titre et son
/// explication ; une coche sur le mode actif.
private struct ResponseModeChoiceList: View {
    let selection: ResponseMode
    let onChoose: (ResponseMode) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 320 pt d'ordinaire ; aux tailles d'accessibilité, toute la largeur que le système accorde
    /// au popover, sinon chaque explication s'étirait sur sept lignes d'un mot ou deux.
    private var idealWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 600 : 320 }

    /// Défile seulement quand les trois modes ne tiennent pas : à AX3 sur iPhone, le popover
    /// coupait le haut de « Rapide » (constaté sur capture, mission C1).
    var body: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }
        }
        .frame(idealWidth: idealWidth, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 360)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ResponseMode.allCases, id: \.self) { mode in
                row(for: mode)
            }
        }
        .padding(8)
    }

    private func row(for mode: ResponseMode) -> some View {
        Button {
            onChoose(mode)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: mode.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(mode.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if mode == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.explanation)
        .accessibilityAddTraits(mode == selection ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("chat.responseMode.\(mode.rawValue)")
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

/// Repli sur une valeur stockée inconnue (ancien cas « debate » de la version web d'origine) : le
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
