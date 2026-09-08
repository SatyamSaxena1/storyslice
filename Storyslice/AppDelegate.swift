import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: PickViewController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

// MARK: - Shared UI helpers

extension UIViewController {
    func presentError(_ error: Error) {
        // ponytail: full NSError detail while diagnosing the picker issue --
        // file writes and log capture both proved unreliable in this jailbreak
        // sandbox, but alerts render fine and screenshots read them just as
        // well. Trim back to plain localizedDescription once resolved.
        let ns = error as NSError
        let message = "\(error.localizedDescription)\n\ndomain=\(ns.domain) code=\(ns.code)\nuserInfo=\(ns.userInfo)"
        let alert = UIAlertController(title: "Something went wrong",
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

enum Style {
    /// Target/action rather than `UIAction`: `UIControl.addAction(_:for:)` is
    /// iOS 14 and we ship to 13.
    static func button(_ title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 14
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return button
    }

    static func label(_ text: String, style: UIFont.TextStyle = .body) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.textColor = .label
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }

    static func stack(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func pin(_ stack: UIStackView, in view: UIView) {
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}
