import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        // Video tooling lives in the dark; the launch screen is dark too, so lock
        // it and every semantic colour below follows without per-screen changes.
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UINavigationController(rootViewController: PickViewController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

// MARK: - Shared UI helpers

extension UIViewController {
    func presentError(_ error: Error) {
        let alert = UIAlertController(title: "Something went wrong",
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

enum Style {
    /// Warm accent shared with the app icon and launch screen.
    static let accent = UIColor(red: 0.98, green: 0.58, blue: 0.29, alpha: 1)

    /// Target/action rather than `UIAction`: `UIControl.addAction(_:for:)` is
    /// iOS 14 and we ship to 13.
    static func button(_ title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.backgroundColor = Style.accent
        button.setTitleColor(UIColor(white: 0.06, alpha: 1), for: .normal)
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
