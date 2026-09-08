import UIKit

final class DoneViewController: UIViewController {

    private let segments: [ExportedSegment]
    private let albumName: String

    init(segments: [ExportedSegment], albumName: String) {
        self.segments = segments
        self.albumName = albumName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Done"
        view.backgroundColor = .systemBackground
        navigationItem.hidesBackButton = true

        let share = Style.button("Share Segments")
        share.addTarget(self, action: #selector(shareSegments), for: .touchUpInside)

        let again = Style.button("Split Another")
        again.backgroundColor = .secondarySystemFill
        again.setTitleColor(.label, for: .normal)
        again.addTarget(self, action: #selector(startOver), for: .touchUpInside)

        Style.pin(Style.stack([
            Style.label("\(segments.count) segments saved", style: .title2),
            Style.label("Find them in the \"\(albumName)\" album in Photos, "
                      + "already in posting order. Add them to your Story oldest first."),
            share,
            again
        ]), in: view)
    }

    @objc private func shareSegments(_ sender: UIButton) {
        let urls = segments.sorted { $0.index < $1.index }.map { $0.url }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = sender
        sheet.popoverPresentationController?.sourceRect = sender.bounds
        present(sheet, animated: true)
    }

    @objc private func startOver() {
        navigationController?.popToRootViewController(animated: true)
    }
}
