//
//  ShareViewController.swift
//  TrivaShare
//
//  Chantier 2.1 (S1) : extension de partage minimale, iPhone et iPad. Elle se contente de se fermer ;
//  la feuille « Rechercher avec Triva » arrive avec la mission E.
//

import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
