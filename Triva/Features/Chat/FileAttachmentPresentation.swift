//
//  FileAttachmentPresentation.swift
//  Triva
//
//  Découpé de FileAttachmentPicker.swift (K2, 25/11/2026) : déplacement pur, sans changement de code.
//

import Foundation

// MARK: - Présentation (logique pure, testable)

/// Note honnête d'une pièce jointe dont seul le début sera utilisé : ligne
/// courte pour la capsule, phrase complète pour VoiceOver et l'infobulle.
nonisolated struct FileAttachmentTruncationNote: Sendable, Equatable {
    let summary: String
    let detail: String
}

/// Textes de la rangée de pièces jointes. Messages FERMÉS : aucun ne recopie
/// `localizedDescription` ni le contenu d'un fichier (même principe que
/// `ChatViewModel.userFacingMessage(for:)`) ; seul le NOM choisi par
/// l'utilisateur est affiché, après nettoyage. Un PDF qui interdit la
/// copie ET l'extraction pour l'accessibilité est refusé avec `PDFCopyPolicy.refusalMessage`
/// (décision de Ben, 2026-11-17) ; les autres PDF à copie interdite sont lus sans message.
nonisolated enum FileAttachmentPresentation {
    static let pickerAccessibilityLabel = "Joindre un fichier"
    static let pickerAccessibilityHint = "PDF, Word, image, texte, Markdown, CSV ou JSON."
    static let pickerHelpText = "Joindre un fichier : PDF, Word, image, texte, Markdown, CSV ou JSON"
    static let dialogConfirmationLabel = "Joindre"
    static let trayAccessibilityLabel = "Pièces jointes"
    static let dismissNoticeLabel = "Masquer ce message"
    static let pickerFailureMessage = "Impossible d'ouvrir les fichiers choisis. Réessaie."
    static let unexpectedFailureMessage = "Impossible de lire ce fichier."
    static let alreadyAttachedMessage = "Déjà joint à cette conversation."
    static let untitledFileName = "Document sans nom"
    /// Menu du trombone (iPhone, iPad, iPhone Duo) : une entrée par provenance (textes à valider par Ben).
    static let attachMenuFilesTitle = "Fichiers…"
    static let attachMenuPhotosTitle = "Photothèque…"
    static let attachMenuPasteTitle = "Coller"
    static let attachMenuAccessibilityLabel = "Joindre"
    static let attachMenuAccessibilityHint = "Fichiers, photos ou contenu copié."
    static let photosAccessibilityHint = "Le texte de l'image est lu sur l'appareil ; l'image n'est jamais envoyée."
    /// Presse-papiers vide ou sans rien que Triva sache lire (à valider par Ben).
    static let nothingToPasteMessage = "Rien à coller : le presse-papiers est vide."
    /// Texte externe (Services, dépôt) coupé à la limite : information discrète (à valider par Ben).
    static func truncatedTextMessage(limit: Int) -> String {
        "Texte coupé aux \(limit) premiers caractères."
    }

    /// Nom de capsule borné en caractères plutôt que par `.frame(maxWidth:)` :
    /// un `ScrollView` horizontal ne propose aucune largeur, le texte
    /// déborderait au lieu de se tronquer. 24 laissent voir une capsule et
    /// demie sur iPhone (signe qu'il y en a d'autres), 16 aux tailles
    /// d'accessibilité.
    static func maxNameLength(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 16 : 24
    }

    /// Message du panneau d'ouverture (affiché par macOS, ignoré ailleurs).
    static func dialogMessage(remainingSlots: Int) -> String {
        let slots = max(1, remainingSlots)
        let count = slots == 1 ? "un document" : "jusqu'à \(slots) documents"
        return "Choisis \(count) : PDF, Word, image, texte, Markdown, CSV ou JSON."
    }

    /// Sans accord en nombre : la ligne au-dessus nomme le ou les fichiers.
    static func tooManyFilesMessage(limit: Int) -> String {
        "Limite de \(limit) fichiers par conversation atteinte."
    }

    static func countLimitReachedMessage(limit: Int) -> String {
        "Tu as déjà joint \(limit) fichiers, le maximum pour une conversation. Retire-en un pour en ajouter un autre."
    }

    /// `nil` pour `CancellationError` (fichier retiré ou conversation vidée :
    /// pas un échec), texte fixe pour toute erreur inattendue.
    static func failureMessage(for error: any Error) -> String? {
        switch error {
        case is CancellationError: return nil
        case let extractionError as AttachmentExtractionError: return extractionError.userFacingMessage
        case let storeError as AttachmentStoreError: return storeError.userFacingMessage
        default: return unexpectedFailureMessage
        }
    }

    /// Fermer le sélecteur sans rien choisir n'est pas une erreur.
    static func isUserCancellation(_ error: any Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    /// Marques bidirectionnelles (implicites, plongements, forçages, isolats) :
    /// elles affichent un nom dans un ordre trompeur, « rapport[U+202E]fdp.exe »
    /// se lisant « rapportexe.pdf ».
    private static let bidirectionalControlValues: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ]
    private static let lineBreakingCategories: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]

    /// Nom sur UNE ligne : contrôles et sauts de ligne (un nom macOS peut en
    /// contenir) remplacés par une espace, marques bidirectionnelles retirées,
    /// blancs fusionnés. Le type vient toujours de l'extension réelle, jamais
    /// de ce nom nettoyé.
    static func displayName(for fileName: String) -> String {
        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        for scalar in fileName.unicodeScalars where !bidirectionalControlValues.contains(scalar.value) {
            scalars.append(lineBreakingCategories.contains(scalar.properties.generalCategory) ? space : scalar)
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? untitledFileName : collapsed
    }

    /// Raccourcit au MILIEU, extension visible : « rapport-annue…-relue.pdf ».
    /// La fin de la base est gardée (un tiers de la place) : c'est souvent là
    /// que deux versions se distinguent (« …v2 »). Compte en `Character`, donc
    /// jamais d'accent coupé en deux. Extension ignorée au-delà de 8 caractères.
    static func shortenedName(_ name: String, maxLength: Int) -> String {
        let limit = max(8, maxLength)
        guard name.count > limit else { return name }
        let fileExtension = (name as NSString).pathExtension
        let keepsExtension = !fileExtension.isEmpty && fileExtension.count <= 8 && name.count > fileExtension.count + 1
        let suffix = keepsExtension ? "." + fileExtension : ""
        let stem = keepsExtension ? String(name.dropLast(fileExtension.count + 1)) : name
        let available = max(2, limit - suffix.count - 1)
        let tailCount = available / 3
        return String(stem.prefix(available - tailCount)) + "…" + String(stem.suffix(tailCount)) + suffix
    }

    /// Symbole sobre par format ; l'extension reste lisible dans le nom.
    static func symbolName(for kind: AttachmentKind) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .docx: return "text.document"
        case .plainText: return "doc.plaintext"
        case .markdown: return "doc.text"
        case .csv: return "tablecells"
        case .json: return "curlybraces"
        case .image: return "photo"
        }
    }

    /// Note CALCULÉE sur ce qui a réellement été lu, jamais « les 32
    /// premières pages » en dur : le budget de 185 000 caractères est PARTAGÉ
    /// par la conversation, un PDF joint après d'autres fichiers peut s'arrêter
    /// page 4. Dernière page lue = plus haute borne des fragments.
    static func truncationNote(for attachment: IndexedAttachment) -> FileAttachmentTruncationNote? {
        guard attachment.isTruncated else { return nil }
        guard attachment.kind == .pdf else {
            return FileAttachmentTruncationNote(summary: "Début du fichier seulement", detail: "Seul le début de ce fichier sera utilisé pour répondre.")
        }
        let lastReadPage = attachment.chunks.compactMap { $0.pageRange?.upperBound }.max()
        guard let pageCount = attachment.pageCount, let lastReadPage else {
            return FileAttachmentTruncationNote(summary: "Début du document seulement", detail: "Seul le début de ce document sera utilisé pour répondre.")
        }
        // Coupé au milieu de sa dernière page : seule la fin manque.
        guard lastReadPage < pageCount else {
            return FileAttachmentTruncationNote(summary: "Fin du document non lue", detail: "La fin de ce document ne sera pas utilisée pour répondre.")
        }
        guard lastReadPage > 1 else {
            return FileAttachmentTruncationNote(summary: "Page 1 sur \(pageCount) seulement", detail: "Seule la première page sur \(pageCount) sera utilisée pour répondre.")
        }
        return FileAttachmentTruncationNote(
            summary: "Pages 1 à \(lastReadPage) sur \(pageCount) seulement",
            detail: "Seules les pages 1 à \(lastReadPage) sur \(pageCount) seront utilisées pour répondre."
        )
    }

    static func joinedFileNames(_ fileNames: [String]) -> String {
        fileNames.map(displayName(for:)).joined(separator: ", ")
    }

    /// Capsule jointe (VoiceOver, infobulle macOS) : le nom, puis la troncature.
    static func attachedAccessibilityLabel(fileName: String, note: FileAttachmentTruncationNote?) -> String {
        displayName(for: fileName) + (note.map { ". \($0.detail)" } ?? "")
    }

    static func attachedAnnouncement(for attachment: IndexedAttachment) -> String {
        let detail = truncationNote(for: attachment).map { " \($0.detail)" } ?? ""
        return "\(displayName(for: attachment.fileName)) joint.\(detail)"
    }

    static func pendingAccessibilityLabel(fileName: String) -> String { "\(displayName(for: fileName)), lecture en cours" }
    static func removeAccessibilityLabel(fileName: String) -> String { "Retirer \(displayName(for: fileName))" }
    static func cancelAccessibilityLabel(fileName: String) -> String { "Annuler l'ajout de \(displayName(for: fileName))" }

    static func announcement(for notice: FileAttachmentNotice) -> String {
        notice.fileNames.isEmpty ? notice.message : "\(joinedFileNames(notice.fileNames)). \(notice.message)"
    }
}

// MARK: - Modèles d'affichage

/// Fichier choisi dont la lecture n'est pas terminée.
nonisolated struct PendingFileAttachment: Sendable, Equatable, Identifiable {
    let id: UUID
    let fileName: String
}

/// Message sous les capsules : fichiers concernés (aucun pour un échec du
/// sélecteur lui-même) et texte fermé.
nonisolated struct FileAttachmentNotice: Sendable, Equatable, Identifiable {
    /// Avertissement (refus, échec) ou simple information (texte coupé : rien n'a échoué), montrée plus discrètement.
    enum Style: Sendable, Equatable {
        case warning
        case information
    }

    let id = UUID()
    let fileNames: [String]
    let message: String
    var style: Style = .warning
}
