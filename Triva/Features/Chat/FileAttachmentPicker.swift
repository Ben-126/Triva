//
//  FileAttachmentPicker.swift
//  Triva
//
//  Created by ben podrojsky on 03/10/2026.
//

import QuickLook
import SwiftUI
#if os(iOS)
import PhotosUI
#endif

// MARK: - Vues

/// Bouton « trombone » de la barre de saisie (tâche 1.11), qui ouvre le
/// sélecteur de fichiers natif en sélection multiple.
/// - À poser DANS le `GlassEffectContainer` de la barre, frère du champ et du
///   bouton d'envoi. Les capsules sont une autre vue (`FileAttachmentTray`).
/// - `.fileImporter` plutôt que le `PhotosPicker` évoqué par le plan :
///   l'extracteur lit aussi le texte des images, en local (Vision, M6). La borne s'applique après le choix.
/// - Limite atteinte : le bouton reste actif et en explique la raison sous
///   les capsules ; grisé, il ne dirait rien sur iPhone.
/// - La closure de `.fileImporter`, non `@Sendable` et formée dans `body`,
///   hérite du main actor : elle se réduit à un appel synchrone.
struct FileAttachmentPicker: View {
    let controller: FileAttachmentController
    /// Brouillon du champ de saisie : l'entrée « Coller » du menu y ajoute un texte collé (iPhone, iPad, iPhone Duo).
    @Binding var draft: String
    #if os(iOS)
    @State private var photoSelection: [PhotosPickerItem] = []
    #endif

    var body: some View {
        trigger
            .buttonStyle(.glass)
            .fileImporter(
                isPresented: Bindable(controller).isPickerPresented,
                allowedContentTypes: FileAttachmentRules.allowedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                controller.handlePickerResult(result)
            }
            .fileDialogMessage(FileAttachmentPresentation.dialogMessage(remainingSlots: controller.remainingSlots))
            .fileDialogConfirmationLabel(FileAttachmentPresentation.dialogConfirmationLabel)
    }

    #if os(macOS)
    /// Mac : le bouton ouvre le panneau d'ouverture. Cmd+V colle fichiers et images (`acceptsComposerPaste`).
    private var trigger: some View {
        Button(action: controller.requestPicker) {
            Image(systemName: "paperclip")
        }
        .accessibilityLabel(FileAttachmentPresentation.pickerAccessibilityLabel)
        .accessibilityHint(FileAttachmentPresentation.pickerAccessibilityHint)
        .help(FileAttachmentPresentation.pickerHelpText)
    }
    #else
    /// iPhone, iPad, iPhone Duo : le trombone ouvre un menu (fichiers, photothèque, coller). Le sélecteur de photos
    /// est présenté par une vue à part : deux présentations de nature différente sur la même vue se gênent.
    private var trigger: some View {
        Menu {
            Button {
                controller.requestPicker()
            } label: {
                Label(FileAttachmentPresentation.attachMenuFilesTitle, systemImage: "doc")
            }
            Button {
                controller.requestPhotoPicker()
            } label: {
                Label(FileAttachmentPresentation.attachMenuPhotosTitle, systemImage: "photo.on.rectangle")
            }
            .accessibilityHint(FileAttachmentPresentation.photosAccessibilityHint)
            Button {
                Task { await controller.pasteFromClipboard(draft: $draft) }
            } label: {
                Label(FileAttachmentPresentation.attachMenuPasteTitle, systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "paperclip")
        }
        .accessibilityLabel(FileAttachmentPresentation.attachMenuAccessibilityLabel)
        .accessibilityHint(FileAttachmentPresentation.attachMenuAccessibilityHint)
        .background {
            Color.clear
                .photosPicker(
                    isPresented: Bindable(controller).isPhotoPickerPresented,
                    selection: $photoSelection,
                    maxSelectionCount: max(1, controller.remainingSlots),
                    matching: .images
                )
        }
        .onChange(of: photoSelection) { _, picked in
            guard !picked.isEmpty else { return }
            photoSelection = []
            Task { await controller.receivePhotos(picked) }
        }
    }
    #endif
}

/// Fichiers joints à la conversation et messages d'ajout (tâche 1.11).
/// - À poser AU-DESSUS de la barre de saisie, en FRÈRE de son
///   `GlassEffectContainer` : la rangée ouvre son propre conteneur, et deux
///   conteneurs imbriqués seraient faux (comme `SuggestionsView`). Aucun
///   padding horizontal ici : l'intégrateur l'aligne sur la barre.
/// - Rien ne s'affiche sans fichier, lecture ni message : un « Aucun fichier
///   joint » serait du remplissage.
/// - Les capsules RESTENT après l'envoi : chaque question suivante interroge
///   encore les pièces jointes de la conversation.
/// - iOS : défilement horizontal ; macOS : flux (`SuggestionsFlowLayout`), la
///   molette d'une souris ne faisant défiler que verticalement.
struct FileAttachmentTray: View {
    let controller: FileAttachmentController
    /// Pièce jointe montrée par Coup d'œil (Quick Look), chantier 2.2 (M5).
    @State private var previewedURL: URL?

    var body: some View {
        if !controller.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !controller.attachments.isEmpty || !controller.pendingAttachments.isEmpty {
                    capsules
                }
                ForEach(controller.notices) { notice in
                    FileAttachmentNoticeRow(notice: notice) {
                        controller.dismissNotice(id: notice.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(FileAttachmentPresentation.trayAccessibilityLabel)
            .quickLookPreview($previewedURL)
            // « Tout effacer » : l'aperçu se ferme avant que son fichier ne soit supprimé.
            .onReceive(NotificationCenter.default.publisher(for: AttachmentVaultPurgeSignal.notificationName)) { _ in
                previewedURL = nil
            }
        }
    }

    /// Un seul `GlassEffectContainer` pour toutes les capsules (DESIGN.md),
    /// espacées de 8 comme les chips de la référence.
    @ViewBuilder
    private var capsules: some View {
        #if os(macOS)
        GlassEffectContainer(spacing: 8) {
            SuggestionsFlowLayout(spacing: 8) { capsuleItems }
        }
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) { capsuleItems }
            }
        }
        #endif
    }

    @ViewBuilder
    private var capsuleItems: some View {
        ForEach(controller.attachments) { attachment in
            FileCapsule(
                fileName: attachment.fileName, kind: attachment.kind,
                note: FileAttachmentPresentation.truncationNote(for: attachment),
                canPreview: controller.storedFileURLs[attachment.id] != nil,
                onPreview: { previewedURL = controller.previewURL(for: attachment.id) }
            ) {
                controller.removeAttachment(id: attachment.id)
            }
        }
        ForEach(controller.pendingAttachments) { pending in
            FileCapsule(fileName: pending.fileName, kind: nil, note: nil, canPreview: false, onPreview: {}) {
                controller.removePendingAttachment(id: pending.id)
            }
        }
    }
}

/// Une capsule : fichier joint (`kind` connu) ou en cours de lecture (`nil`).
/// Verre teinté à l'accent une fois joint (chip, DESIGN.md), neutre pendant la
/// lecture : la teinte dit l'état, sans bordure. Pas de `.interactive()` :
/// seul le bouton de retrait répond au toucher. `truncationMode(.middle)` est
/// un filet quand le flux macOS impose une largeur ; le nom complet va à
/// VoiceOver et à l'infobulle macOS.
private struct FileCapsule: View {
    let fileName: String
    let kind: AttachmentKind?
    let note: FileAttachmentTruncationNote?
    /// Une copie du fichier existe : Coup d'œil proposé (menu contextuel, barre d'espace sur Mac).
    let canPreview: Bool
    let onPreview: () -> Void
    let onRemove: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAttached: Bool { kind != nil }

    private var accessibilityLabel: String {
        isAttached
            ? FileAttachmentPresentation.attachedAccessibilityLabel(fileName: fileName, note: note)
            : FileAttachmentPresentation.pendingAccessibilityLabel(fileName: fileName)
    }

    private var removeAccessibilityLabel: String {
        isAttached
            ? FileAttachmentPresentation.removeAccessibilityLabel(fileName: fileName)
            : FileAttachmentPresentation.cancelAccessibilityLabel(fileName: fileName)
    }

    var body: some View {
        let maxLength = FileAttachmentPresentation.maxNameLength(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        let name = FileAttachmentPresentation.shortenedName(FileAttachmentPresentation.displayName(for: fileName), maxLength: maxLength)
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: name)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(isAttached ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note {
                        Text(verbatim: note.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            SmallDismissButton(accessibilityLabel: removeAccessibilityLabel, action: onRemove)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassEffect(isAttached ? .regular.tint(.accentColor.opacity(0.15)) : .regular, in: .capsule)
        #if os(macOS)
        .help(accessibilityLabel)
        #endif
        .attachmentPreviewActions(canPreview: canPreview, onPreview: onPreview)
    }

    @ViewBuilder
    private var icon: some View {
        if let kind {
            Image(systemName: FileAttachmentPresentation.symbolName(for: kind))
                .foregroundStyle(.tint)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

/// Petit bouton « × » de retrait ou de masquage. Style `.plain` : du verre
/// dans une capsule en verre ferait du verre sur du verre. 32 pt sur iOS,
/// sous les 44 pt recommandés : compromis courant des capsules de saisie, que
/// VoiceOver atteint comme élément à part ; 24 pt sur macOS (pointeur précis).
private struct SmallDismissButton: View {
    #if os(macOS)
    private static let hitSize: CGFloat = 24
    #else
    private static let hitSize: CGFloat = 32
    #endif

    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Message sous les capsules, au style du bandeau d'erreur de `ChatView`. Pas
/// de verre : c'est du texte statique (DESIGN.md). Fichiers concernés en tête.
private struct FileAttachmentNoticeRow: View {
    let notice: FileAttachmentNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    if !notice.fileNames.isEmpty {
                        Text(verbatim: FileAttachmentPresentation.joinedFileNames(notice.fileNames))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(verbatim: notice.message)
                }
            } icon: {
                Image(systemName: notice.style == .information ? "info.circle" : "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            SmallDismissButton(accessibilityLabel: FileAttachmentPresentation.dismissNoticeLabel, action: onDismiss)
        }
    }
}
