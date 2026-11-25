//
//  FileAttachmentPreviews.swift
//  Triva
//
//  Découpé de FileAttachmentPicker.swift (K2, 25/11/2026) : déplacement pur, sans changement de code.
//

import SwiftUI

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
                    FileAttachmentPicker(controller: controller, draft: $draft)
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
