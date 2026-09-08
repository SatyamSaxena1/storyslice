import AVFoundation
import UIKit

final class ExportViewController: UIViewController {

    private let source: VideoSourceInfo
    private let plan: SegmentPlan
    private let options: ExportOptions

    private let progressView = UIProgressView(progressViewStyle: .default)
    private let status = Style.label("Preparing…", style: .headline)
    private let cancelButton = Style.button("Cancel")

    private var task: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(source: VideoSourceInfo, plan: SegmentPlan, options: ExportOptions) {
        self.source = source
        self.plan = plan
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Exporting"
        view.backgroundColor = .systemBackground
        navigationItem.hidesBackButton = true

        cancelButton.backgroundColor = .secondarySystemFill
        cancelButton.setTitleColor(.label, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        Style.pin(Style.stack([status, progressView, cancelButton]), in: view)
        run()
    }

    @objc private func cancel() {
        task?.cancel()
    }

    private func run() {
        // Exports outlive a brief trip to another app; when the OS reclaims the
        // task the export is cancelled cleanly rather than being killed halfway
        // through a file.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "storyslice.export") {
            [weak self] in self?.task?.cancel()
        }

        task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.endBackgroundTask() }
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("storyslice-output", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let segments = try await VideoSlicer().export(
                    source: self.source, plan: self.plan, options: self.options, into: directory,
                    progress: { fraction in
                        Task { @MainActor [weak self] in self?.update(fraction) }
                    })

                self.status.text = "Saving to Photos…"
                self.progressView.setProgress(1, animated: true)
                try await LibraryWriter.save(segments,
                                             albumNamed: self.source.displayName,
                                             baseDate: self.source.creationDate)

                self.navigationController?.pushViewController(
                    DoneViewController(segments: segments, albumName: self.source.displayName),
                    animated: true)
            } catch is CancellationError {
                self.navigationController?.popToRootViewController(animated: true)
            } catch {
                self.presentError(error)
                self.navigationController?.popViewController(animated: true)
            }
        }
    }

    private func update(_ fraction: Double) {
        progressView.setProgress(Float(fraction), animated: true)
        let done = min(Int(fraction * Double(plan.count)) + 1, plan.count)
        status.text = "Segment \(done) of \(plan.count)"
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
