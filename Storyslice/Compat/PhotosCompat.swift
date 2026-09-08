import AVFoundation
import Photos
import PhotosUI
import UIKit

// ponytail: temporary NSLog tracing while chasing a picker-selection issue
// that leaves no crash report and no other trace. Delete every "STORYSLICE-DIAG"
// line below once the picker is confirmed working.

/// The only file in the project that contains `#available`.
/// Everything downstream sees a single API regardless of iOS version.

// MARK: - Authorization

enum PhotoAccess {

    enum Level { case granted, limited, denied }

    static func requestAddAndRead() async -> Level {
        await withCheckedContinuation { (cont: CheckedContinuation<Level, Never>) in
            if #available(iOS 14, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    cont.resume(returning: level(for: status))
                }
            } else {
                PHPhotoLibrary.requestAuthorization { status in
                    cont.resume(returning: level(for: status))
                }
            }
        }
    }

    private static func level(for status: PHAuthorizationStatus) -> Level {
        // `.limited` is an iOS 14 case, so it cannot appear in a plain switch
        // compiled against a 13.0 floor.
        if #available(iOS 14, *), status == .limited { return .limited }
        return status == .authorized ? .granted : .denied
    }
}

// MARK: - Picking

protocol VideoPickerDelegate: AnyObject {
    func videoPicker(_ picker: VideoPicker, didPick url: URL, displayName: String)
    func videoPickerDidCancel(_ picker: VideoPicker)
    func videoPicker(_ picker: VideoPicker, didFailWith error: Error)
}

/// `PHPickerViewController` on iOS 14+, `UIImagePickerController` on iOS 13.
///
/// Both paths copy the chosen file into our own temporary directory before
/// returning: the URL `PHPickerViewController` hands back is deleted the moment
/// its completion handler returns.
final class VideoPicker: NSObject {

    weak var delegate: VideoPickerDelegate?
    private static let movieType = "public.movie"

    func present(from presenter: UIViewController) {
        if #available(iOS 14, *) {
            NSLog("STORYSLICE-DIAG presenting PHPickerViewController")
            var configuration = PHPickerConfiguration()
            configuration.filter = .videos
            configuration.selectionLimit = 1
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            presenter.present(picker, animated: true)
        } else {
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.mediaTypes = [Self.movieType]
            picker.videoExportPreset = AVAssetExportPresetPassthrough
            picker.delegate = self
            presenter.present(picker, animated: true)
        }
    }

    fileprivate func adopt(_ url: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("storyslice-input", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}

@available(iOS 14, *)
extension VideoPicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        NSLog("STORYSLICE-DIAG didFinishPicking count=%d providers=%@",
              results.count, results.map { $0.itemProvider.registeredTypeIdentifiers })
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else {
            NSLog("STORYSLICE-DIAG no itemProvider -> treating as cancel")
            delegate?.videoPickerDidCancel(self)
            return
        }
        let name = provider.suggestedName ?? "Video"
        let hasMovie = provider.hasItemConformingToTypeIdentifier(Self.movieType)
        NSLog("STORYSLICE-DIAG provider name=%@ hasMovieType=%@ allTypes=%@",
              name, hasMovie ? "YES" : "NO", provider.registeredTypeIdentifiers)
        provider.loadFileRepresentation(forTypeIdentifier: Self.movieType) { [weak self] url, error in
            NSLog("STORYSLICE-DIAG loadFileRepresentation callback url=%@ error=%@",
                  url?.absoluteString ?? "nil", String(describing: error))
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let url = url else {
                    self.delegate?.videoPicker(self, didFailWith: error ?? AVCompatError.noVideoTrack)
                    return
                }
                do {
                    let copied = try self.adopt(url)
                    NSLog("STORYSLICE-DIAG adopted to %@", copied.absoluteString)
                    self.delegate?.videoPicker(self, didPick: copied, displayName: name)
                } catch {
                    NSLog("STORYSLICE-DIAG adopt() threw %@", String(describing: error))
                    self.delegate?.videoPicker(self, didFailWith: error)
                }
            }
        }
    }
}

extension VideoPicker: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let url = info[.mediaURL] as? URL else {
            delegate?.videoPickerDidCancel(self)
            return
        }
        do {
            let copied = try adopt(url)
            delegate?.videoPicker(self, didPick: copied,
                                  displayName: url.deletingPathExtension().lastPathComponent)
        } catch {
            delegate?.videoPicker(self, didFailWith: error)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        delegate?.videoPickerDidCancel(self)
    }
}
