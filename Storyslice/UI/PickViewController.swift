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

        // ponytail: temporary -- settle whether this sandbox can write files
        // AT ALL, independent of the picker. Two different videos have hit
        // the identical "no such file" error, which looks less like a
        // per-asset race and more like a broken container from re-signing.
        DispatchQueue.main.async { [weak self] in self?.runSandboxSelfTest() }
    }

    private func runSandboxSelfTest() {
        var lines: [String] = []
        let fm = FileManager.default
        for (label, base) in [("tmp", fm.temporaryDirectory),
                              ("docs", fm.urls(for: .documentDirectory, in: .userDomainMask).first)] {
            guard let base = base else { lines.append("\(label): no URL"); continue }
            let file = base.appendingPathComponent("selftest-\(label).txt")
            do {
                try "hello".data(using: .utf8)!.write(to: file)
                let readBack = try String(contentsOf: file, encoding: .utf8)
                lines.append("\(label): OK wrote+read '\(readBack)' at \(file.path)")
            } catch {
                let ns = error as NSError
                lines.append("\(label): FAILED \(ns.domain)#\(ns.code) \(ns.localizedDescription)")
            }
        }
        let alert = UIAlertController(title: "DIAG: sandbox self-test",
                                      message: lines.joined(separator: "\n\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func choose() {
        diagLog("choose() tapped")
        picker.present(from: self)
    }

    private func setBusy(_ busy: Bool) {
        chooseButton.isEnabled = !busy
        busy ? spinner.startAnimating() : spinner.stopAnimating()
    }
}

extension PickViewController: VideoPickerDelegate {

    func videoPicker(_ picker: VideoPicker, didPick url: URL, displayName: String) {
        diagLog("PickViewController.didPick url=\(url.absoluteString) name=\(displayName)")
        setBusy(true)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.setBusy(false) }
            do {
                let asset = AVURLAsset(
                    url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let info = try await AssetLoader.load(asset: asset, displayName: displayName)
                diagLog("AssetLoader.load succeeded duration=\(info.duration.seconds)")
                guard info.duration.seconds > 0 else {
                    throw AVCompatError.unsupportedSource("it has no playable duration")
                }
                self.navigationController?.pushViewController(
                    ConfigureViewController(source: info), animated: true)
                diagLog("pushed ConfigureViewController")
            } catch {
                diagLog("AssetLoader.load threw \(String(describing: error))")
                self.presentError(error)
            }
        }
    }

    func videoPickerDidCancel(_ picker: VideoPicker) {
        diagLog("PickViewController.didCancel")
        // ponytail: temporary -- make the silent/no-op cancel path visible on
        // screen too, so every outcome (success, failure, cancel) shows
        // something screenshots can read, with no dependency on logs or files.
        let alert = UIAlertController(title: "DIAG: cancel path hit",
                                      message: "videoPickerDidCancel ran -- PHPickerResult had no itemProvider.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func videoPicker(_ picker: VideoPicker, didFailWith error: Error) {
        diagLog("PickViewController.didFailWith \(String(describing: error))")
        presentError(error)
    }
}
