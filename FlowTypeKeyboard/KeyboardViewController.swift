import SwiftUI
import UIKit

public final class KeyboardViewController: UIInputViewController {
    private let stateModel = KeyboardStateModel()
    private var hostingController: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?

    public override func viewDidLoad() {
        super.viewDidLoad()

        stateModel.proxyProvider = { [weak self] in
            self?.textDocumentProxy
        }
        stateModel.advanceInputModeHandler = { [weak self] in
            self?.advanceToNextInputMode()
        }
        stateModel.openURLHandler = { [weak self] url in
            self?.openHostApp(url: url)
        }

        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear

        let rootView = KeyboardRootView(model: stateModel)
        let host = UIHostingController(rootView: rootView)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.isOpaque = false

        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        self.hostingController = host

        let constraint = view.heightAnchor.constraint(equalToConstant: preferredKeyboardHeight())
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        self.heightConstraint = constraint

        requestSupplementaryLexicon { [weak self] lexicon in
            Task { @MainActor [weak self] in
                self?.stateModel.setSupplementaryLexicon(lexicon.entries)
            }
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        stateModel.hasFullAccess = self.hasFullAccess
        stateModel.needsInputModeSwitchKey = self.needsInputModeSwitchKey
        stateModel.reloadSharedSettingsAsync()
        stateModel.syncHostStatusAsync()
        stateModel.refreshContextFromProxy()
        updateHeightIfNeeded()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeightIfNeeded()
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        stateModel.scheduleContextRefresh()
    }

    public override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        stateModel.scheduleContextRefresh()
    }

    private func updateHeightIfNeeded() {
        let target = preferredKeyboardHeight()
        if let hc = heightConstraint, abs(hc.constant - target) > 0.5 {
            hc.constant = target
        }
    }

    private func preferredKeyboardHeight() -> CGFloat {
        let isLandscape = traitCollection.verticalSizeClass == .compact
        return isLandscape ? 236 : 293
    }

    private func openHostApp(url: URL) {
        if let ctx = extensionContext {
            ctx.open(url) { success in
                if !success {
                    DispatchQueue.main.async {
                        let env = EnvironmentValues()
                        env.openURL(url)
                    }
                }
            }
        } else {
            let env = EnvironmentValues()
            env.openURL(url)
        }
    }
}
