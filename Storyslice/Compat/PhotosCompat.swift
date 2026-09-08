import AVFoundation
import Photos
import PhotosUI
import UIKit

// ponytail: temporary tracing while chasing a picker-selection issue that
// leaves no crash report and no other trace. NSLog output proved unreliable
// to capture live (the unified-logging tooling available here only supports
// a forward-looking capture window, which races any UI-driven event), so
// this also appends to a plain file that can just be `cat`/`tail`ed after the
// fact. Delete every diagLog call and this function once the picker works.
func diagLog(_ message: String) {
    NSLog("STORYSLICE-DIAG %@", message)
    // A sandboxed, properly-signed app can only write inside its own
    // container -- resolve it via the real API rather than a hardcoded path
    // (an earlier version hardcoded /var/mobile/Documents, which is outside
    // the sandbox and failed silently under `try?`).
    guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return }
    let line = "\(Date()) \(message)\n"
    let url = dir.appendingPathComponent("storyslice-diag.log")
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

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
            diagLog("presenting PHPickerViewController")
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
        diagLog("didFinishPicking count=\(results.count) providers=\(results.map { $0.itemProvider.registeredTypeIdentifiers })")
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else {
            diagLog("no itemProvider -> treating as cancel")
            delegate?.videoPickerDidCancel(self)
            return
        }
        let name = provider.suggestedName ?? "Video"
        let hasMovie = provider.hasItemConformingToTypeIdentifier(Self.movieType)
        diagLog("provider name=\(name) hasMovieType=\(hasMovie) allTypes=\(provider.registeredTypeIdentifiers)")
        provider.loadFileRepresentation(forTypeIdentifier: Self.movieType) { [weak self] url, error in
            diagLog("loadFileRepresentation callback url=\(url?.absoluteString ?? "nil") error=\(String(describing: error))")
            guard let self = self else { return }

            // The temp file at `url` is only guaranteed to exist for the
            // duration of this completion handler -- copy it out NOW,
            // synchronously, before hopping to the main queue. Deferring the
            // copy into a `DispatchQueue.main.async` (as this used to do)
            // races the system's own cleanup of that temp file and fails
            // with "couldn't be opened because there is no such file".
            let outcome: Result<URL, Error>
            if let url = url {
                do {
                    let copied = try self.adopt(url)
                    diagLog("adopted to \(copied.absoluteString)")
                    outcome = .success(copied)
                } catch {
                    diagLog("adopt() threw \(String(describing: error))")
                    outcome = .failure(error)
                }
            } else {
                outcome = .failure(error ?? AVCompatError.noVideoTrack)
            }

            DispatchQueue.main.async {
                switch outcome {
                case .success(let copied):
                    self.delegate?.videoPicker(self, didPick: copied, displayName: name)
                case .failure(let error):
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
