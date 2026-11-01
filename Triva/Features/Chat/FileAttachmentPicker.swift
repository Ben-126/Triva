//
//  FileAttachmentPicker.swift
//  Triva
//
//  Created by ben podrojsky on 03/10/2026.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Règles (logique pure, testable)

/// Résultat de `FileAttachmentRules.plan` : ce qui sera lu, et ce qui ne le
/// sera pas, nommé pour être affiché (rien n'est abandonné en silence).
nonisolated struct FileAttachmentSelectionPlan: Sendable, Equatable {
    let accepted: [URL]
    let duplicateFileNames: [String]
    let overflowFileNames: [String]
}

/// Ce que le sélecteur de pièces jointes (tâche 1.11) accepte, et combien.
/// `nonisolated` : règles déterministes, sans état (comme `SuggestionsPresentation`).
nonisolated enum FileAttachmentRules {
    /// 15 pièces jointes au plus par conversation, jointes et en lecture
    /// confondues : 15 × 5 pages = le budget total de 75 pages décidé par Ben
    /// (2026-10-04). La limite de CONTENU reste le budget de 185 000 caractères
    /// du store, PARTAGÉ entre les fichiers ; celle-ci évite qu'un « Tout
    /// sélectionner » sur 200 fichiers lance 200 lectures (`.fileImporter` ne
    /// sait pas borner une sélection), et garde la rangée lisible d'un coup
    /// d'œil sur iPhone. Valeur de produit : à ajuster ici seulement.
    static let maxAttachmentCount = 15

    /// Types proposés par `.fileImporter`, DÉRIVÉS de `AttachmentKind` : le
    /// `switch` exhaustif de `contentTypes(for:)` ne compile plus si
    /// l'extracteur apprend un format que le sélecteur ne propose pas.
    static let allowedContentTypes: [UTType] = {
        var seenIdentifiers: Set<String> = []
        return AttachmentKind.allCases
            .flatMap(FileAttachmentRules.contentTypes(for:))
            .filter { seenIdentifiers.insert($0.identifier).inserted }
    }()

    /// Reflet de `AttachmentKind.init?(fileName:)`, qui fait foi :
    /// - JAMAIS `.text` : HTML, RTF et XML y sont conformes, et l'extracteur
    ///   les refuse (leur texte brut est du balisage) ;
    /// - `.json` à part : il n'est PAS conforme à `.plainText` ;
    /// - Markdown, CSV et TSV, conformes à `.plainText`, listés quand même ;
    ///   Markdown aussi par extension, même filet que l'extracteur si
    ///   l'identifiant système n'est pas déclaré.
    static func contentTypes(for kind: AttachmentKind) -> [UTType] {
        switch kind {
        case .pdf: return [.pdf]
        case .plainText: return [.plainText]
        case .markdown:
            return [UTType("net.daringfireball.markdown"), UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        case .csv: return [.commaSeparatedText, .tabSeparatedText]
        case .json: return [.json]
        }
    }

    /// Conformance à l'un des types autorisés, comme le teste le sélecteur.
    static func accepts(_ contentType: UTType) -> Bool {
        allowedContentTypes.contains { contentType.conforms(to: $0) }
    }

    /// Répartit une sélection, dans son ordre, entre fichiers à lire, doublons
    /// et excédent (au-delà de `availableSlots`). Doublon : même nom, casse
    /// ignorée, qu'un fichier joint, en lecture ou plus haut dans la sélection.
    /// Le store ne dédoublonne pas : joint deux fois, un document consommerait
    /// deux fois le budget et sortirait deux fois en source `[n]`. Le nom est
    /// le seul repère (le store ne garde pas l'URL) ; limite assumée : deux
    /// fichiers distincts de même nom ne peuvent être joints ensemble.
    static func plan(for urls: [URL], existingFileNames: [String], availableSlots: Int) -> FileAttachmentSelectionPlan {
        var seenKeys = Set(existingFileNames.map(duplicateKey(for:)))
        var accepted: [URL] = []
        var duplicates: [String] = []
        var overflow: [String] = []
        for url in urls {
            let fileName = url.lastPathComponent
            if !seenKeys.insert(duplicateKey(for: fileName)).inserted {
                duplicates.append(fileName)
            } else if accepted.count < max(0, availableSlots) {
                accepted.append(url)
            } else {
                overflow.append(fileName)
            }
        }
        return FileAttachmentSelectionPlan(accepted: accepted, duplicateFileNames: duplicates, overflowFileNames: overflow)
    }

    /// Casse ignorée, comme APFS par défaut. `String` compare déjà à
    /// équivalence canonique près (« é » composé ou décomposé), `Set` aussi.
    private static func duplicateKey(for fileName: String) -> String {
        fileName.lowercased()
    }
}

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
/// l'utilisateur est affiché, après nettoyage. `isCopyRestricted` n'est
/// jamais montré : décision de Ben, ces PDF sont lus sans message particulier.
nonisolated enum FileAttachmentPresentation {
    static let pickerAccessibilityLabel = "Joindre un fichier"
    static let pickerAccessibilityHint = "PDF, texte, Markdown, CSV ou JSON."
    static let pickerHelpText = "Joindre un fichier : PDF, texte, Markdown, CSV ou JSON"
    static let dialogConfirmationLabel = "Joindre"
    static let trayAccessibilityLabel = "Pièces jointes"
    static let dismissNoticeLabel = "Masquer ce message"
    static let pickerFailureMessage = "Impossible d'ouvrir les fichiers choisis. Réessaie."
    static let unexpectedFailureMessage = "Impossible de lire ce fichier."
    static let alreadyAttachedMessage = "Déjà joint à cette conversation."
    static let untitledFileName = "Document sans nom"

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
        return "Choisis \(count) : PDF, texte, Markdown, CSV ou JSON."
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
        case .plainText: return "doc.plaintext"
        case .markdown: return "doc.text"
        case .csv: return "tablecells"
        case .json: return "curlybraces"
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
    let id = UUID()
    let fileNames: [String]
    let message: String
}

/// Entrée de la file de lecture : l'URL n'est gardée que jusqu'à la lecture
/// (comme `AttachmentStore`, qui ne conserve aucun accès au fichier).
nonisolated private struct QueuedFile: Sendable {
    let id = UUID()
    let url: URL
    var fileName: String { url.lastPathComponent }
}

// MARK: - Contrôleur

/// État d'interface partagé par `FileAttachmentPicker` (bouton) et
/// `FileAttachmentTray` (capsules) : file des lectures et messages. Les pièces
/// jointes restent dans `AttachmentStore`, seule source de vérité, lu sans
/// copie : un `store.remove(id:)` fait ailleurs ne laisse aucune capsule fantôme.
///
/// - **Lecture SÉQUENTIELLE, obligatoire.** `AttachmentStore.attach(fileAt:)`
///   réserve `min(12 500, budget restant)` caractères dès le début d'une
///   lecture. En parallèle, le premier de trois petits fichiers réserverait
///   tout le budget et les deux autres échoueraient en « limite atteinte »,
///   alors qu'il n'en consommera que 2 000. Une seule tâche vide donc la file :
///   chaque réservation est libérée avant la lecture suivante.
/// - **Retirer un fichier pas encore joint** : sa capsule disparaît aussitôt.
///   En file, il n'est jamais lu ; en lecture, celle-ci va à son terme (1 s
///   au plus pour 500 pages) puis son résultat est écarté dans le même tour du
///   main actor que son ajout, sans jamais s'afficher. Pas d'annulation de
///   tâche : l'unique tâche vide la file, l'annuler ferait échouer la suite.
/// - **Nouvelle conversation : `removeAll()`, jamais `store.removeAll()`
///   seul.** La génération du store écarte la lecture EN COURS, pas les
///   fichiers EN FILE, qui s'attacheraient sinon à la nouvelle conversation.
/// - **Durée de vie** : reçoit le store de la conversation sans le créer ; à
///   posséder à côté du ViewModel, jamais dans le `@State` d'une vue recréable.
/// - **Annonces VoiceOver** postées ici, au moment exact de l'événement : la
///   rangée n'existe pas tant qu'elle est vide, et `onChange` ignore la valeur
///   présente à l'apparition.
@Observable
final class FileAttachmentController {
    let store: AttachmentStore
    let maxAttachmentCount: Int
    private(set) var pendingAttachments: [PendingFileAttachment] = []
    private(set) var notices: [FileAttachmentNotice] = []

    @ObservationIgnored private var queue: [QueuedFile] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var currentFileID: UUID?
    @ObservationIgnored private var discardsCurrentResult = false

    init(store: AttachmentStore, maxAttachmentCount: Int = FileAttachmentRules.maxAttachmentCount) {
        self.store = store
        self.maxAttachmentCount = max(1, maxAttachmentCount)
    }

    var attachments: [IndexedAttachment] { store.attachments }
    var remainingSlots: Int { max(0, maxAttachmentCount - store.attachments.count - pendingAttachments.count) }
    /// Budget des fichiers DÉJÀ joints, sans les réservations des lectures en
    /// cours : sinon le bouton paraîtrait bloqué pendant chaque lecture.
    var isCharacterBudgetExhausted: Bool { store.indexedCharacterCount >= store.totalCharacterBudget }
    var canAttachMore: Bool { remainingSlots > 0 && !isCharacterBudgetExhausted }
    var isEmpty: Bool { store.attachments.isEmpty && pendingAttachments.isEmpty && notices.isEmpty }

    // MARK: Actions

    /// Bouton touché alors que `canAttachMore` est faux : explique pourquoi,
    /// plutôt que d'ouvrir un sélecteur dont aucun choix n'aboutirait.
    func explainAttachmentLimit() {
        let message = remainingSlots == 0
            ? FileAttachmentPresentation.countLimitReachedMessage(limit: maxAttachmentCount)
            : AttachmentStoreError.characterBudgetExhausted.userFacingMessage
        notices = []
        show(FileAttachmentNotice(fileNames: [], message: message))
    }

    /// Résultat brut de `.fileImporter`.
    func handlePickerResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            enqueue(urls)
        case .failure(let error):
            guard !FileAttachmentPresentation.isUserCancellation(error) else { return }
            notices = []
            show(FileAttachmentNotice(fileNames: [], message: FileAttachmentPresentation.pickerFailureMessage))
        }
    }

    /// Met des fichiers en file ; les messages précédents, caducs, sont effacés.
    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let existingNames = store.attachments.map(\.fileName) + pendingAttachments.map(\.fileName)
        let plan = FileAttachmentRules.plan(for: urls, existingFileNames: existingNames, availableSlots: remainingSlots)
        let files = plan.accepted.map(QueuedFile.init(url:))
        notices = []
        if !plan.duplicateFileNames.isEmpty {
            show(FileAttachmentNotice(fileNames: plan.duplicateFileNames, message: FileAttachmentPresentation.alreadyAttachedMessage))
        }
        if !plan.overflowFileNames.isEmpty {
            show(FileAttachmentNotice(fileNames: plan.overflowFileNames, message: FileAttachmentPresentation.tooManyFilesMessage(limit: maxAttachmentCount)))
        }
        pendingAttachments += files.map { PendingFileAttachment(id: $0.id, fileName: $0.fileName) }
        queue += files
        startWorkerIfNeeded()
    }

    func removeAttachment(id: UUID) { store.remove(id: id) }
    func dismissNotice(id: UUID) { notices.removeAll { $0.id == id } }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        queue.removeAll { $0.id == id }
        if currentFileID == id { discardsCurrentResult = true }
    }

    /// À l'envoi d'une question, par exemple : ces messages sont caducs.
    func dismissAllNotices() { notices = [] }

    /// « Nouvelle conversation » : file vidée AVANT le store, pour qu'aucun
    /// fichier en attente ne démarre après coup. La lecture en cours échoue en
    /// `CancellationError` (génération du store), sans message.
    func removeAll() {
        queue.removeAll()
        pendingAttachments.removeAll()
        notices = []
        if currentFileID != nil { discardsCurrentResult = true }
        store.removeAll()
    }

    // MARK: File de lecture

    /// Tâche créée sur le main actor, dont elle hérite : les appels au store
    /// (isolé au main actor) se font sans saut d'acteur ; le travail lourd
    /// quitte le main actor dans `AttachmentPreparer` (`@concurrent`).
    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    /// Aucune suspension entre la fin de la boucle et `worker = nil` : une
    /// sélection ne peut pas s'intercaler et rester sans tâche pour la lire.
    private func drainQueue() async {
        while !queue.isEmpty {
            let file = queue.removeFirst()
            await read(file)
        }
        worker = nil
    }

    private func read(_ file: QueuedFile) async {
        currentFileID = file.id
        discardsCurrentResult = false
        defer { currentFileID = nil }
        do {
            let attachment = try await store.attach(fileAt: file.url)
            pendingAttachments.removeAll { $0.id == file.id }
            if discardsCurrentResult {
                store.remove(id: attachment.id)
            } else {
                announce(FileAttachmentPresentation.attachedAnnouncement(for: attachment))
            }
        } catch {
            pendingAttachments.removeAll { $0.id == file.id }
            handleFailure(error, for: file)
        }
    }

    /// Fichier retiré pendant sa lecture, ou conversation vidée : son échec ne
    /// concerne plus personne. Budget épuisé : les fichiers encore en file
    /// échoueraient tous à l'identique (rien ne s'exécute entre deux lectures),
    /// ils sont donc abandonnés d'un coup, sous UN seul message.
    private func handleFailure(_ error: any Error, for file: QueuedFile) {
        guard !discardsCurrentResult else { return }
        if let storeError = error as? AttachmentStoreError, storeError == .characterBudgetExhausted {
            let abandoned = queue
            let abandonedIDs = Set(abandoned.map(\.id))
            queue.removeAll()
            pendingAttachments.removeAll { abandonedIDs.contains($0.id) }
            show(FileAttachmentNotice(fileNames: [file.fileName] + abandoned.map(\.fileName), message: storeError.userFacingMessage))
        } else if let message = FileAttachmentPresentation.failureMessage(for: error) {
            show(FileAttachmentNotice(fileNames: [file.fileName], message: message))
        }
    }

    private func show(_ notice: FileAttachmentNotice) {
        notices.append(notice)
        announce(FileAttachmentPresentation.announcement(for: notice))
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

// MARK: - Vues

/// Bouton « trombone » de la barre de saisie (tâche 1.11), qui ouvre le
/// sélecteur de fichiers natif en sélection multiple.
/// - À poser DANS le `GlassEffectContainer` de la barre, frère du champ et du
///   bouton d'envoi. Les capsules sont une autre vue (`FileAttachmentTray`).
/// - `.fileImporter` plutôt que le `PhotosPicker` évoqué par le plan :
///   l'extracteur ne lit aucune image. La borne s'applique après le choix.
/// - Limite atteinte : le bouton reste actif et en explique la raison sous
///   les capsules ; grisé, il ne dirait rien sur iPhone.
/// - La closure de `.fileImporter`, non `@Sendable` et formée dans `body`,
///   hérite du main actor : elle se réduit à un appel synchrone.
struct FileAttachmentPicker: View {
    let controller: FileAttachmentController
    @State private var isImporterPresented = false

    var body: some View {
        Button(action: openImporter) {
            Image(systemName: "paperclip")
        }
        .buttonStyle(.glass)
        .accessibilityLabel(FileAttachmentPresentation.pickerAccessibilityLabel)
        .accessibilityHint(FileAttachmentPresentation.pickerAccessibilityHint)
        #if os(macOS)
        .help(FileAttachmentPresentation.pickerHelpText)
        #endif
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: FileAttachmentRules.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            controller.handlePickerResult(result)
        }
        .fileDialogMessage(FileAttachmentPresentation.dialogMessage(remainingSlots: controller.remainingSlots))
        .fileDialogConfirmationLabel(FileAttachmentPresentation.dialogConfirmationLabel)
    }

    private func openImporter() {
        if controller.canAttachMore {
            isImporterPresented = true
        } else {
            controller.explainAttachmentLimit()
        }
    }
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
            FileCapsule(fileName: attachment.fileName, kind: attachment.kind, note: FileAttachmentPresentation.truncationNote(for: attachment)) {
                controller.removeAttachment(id: attachment.id)
            }
        }
        ForEach(controller.pendingAttachments) { pending in
            FileCapsule(fileName: pending.fileName, kind: nil, note: nil) {
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
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            SmallDismissButton(accessibilityLabel: FileAttachmentPresentation.dismissNoticeLabel, action: onDismiss)
        }
    }
}

// MARK: - Previews

/// Préparation factice, sans vrai fichier, pilotée par le nom : `lent…` reste
/// en lecture (et retient la file derrière lui), `scan…` est un PDF sans
/// texte, un type inconnu est refusé, `rapport…` est tronqué.
nonisolated private struct PreviewAttachmentPreparer: AttachmentPreparing {
    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        let fileName = url.lastPathComponent
        if fileName.hasPrefix("lent") { try await Task.sleep(for: .seconds(3_600)) }
        if fileName.hasPrefix("scan") { throw AttachmentExtractionError.noExtractableText(pageCount: 12) }
        guard let kind = AttachmentKind(fileName: fileName) else {
            throw AttachmentExtractionError.unsupportedFileType(fileExtension: url.pathExtension.lowercased())
        }
        let isTruncated = fileName.hasPrefix("rapport")
        let isPDF = kind == .pdf
        let chunk = AttachmentChunk(index: 0, text: "Extrait factice.", pageRange: isPDF ? 1...(isTruncated ? 16 : 4) : nil)
        return IndexedAttachment(
            fileName: fileName, kind: kind, pageCount: isPDF ? (isTruncated ? 120 : 4) : nil,
            characterCount: min(characterLimit, isTruncated ? 40_000 : 3_000),
            isTruncated: isTruncated, isCopyRestricted: false, chunks: [chunk]
        )
    }
}

private func previewController(selecting fileNames: [String] = []) -> FileAttachmentController {
    let controller = FileAttachmentController(store: AttachmentStore(preparer: PreviewAttachmentPreparer()))
    controller.enqueue(fileNames.map { URL(fileURLWithPath: "/Previews/\($0)") })
    return controller
}

/// Barre de saisie factice, au placement attendu : la rangée en frère
/// au-dessus, le bouton dans le conteneur de verre de la barre.
private struct PreviewComposer: View {
    let controller: FileAttachmentController
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FileAttachmentTray(controller: controller)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    FileAttachmentPicker(controller: controller)
                    TextField("Pose ta question…", text: $draft)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                    Button {} label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("Envoyer")
                }
            }
        }
        .padding(20)
    }
}

#Preview("Vide") {
    PreviewComposer(controller: previewController())
}

/// PDF lu jusqu'à la page 16 sur 120 ; le dernier fichier reste en lecture.
#Preview("Joints, PDF tronqué, lecture en cours") {
    PreviewComposer(controller: previewController(selecting: [
        "notes de cours.md", "donnees.csv", "rapport-annuel-2025-version-definitive-relue.pdf", "lent-cours-histoire.pdf",
    ]))
}

/// Sept fichiers pour cinq places : deux refusés pour la limite, un PDF
/// scanné et un type non pris en charge en échec.
#Preview("Erreurs et limite") {
    PreviewComposer(controller: previewController(selecting: [
        "scan-contrat.pdf", "lettre.docx", "a.txt", "b.txt", "c.txt", "d.txt", "e.txt",
    ]))
}

#Preview("Sombre, très grand texte") {
    PreviewComposer(controller: previewController(selecting: ["notes.md", "rapport-annuel-2025-version-definitive.pdf"]))
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
