//
//  TrivaRootCoordinator+SystemNotice.swift
//  Triva
//
//  Mission X1 : les informations que le partage fait afficher sous les capsules de la fenêtre (texte coupé aux 2 000
//  premiers caractères, fichier qui n'a pas pu être copié). Une information n'ouvre rien et n'envoie rien.
//

import Foundation

/// Textes des informations du partage (« à valider par Ben »).
nonisolated enum SystemNoticeMessages {
    static let fileNotCopied = "Le fichier partagé n'a pas pu être copié dans Triva (place insuffisante ?). Partage-le de nouveau."
}

extension TrivaRootCoordinator {
    func applyNotice(_ notice: SystemNotice) -> SystemRouteOutcome {
        selection = .search
        session.ensureChatViewModel()
        guard let controller = session.chatViewModel?.attachmentController else { return .ignored }
        switch notice {
        case .truncatedText:
            controller.reportTruncatedText()
        case .fileNotCopied:
            controller.reportRefusal(SystemNoticeMessages.fileNotCopied)
        }
        return .noticeShown
    }
}
