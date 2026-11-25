//
//  ComposerPaste.swift
//  Triva
//
//  K2 : coller une image ou un fichier dans le chat.
//  - Mac : Cmd+V. Le champ de saisie (NSTextView) prendrait seul le collage et, pour un fichier copié dans le Finder,
//    collerait son NOM en texte. Un moniteur d'événements local, borné à la fenêtre de ce champ, intercepte donc
//    Cmd+V UNIQUEMENT si `PasteboardClassifier` dit « fichier » ou « image » ; dans tous les autres cas l'événement
//    est rendu intact et le champ colle son texte normalement.
//  - iPhone, iPad : `pasteDestination` sur le champ (Cmd+V du clavier matériel de l'iPad, menu Coller du champ). UIKit
//    ne l'interroge que si le champ ne sait pas coller ce que contient le presse-papiers : un presse-papiers texte colle
//    donc toujours du texte. Le menu du trombone (« Coller ») couvre le reste, sur iPhone, iPad et iPhone Duo.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// À poser sur le champ de saisie.
    /// - Parameters:
    ///   - controller: les pièces jointes de CETTE conversation.
    ///   - isFieldFocused: le champ a-t-il le focus (Mac : le moniteur n'agit que dans ce cas ou si aucun champ n'est en édition).
    func acceptsComposerPaste(controller: FileAttachmentController, isFieldFocused: @escaping () -> Bool) -> some View {
        #if os(macOS)
        background(ComposerPasteMonitor(controller: controller, isFieldFocused: isFieldFocused))
        #else
        pasteDestination(for: DroppedItem.self) { items in
            let named = PasteImport.uniquelyNamed(items, imagePrefix: "Image collée")
            controller.receivePasted(named)
        } validator: { items in
            DropPlan.attachableOnly(items)
        }
        #endif
    }
}

#if os(macOS)
/// Vue sans rendu qui garde un moniteur `NSEvent` tant qu'elle est dans une fenêtre.
private struct ComposerPasteMonitor: NSViewRepresentable {
    let controller: FileAttachmentController
    let isFieldFocused: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.configure(controller: controller, isFieldFocused: isFieldFocused)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.configure(controller: controller, isFieldFocused: isFieldFocused)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

private final class MonitorView: NSView {
    private var controller: FileAttachmentController?
    private var isFieldFocused: () -> Bool = { false }
    private var monitor: Any?

    func configure(controller: FileAttachmentController, isFieldFocused: @escaping () -> Bool) {
        self.controller = controller
        self.isFieldFocused = isFieldFocused
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Le moniteur est appelé sur le main thread ; `NSEvent` n'est pas `Sendable`, seul un booléen en ressort.
            nonisolated(unsafe) let unsafeEvent = event
            let consumed = MainActor.assumeIsolated { self?.consumes(unsafeEvent) ?? false }
            return consumed ? nil : event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// `true` : l'événement est consommé (collage d'un fichier ou d'une image). `false` : le champ colle comme d'habitude.
    private func consumes(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v",
              isFieldFocused() || !(window.firstResponder is NSText),
              let controller else { return false }
        let payload = MacPastePayload.read()
        switch PasteboardClassifier.decision(for: payload.snapshot) {
        case .files, .image:
            Task {
                let items = await payload.attachableItems()
                controller.receivePasted(items)
            }
            return true
        case .text, .nothing:
            return false
        }
    }
}
#endif
