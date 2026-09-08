import Photos

enum LibraryError: LocalizedError {
    case accessDenied
    case saveFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Storyslice needs permission to add videos to your library. "
                 + "Enable Photos access in Settings to save your segments."
        case .saveFailed(let underlying):
            return underlying?.localizedDescription ?? "The segments could not be saved."
        }
    }
}

enum LibraryWriter {

    /// Saves segments into an album, timestamped so they sort into posting order.
    ///
    /// The Photos picker and the Instagram composer both sort by creation date.
    /// Without the per-index offset the segments come back shuffled and the
    /// whole feature reads as broken, so this one line is load-bearing.
    static func save(_ segments: [ExportedSegment],
                     albumNamed title: String,
                     baseDate: Date?) async throws {

        let access = await PhotoAccess.requestAddAndRead()
        guard access != .denied else { throw LibraryError.accessDenied }

        let base = baseDate ?? Date()
        // `.limited` access still permits adding, but not reading back an album
        // we created, so skip album management entirely in that case.
        let useAlbum = access == .granted
        let existing = useAlbum ? findAlbum(named: title) : nil

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let album: PHAssetCollectionChangeRequest?
                if !useAlbum {
                    album = nil
                } else if let existing = existing {
                    album = PHAssetCollectionChangeRequest(for: existing)
                } else {
                    album = PHAssetCollectionChangeRequest
                        .creationRequestForAssetCollection(withTitle: title)
                }

                for segment in segments.sorted(by: { $0.index < $1.index }) {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: segment.url, options: nil)
                    request.creationDate = base.addingTimeInterval(Double(segment.index))
                    if let placeholder = request.placeholderForCreatedAsset {
                        album?.addAssets([placeholder] as NSArray)
                    }
                }
            }, completionHandler: { success, error in
                if success { cont.resume() }
                else { cont.resume(throwing: LibraryError.saveFailed(error)) }
            })
        }
    }

    private static func findAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle = %@", title)
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options).firstObject
    }
}
