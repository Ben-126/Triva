//
//  AttachmentTextExtractor+Docx.swift
//  Triva
//
//  Mission W : le .docx dans l'extracteur de pièces jointes. Toute la lecture est dans `DocxTextReader` ; ici seulement
//  la mise en forme du résultat (une section, sans pagination : un .docx n'a pas de pages avant mise en page).
//

import Foundation

nonisolated extension AttachmentTextExtractor {
    func extractDocx(fileAt url: URL, fileName: String, characterLimit: Int) throws -> ExtractedAttachment {
        extracted(from: try docxReader.read(fileAt: url, characterLimit: characterLimit), fileName: fileName)
    }

    func extractDocx(data: Data, fileName: String, characterLimit: Int) throws -> ExtractedAttachment {
        extracted(from: try docxReader.read(data: data, characterLimit: characterLimit), fileName: fileName)
    }

    private func extracted(from content: DocxContent, fileName: String) -> ExtractedAttachment {
        ExtractedAttachment(
            fileName: fileName,
            kind: .docx,
            sections: [ExtractedTextSection(pageNumber: nil, text: content.text)],
            pageCount: nil,
            isTruncated: content.isTruncated,
            isCopyRestricted: false,
            textEncoding: nil
        )
    }
}
