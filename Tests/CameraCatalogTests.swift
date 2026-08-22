import Foundation

extension PhotokichinTestRunner {
    static func runCameraCatalogTests() throws {
        try runCameraCatalogBuilderTests()
        try runCameraCatalogRefreshGateTests()
        print("PASS: camera catalog replacement, pairing, stable ordering, state preservation, and five-second gate")
    }

    private static func runCameraCatalogBuilderTests() throws {
        let cameraID = "camera-catalog-test"
        let earlyDate = Date(timeIntervalSince1970: 100)
        let middleDate = Date(timeIntervalSince1970: 200)
        let lateDate = Date(timeIntervalSince1970: 300)

        let pairedJPEG = cameraAsset(
            id: "path:DCIM/100/IMG_0001.JPG",
            filename: "IMG_0001.JPG",
            path: "DCIM/100/IMG_0001.JPG",
            variant: .jpeg,
            date: earlyDate
        )
        let pairedRAW = cameraAsset(
            id: "path:DCIM/100/IMG_0001.CR3",
            filename: "IMG_0001.CR3",
            path: "DCIM/100/IMG_0001.CR3",
            variant: .raw,
            date: earlyDate
        )
        let jpgOnly = cameraAsset(
            id: "path:DCIM/100/IMG_0002.JPG",
            filename: "IMG_0002.JPG",
            path: "DCIM/100/IMG_0002.JPG",
            variant: .jpeg,
            date: middleDate
        )
        let rawOnly = cameraAsset(
            id: "path:DCIM/100/IMG_0003.CR3",
            filename: "IMG_0003.CR3",
            path: "DCIM/100/IMG_0003.CR3",
            variant: .raw,
            date: lateDate
        )
        let movie = cameraAsset(
            id: "path:DCIM/100/CLIP_0001.MOV",
            filename: "CLIP_0001.MOV",
            path: "DCIM/100/CLIP_0001.MOV",
            variant: .movie,
            date: Date(timeIntervalSince1970: 250)
        )
        let sameBasenameOtherFolder = cameraAsset(
            id: "path:DCIM/101/IMG_0002.JPG",
            filename: "IMG_0002.JPG",
            path: "DCIM/101/IMG_0002.JPG",
            variant: .jpeg,
            date: middleDate
        )

        let entries = [
            // Deliberately out of chronological order. The second entry is a
            // duplicate notification carrying the same pairing relation.
            CameraCatalogEntry(asset: rawOnly, pairedRaw: nil),
            CameraCatalogEntry(asset: pairedJPEG, pairedRaw: pairedRAW),
            CameraCatalogEntry(asset: jpgOnly, pairedRaw: nil),
            CameraCatalogEntry(asset: pairedJPEG, pairedRaw: pairedRAW),
            CameraCatalogEntry(asset: movie, pairedRaw: nil),
            CameraCatalogEntry(asset: sameBasenameOtherFolder, pairedRaw: nil)
        ]
        // The ICCameraFile adapter rejects unsupported extensions before a
        // value reaches the pure builder.
        try require(CameraCatalogBuilder.variant(for: "README.TXT") == nil, "unsupported extensions must be rejected by the adapter")

        let groups = CameraCatalogBuilder.groups(
            cameraID: cameraID,
            cameraName: "Test Camera",
            entries: entries,
            previousGroups: []
        )
        try require(groups.count == 5, "JPG+CR3, JPG-only, CR3-only, MOV, and same-name folder groups must remain five groups")
        try require(groups.allSatisfy { $0.presentationOrder >= 0 }, "every camera group must receive a presentation order")
        try require(groups.map(\.presentationOrder) == Array(0..<groups.count), "presentationOrder must be a contiguous sequence")
        try require(groups.allSatisfy { $0.metadata.cameraModel == "Test Camera" }, "camera name must be copied into camera metadata")
        try require(
            groups.map(\.captureDate) == groups.map(\.captureDate).sorted { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) },
            "groups must be sorted by capture date first"
        )

        let noCameraNameGroups = CameraCatalogBuilder.groups(
            cameraID: cameraID,
            cameraName: nil,
            entries: [CameraCatalogEntry(asset: jpgOnly, pairedRaw: nil)],
            previousGroups: []
        )
        try require(noCameraNameGroups.first?.metadata.cameraModel == nil, "a missing camera name must not be replaced with productKind")

        let pairedGroup = try requireValue(
            groups.first { $0.id.hasSuffix("DCIM/100/IMG_0001") },
            "the JPG and paired CR3 must share one group"
        )
        try require(Set(pairedGroup.cameraReference?.assets.map(\.variant) ?? []) == Set([AssetVariant.jpeg, .raw]), "pairedRawImage must complete the JPG group with CR3")
        try require(pairedGroup.cameraReference?.assets.count == 2, "duplicate notifications must not duplicate the JPG or CR3 asset")

        let jpgOnlyGroup = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/IMG_0002") }, "JPG-only group is missing")
        try require(jpgOnlyGroup.cameraReference?.asset(for: .jpeg) != nil, "JPG-only group must retain its JPG")
        try require(jpgOnlyGroup.cameraReference?.asset(for: .raw) == nil, "JPG-only group must not invent a CR3")

        let rawOnlyGroup = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/IMG_0003") }, "CR3-only group is missing")
        try require(rawOnlyGroup.cameraReference?.asset(for: .raw) != nil, "CR3-only group must retain its CR3")
        try require(rawOnlyGroup.cameraReference?.asset(for: .jpeg) == nil, "CR3-only group must not invent a JPG")

        let movieGroup = try requireValue(groups.first { $0.id.hasSuffix("DCIM/100/CLIP_0001") }, "MOV group is missing")
        try require(movieGroup.cameraReference?.asset(for: .movie) != nil, "MOV must remain a camera asset")
        try require(groups.allSatisfy { !$0.id.contains("README") }, "unsupported extensions must be excluded")

        let sameNameGroups = groups.filter { $0.basename == "IMG_0002" }
        try require(sameNameGroups.count == 2, "same basename in different folders must form separate groups")
        try require(sameNameGroups.map(\.id) == sameNameGroups.map(\.id).sorted(), "equal dates and basenames must use id as the final tie-breaker")

        var previous = jpgOnlyGroup
        previous.importedJPEG = true
        previous.importedRAW = true
        previous.possibleImportedJPEG = true
        previous.possibleImportedRAW = true
        previous.isMetadataLoaded = true
        previous.libraryAssetStatus = .registered
        previous.photoID = "persistent-photo-id"
        previous.labels = [PhotoLabel(id: "label-1", name: "Keep", normalizedName: "keep", colorHex: "#000000", sortOrder: 0, lastUsedAt: nil)]
        let changedJPG = cameraAsset(
            id: jpgOnly.identifier,
            filename: jpgOnly.filename,
            path: jpgOnly.remotePath,
            variant: .jpeg,
            date: Date(timeIntervalSince1970: 50)
        )
        let replacement = CameraCatalogBuilder.groups(
            cameraID: cameraID,
            cameraName: "Test Camera",
            entries: [CameraCatalogEntry(asset: changedJPG, pairedRaw: nil)],
            previousGroups: [previous, rawOnlyGroup]
        )
        try require(replacement.count == 1, "the current complete input must replace the old snapshot")
        let preserved = try requireValue(replacement.first, "replacement group is missing")
        try require(preserved.importedJPEG && preserved.importedRAW, "existing import state must survive catalog replacement")
        try require(preserved.possibleImportedJPEG && preserved.possibleImportedRAW, "existing possible-import state must survive catalog replacement")
        try require(preserved.isMetadataLoaded && preserved.libraryAssetStatus == .registered, "existing metadata and library state must survive catalog replacement")
        try require(preserved.photoID == "persistent-photo-id" && preserved.labels.count == 1, "existing photo identity and labels must survive catalog replacement")
        try require(!replacement.contains { $0.id == rawOnlyGroup.id }, "a group absent from the complete input must not remain")
    }

    private static func runCameraCatalogRefreshGateTests() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        try require(
            CameraCatalogRefreshGate.decision(
                receivedAt: base,
                completionEventAt: nil,
                updateInFlight: false,
                updateStartedAt: nil,
                updateFinishedAt: nil,
                nextAllowedAt: nil
            ) == .accepted,
            "the first catalog notification must be accepted"
        )
        let nextAllowed = base.addingTimeInterval(CameraCatalogRefreshGate.interval)
        try require(
            CameraCatalogRefreshGate.decision(
                receivedAt: base.addingTimeInterval(4.999),
                completionEventAt: nil,
                updateInFlight: false,
                updateStartedAt: nil,
                updateFinishedAt: nil,
                nextAllowedAt: nextAllowed
            ) == .ignored("five_second_interval"),
            "a notification inside the five-second gate must be ignored"
        )
        try require(
            CameraCatalogRefreshGate.decision(
                receivedAt: nextAllowed,
                completionEventAt: nil,
                updateInFlight: false,
                updateStartedAt: nil,
                updateFinishedAt: nil,
                nextAllowedAt: nextAllowed
            ) == .accepted,
            "a notification at the five-second boundary must be accepted"
        )
        try require(
            CameraCatalogRefreshGate.decision(
                receivedAt: base.addingTimeInterval(1),
                completionEventAt: nil,
                updateInFlight: true,
                updateStartedAt: base,
                updateFinishedAt: nil,
                nextAllowedAt: nil
            ) == .ignored("catalog_update_in_flight"),
            "a notification during catalog replacement must be ignored"
        )
        try require(
            CameraCatalogRefreshGate.decision(
                receivedAt: base.addingTimeInterval(1),
                completionEventAt: base.addingTimeInterval(2),
                updateInFlight: false,
                updateStartedAt: nil,
                updateFinishedAt: nil,
                nextAllowedAt: nil
            ) == .ignored("before_completion_event"),
            "a delayed notification from before completion must be ignored"
        )
        try require(
            CameraCatalogRefreshGate.decision(
                receivedAt: base.addingTimeInterval(3),
                completionEventAt: base.addingTimeInterval(2),
                updateInFlight: false,
                updateStartedAt: nil,
                updateFinishedAt: nil,
                nextAllowedAt: nil
            ) == .accepted,
            "a notification after completion may start the next replacement"
        )
    }

    private static func cameraAsset(
        id: String,
        filename: String,
        path: String,
        variant: AssetVariant,
        date: Date
    ) -> CameraCatalogAsset {
        CameraCatalogAsset(
            identifier: id,
            filename: filename,
            remotePath: path,
            variant: variant,
            fileSize: 100,
            captureDate: date,
            width: 4_000,
            height: 3_000
        )
    }
}
