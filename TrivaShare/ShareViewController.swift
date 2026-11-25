//
//  ShareViewController.swift
//  TrivaShare
//
//  Chantier 2.1 (mission E) : extension de partage « Rechercher avec Triva » (iPhone et iPad). Elle héberge une petite
//  feuille SwiftUI (`ShareComposerView`). Toute la logique est dans `ShareComposerModel` (TrivaShared, testé).
//
//  Une extension de partage ne peut PAS ouvrir l'app (limite Apple, `NSExtensionContext.open` n'existe que pour
//  Today et iMessage) : elle dépose le partage dans l'App Group, et l'app vient le chercher à son prochain passage au
//  premier plan. Aucun réseau, aucune recherche, aucun envoi d'ici.
//

import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private var model: ShareComposerModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let stagingRoot = FileManager.default.temporaryDirectory
            .appending(path: "TrivaShareStaging", directoryHint: .isDirectory)
        // Ce qu'un partage précédent a laissé (feuille balayée, extension tuée) part avant d'en créer un nouveau.
        ShareItemReader.purgeStaleStaging(in: stagingRoot)
        let staging = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let model = ShareComposerModel(items: items, stagingDirectory: staging, inbox: { SharedInbox.live() })
        self.model = model

        let host = UIHostingController(
            rootView: ShareComposerView(
                model: model,
                onCancel: { [weak self] in self?.cancel() },
                onDone: { [weak self] in self?.complete() }
            )
        )
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Feuille balayée : le dossier de travail ne reste pas.
        model?.finish()
    }

    private func cancel() {
        model?.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func complete() {
        model?.finish()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
