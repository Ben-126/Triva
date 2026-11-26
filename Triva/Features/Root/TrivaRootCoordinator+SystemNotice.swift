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

    /// F3 : la boîte de partage garde 10 partages ; les plus anciens ont été retirés (« à valider par Ben »).
    static func sharesDropped(count: Int) -> String {
        count == 1
            ? "1 partage plus ancien n'a pas pu être gardé."
            : "\(count) partages plus anciens n'ont pas pu être gardés."
    }
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
        case .sharesDropped(let count):
            controller.reportInformation(SystemNoticeMessages.sharesDropped(count: count))
        }
        return .noticeShown
    }
}
