import AVFoundation
import UIKit

final class PickViewController: UIViewController {

    private let picker = VideoPicker()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let chooseButton = Style.button("Choose Video")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Storyslice"
        view.backgroundColor = .systemBackground
        picker.delegate = self

        chooseButton.addTarget(self, action: #selector(choose), for: .touchUpInside)
        spinner.hidesWhenStopped = true

        Style.pin(Style.stack([
            Style.label("Split any video into Story-ready 9:16 clips.", style: .title2),
            Style.label("Nothing leaves your phone."),
            chooseButton,
            spinner
        ]), in: view)
    }

    @objc private func choose() {
        picker.present(from: self)
    }

    private func setBusy(_ busy: Bool) {
        chooseButton.isEnabled = !busy
        busy ? spinner.startAnimating() : spinner.stopAnimating()
    }
}

extension PickViewController: VideoPickerDelegate {

    func videoPicker(_ picker: VideoPicker, didPick url: URL, displayName: String) {
        setBusy(true)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.setBusy(false) }
            do {
                let asset = AVURLAsset(
                    url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let info = try await AssetLoader.load(asset: asset, displayName: displayName)
                guard info.duration.seconds > 0 else {
                    throw AVCompatError.unsupportedSource("it has no playable duration")
                }
                self.navigationController?.pushViewController(
                    ConfigureViewController(source: info), animated: true)
            } catch {
                self.presentError(error)
            }
        }
    }

    func videoPickerDidCancel(_ picker: VideoPicker) {}

    func videoPicker(_ picker: VideoPicker, didFailWith error: Error) {
        presentError(error)
    }
}
