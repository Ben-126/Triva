//
//  ShareComposerModel.swift
//  TrivaShared
//
//  Chantier 2.1 (mission E) : le modèle de la feuille « Rechercher avec Triva ». Placé dans `TrivaShared` pour être
//  TESTÉ (la vue de l'extension reste mince). Il lit le partage, propose la question, puis écrit dans la boîte de
//  l'App Group au bouton « Envoyer à Triva ». Rien ne part ailleurs : l'extension ne fait pas de réseau, ne lance
//  aucune recherche, et ne peut pas ouvrir l'app (limite Apple) : c'est l'app qui vient chercher (mission E, consommateur).
//

import Foundation
import Observation

/// Les textes de la feuille (à valider par Ben). Le premier et le dernier de la confirmation viennent de la spec 2.1 §4.6.
nonisolated enum ShareMessages {
    static let unreadable = "Triva n'a pas pu lire ce contenu."
    static let unsupportedFile = "Triva ne lit pas ce type de fichier."
    static let tooLarge = "Ce fichier est trop volumineux pour être joint."
    static let cannotSave = "Triva n'a pas pu recevoir ce contenu. Ouvre Triva une fois, puis réessaie."

    static func confirmation(hasFile: Bool, hasQuestion: Bool) -> String {
        switch (hasFile, hasQuestion) {
        case (false, _): "C'est prêt. Ouvre Triva : ta question t'attend dans la barre de saisie."
        case (true, false): "C'est prêt. Ouvre Triva : ton fichier t'attend dans la barre de saisie."
        case (true, true): "C'est prêt. Ouvre Triva : ton fichier et ta question t'attendent dans la barre de saisie."
        }
    }

    static func message(for error: ShareReadError) -> String {
        switch error {
        case .nothingReadable: unreadable
        case .unsupportedFile: unsupportedFile
        case .tooLarge: tooLarge
        }
    }
}

@MainActor
@Observable
final class ShareComposerModel {
    enum Phase: Equatable {
        case loading
        case ready
        case saving
        /// Écrit dans la boîte ; le texte est la confirmation à afficher.
        case done(String)
        case failed(String)
    }

    /// La question, modifiable. Préremplie par le partage (texte tel quel, titre de la page, sinon son adresse).
    var question: String = ""
    private(set) var phase: Phase = .loading
    /// Le fichier partagé (PDF ou image), copié dans le dossier de travail de l'extension.
    private(set) var file: StagedShareFile?

    @ObservationIgnored private let items: [NSExtensionItem]
    @ObservationIgnored private let stagingDirectory: URL
    @ObservationIgnored private let inbox: () -> SharedInbox?

    /// - Parameter inbox: fabrique de la boîte de l'App Group (`nil` : groupe indisponible).
    init(items: [NSExtensionItem], stagingDirectory: URL, inbox: @escaping () -> SharedInbox?) {
        self.items = items
        self.stagingDirectory = stagingDirectory
        self.inbox = inbox
    }

    /// Un fichier suffit (la question est alors facultative) ; sinon il faut une question lisible.
    var canSend: Bool {
        guard phase == .ready else { return false }
        return file != nil || ExternalQuerySanitizer.sanitize(question) != nil
    }

    // MARK: - Actions

    func load() async {
        do {
            let content = try await ShareItemReader.read(items, stagingDirectory: stagingDirectory)
            if case .file(let staged) = content { file = staged }
            question = content.suggestedQuestion ?? ""
            phase = .ready
        } catch let error as ShareReadError {
            ShareItemReader.clearStaging(at: stagingDirectory)
            phase = .failed(ShareMessages.message(for: error))
        } catch {
            ShareItemReader.clearStaging(at: stagingDirectory)
            phase = .failed(ShareMessages.unreadable)
        }
    }

    /// « Envoyer à Triva » : écrit dans la boîte. Sans effet si une écriture est déjà en cours ou terminée.
    ///
    /// La copie d'un gros PDF se fait HORS du thread principal : la feuille affiche son état « en cours » au lieu de se figer.
    func send() async {
        guard canSend else { return }
        phase = .saving
        defer { ShareItemReader.clearStaging(at: stagingDirectory) }
        guard let inbox = inbox() else {
            phase = .failed(ShareMessages.cannotSave)
            return
        }
        do {
            let entry = try await Self.write(to: inbox, text: question, fileAt: file?.url, displayName: file?.displayName)
            // Prévient l'app si elle est déjà au premier plan (sinon elle reprendra au prochain passage).
            ShareInboxSignal.post()
            phase = .done(ShareMessages.confirmation(hasFile: entry.file != nil, hasQuestion: entry.text != nil))
        } catch SharedInbox.Failure.tooLarge {
            phase = .failed(ShareMessages.tooLarge)
        } catch SharedInbox.Failure.unsupportedFile {
            phase = .failed(ShareMessages.unsupportedFile)
        } catch {
            phase = .failed(ShareMessages.cannotSave)
        }
    }

    @concurrent
    private static func write(to inbox: SharedInbox, text: String, fileAt source: URL?, displayName: String?) async throws -> SharedInboxEntry {
        try inbox.add(text: text, fileAt: source, displayName: displayName)
    }

    /// « Annuler » : rien n'est gardé, le dossier de travail est effacé.
    func cancel() {
        ShareItemReader.clearStaging(at: stagingDirectory)
    }

    /// Fin de la feuille (après la confirmation) : même nettoyage, par prudence.
    func finish() {
        ShareItemReader.clearStaging(at: stagingDirectory)
    }
}
