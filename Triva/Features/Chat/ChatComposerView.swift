//
//  ChatComposerView.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

// MARK: - Présentation (logique pure, testable)

/// Règles de la barre de saisie, isolées de la vue pour être testées sans interface.
nonisolated enum ChatComposerPresentation {

    /// Nombre de lignes du champ aux tailles d'accessibilité : assez pour relire une question
    /// longue à AX3 sans que la barre ne mange le fil (au-delà, le champ défile).
    static let accessibilityLineLimit = 1...4

    /// Le champ passe-t-il seul sur sa propre ligne, boutons en dessous ?
    ///
    /// Oui aux tailles d'accessibilité (AX1 à AX5) : entre trombone, mode et envoi agrandis,
    /// le champ tombait à environ 85 pt utiles sur un iPhone de 402 pt, et le placeholder
    /// « Pose ta qu… » rapetissait alors que tout le reste grossissait (QA Q3, finding 3).
    /// Taille de texte et non largeur d'écran : c'est le texte qui grossit, pas l'écran
    /// qui rétrécit.
    ///
    /// Sauf quand la HAUTEUR est compacte (iPhone en paysage) : la largeur ne manque plus
    /// (≈ 870 pt), c'est la hauteur, et deux rangées plus le clavier ne laissaient au champ que
    /// 5 pt, bouton d'envoi caché sous le clavier (constaté à AX3 en paysage, test03).
    static func stacksField(isAccessibilitySize: Bool, isVerticallyCompact: Bool = false) -> Bool {
        isAccessibilitySize && !isVerticallyCompact
    }

    /// Le texte qu'un Retour vient d'envoyer, s'il y en a un.
    ///
    /// Aux tailles d'accessibilité, le champ est multiligne (`axis: .vertical`), et un champ
    /// multiligne insère un saut de ligne au lieu d'appeler `onSubmit`. Pour garder « Retour
    /// envoie » partout, on reconnaît la frappe d'un Retour : le nouveau texte est l'ancien
    /// plus un seul `\n` en fin. Un collage de plusieurs lignes ne ressemble pas à ça, il
    /// n'envoie donc rien. Renvoie le texte sans ce saut de ligne, ou `nil`.
    static func submittedText(old: String, new: String) -> String? {
        guard new.count == old.count + 1, new.hasSuffix("\n"), new.dropLast() == old[...] else {
            return nil
        }
        return old
    }
}

// MARK: - Moteur IA dans la barre

/// Badge moteur (icône seule) et « Changer de moteur », posés en tête de la barre de saisie quand
/// la hauteur ne laisse plus de place à une rangée d'en-tête (`EngineHeaderLayout.badgeIsIconOnly` :
/// iPhone en paysage, AX3 et plus, clavier ouvert). La largeur, elle, ne manque pas. Le badge
/// garde son libellé d'accessibilité complet et ses identifiants, le bouton aussi.
struct ComposerEngineAccessory {
    let icon: String
    let text: String
    let onChangeEngine: () -> Void
}

// MARK: - Vue

/// Barre de saisie du chat : fichiers joints au-dessus (`FileAttachmentTray`, frère du
/// conteneur : il ouvre le sien), puis trombone, mode de réponse, champ, envoi.
///
/// Sortie de `ChatView.swift` (mission C1), qui frôlait la limite de 800 lignes.
/// L'état (brouillon, `Task` d'envoi, focus) reste dans `ChatView` : il sert aussi au fil
/// (suggestions, relance, toucher qui ferme le clavier). Cette vue ne fait que l'afficher.
///
/// Trombone et mode en `.glass` (actions secondaires), envoi seul en `.glassProminent`
/// (DESIGN.md). Un seul `GlassEffectContainer` pour ces frères de verre. Le champ porte le
/// verre INTERACTIF que prescrit DESIGN.md (« Barre de recherche ») : le choix du mode est un
/// popover présenté hors de cette hiérarchie, il ne se fait plus voler ses touchers (voir
/// `ResponseModeSelector`). Décision de Ben, 2026-11-11.
struct ChatComposerView: View {
    let attachmentController: FileAttachmentController
    let responseModeStore: ResponseModeSettingsStore
    @Binding var draft: String
    var isDraftFocused: FocusState<Bool>.Binding
    let isGenerating: Bool
    let isSendDisabled: Bool
    let contentMaxWidth: CGFloat?
    let onSend: () -> Void
    let onStop: () -> Void
    /// Non `nil` : la rangée moteur de l'en-tête vit ici (voir `ComposerEngineAccessory`).
    var engineAccessory: ComposerEngineAccessory?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var stacksField: Bool {
        #if os(iOS)
        let isVerticallyCompact = verticalSizeClass == .compact
        #else
        let isVerticallyCompact = false
        #endif
        return ChatComposerPresentation.stacksField(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            isVerticallyCompact: isVerticallyCompact
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !attachmentController.isEmpty {
                FileAttachmentTray(controller: attachmentController)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            GlassEffectContainer(spacing: 12) {
                bar
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        if stacksField {
            VStack(spacing: 12) {
                field
                HStack(spacing: 12) {
                    secondaryActions
                    Spacer(minLength: 0)
                    sendButton
                }
            }
        } else {
            HStack(spacing: 12) {
                engineControls
                secondaryActions
                field
                sendButton
            }
        }
    }

    @ViewBuilder
    private var engineControls: some View {
        if let engineAccessory {
            EngineBadge(
                badge: (engineAccessory.icon, engineAccessory.text, ""),
                showsCaption: false,
                badgeIdentifier: "search.engineBadge",
                iconOnly: true
            )
            Button("Changer de moteur", systemImage: "arrow.triangle.2.circlepath", action: engineAccessory.onChangeEngine)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .accessibilityIdentifier("search.changeEngine")
        }
    }

    /// Le contrôleur du ViewModel, jamais un `@State` d'ici : ses fichiers n'atteindraient pas
    /// le pipeline.
    @ViewBuilder
    private var secondaryActions: some View {
        FileAttachmentPicker(controller: attachmentController)
        ResponseModeSelector(store: responseModeStore)
    }

    /// `.textFieldStyle(.plain)` : sur Mac, le style par défaut dessinait un champ arrondi
    /// système à l'intérieur de la forme de verre, un double contour (QA Q3, finding 24).
    /// Sans effet visible sur iOS.
    @ViewBuilder
    private var field: some View {
        Group {
            if stacksField {
                TextField("Pose ta question…", text: $draft, axis: .vertical)
                    .lineLimit(ChatComposerPresentation.accessibilityLineLimit)
                    .onChange(of: draft) { oldValue, newValue in
                        guard let submitted = ChatComposerPresentation.submittedText(old: oldValue, new: newValue) else { return }
                        draft = submitted
                        // Un champ d'une ligne rend le focus quand on valide avec Retour, et le
                        // clavier se range. Le champ multiligne ne le fait pas : sans cette ligne,
                        // le clavier restait ouvert après chaque envoi à AX3 et cachait la barre
                        // d'onglets (constaté sur iPhone 18 Pro, test03).
                        isDraftFocused.wrappedValue = false
                        onSend()
                    }
            } else {
                TextField("Pose ta question…", text: $draft)
            }
        }
        .textFieldStyle(.plain)
        .focused(isDraftFocused)
        .onSubmit(onSend)
        .accessibilityIdentifier("chat.input")
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }

    private var sendButton: some View {
        Button {
            // Affordance d'annulation : sans elle, une génération qui ne répond plus (ex.
            // connexion BYOK qui pend) tourne jusqu'au timeout réseau par défaut.
            if isGenerating { onStop() } else { onSend() }
        } label: {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
        }
        .buttonStyle(.glassProminent)
        .disabled(isGenerating ? false : isSendDisabled)
        .accessibilityLabel(isGenerating ? "Arrêter la génération" : "Envoyer")
        .accessibilityIdentifier("chat.send")
        // Échap arrête la génération (clavier matériel, Mac et iPad) ; rien le reste du temps,
        // pour ne jamais envoyer par accident.
        .keyboardShortcut(isGenerating ? KeyboardShortcut.cancelAction : nil)
    }
}

// MARK: - Previews

private struct ChatComposerPreviewHost: View {
    @State private var draft = ""
    @FocusState private var focused: Bool
    private let controller = FileAttachmentController(store: AttachmentStore())

    var body: some View {
        VStack {
            Spacer()
            ChatComposerView(
                attachmentController: controller,
                responseModeStore: ResponseModeSettingsStore(),
                draft: $draft,
                isDraftFocused: $focused,
                isGenerating: false,
                isSendDisabled: draft.isEmpty,
                contentMaxWidth: nil,
                onSend: {},
                onStop: {}
            )
        }
    }
}

#Preview("Barre de saisie") {
    ChatComposerPreviewHost()
}

#Preview("Barre de saisie — AX3") {
    ChatComposerPreviewHost()
        .dynamicTypeSize(.accessibility3)
}
