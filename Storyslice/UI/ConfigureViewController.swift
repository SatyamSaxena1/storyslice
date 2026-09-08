import AVFoundation
import UIKit

final class ConfigureViewController: UIViewController {

    private let source: VideoSourceInfo
    private let lengths: [Int] = [15, 30, 60]
    private let lengthControl = UISegmentedControl(items: ["15s", "30s", "60s"])
    private let fillControl = UISegmentedControl(
        items: FillMode.allCases.map { $0.title })
    private let summary = Style.label("")

    init(source: VideoSourceInfo) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Split"
        view.backgroundColor = .systemBackground

        // 60s is Instagram's current per-Story limit, and the sensible default.
        lengthControl.selectedSegmentIndex = 2
        fillControl.selectedSegmentIndex = FillMode.blur.rawValue
        lengthControl.addTarget(self, action: #selector(refresh), for: .valueChanged)

        let split = Style.button("Split into Segments")
        split.addTarget(self, action: #selector(startExport), for: .touchUpInside)

        Style.pin(Style.stack([
            Style.label(describeSource(), style: .subheadline),
            Style.label("Segment length", style: .headline),
            lengthControl,
            Style.label("Fill style", style: .headline),
            fillControl,
            summary,
            split
        ]), in: view)

        refresh()
    }

    private var selectedPlan: SegmentPlan {
        SegmentPlan(duration: source.duration,
                    targetSegmentLength: CMTime(value: CMTimeValue(lengths[lengthControl.selectedSegmentIndex]),
                                                timescale: 1))
    }

    @objc private func refresh() {
        let plan = selectedPlan
        let each = plan.segments.map { String(format: "%.0fs", $0.duration.seconds) }
        summary.text = plan.count == 1
            ? "One segment, no split needed."
            : "\(plan.count) segments: \(each.joined(separator: " + "))"
    }

    @objc private func startExport() {
        var options = ExportOptions()
        options.fillMode = FillMode(rawValue: fillControl.selectedSegmentIndex) ?? .blur
        navigationController?.pushViewController(
            ExportViewController(source: source, plan: selectedPlan, options: options),
            animated: true)
    }

    private func describeSource() -> String {
        let display = Geometry.displaySize(naturalSize: source.naturalSize,
                                           preferredTransform: source.preferredTransform)
        let hdr = source.transfer.isHDR ? " HDR" : ""
        return String(format: "%.0f×%.0f%@ · %.0fs",
                      display.width, display.height, hdr, source.duration.seconds)
    }
}
