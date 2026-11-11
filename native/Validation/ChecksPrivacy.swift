/*
 * Regression checks – privacy and formats: private permissions, symlink attacks and RTF budgets.
 * Synthetic fixtures only; never touches the real clipboard or history database.
 * author: helele
 * since: 2026-11-09
 */
import Foundation
import Carbon
import SQLite3
import Darwin

extension RegressionChecks {
    static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func privacy(_ directory: URL) async throws {
        let ordinary = try child(directory, "ordinary")
        // prepare must repair an existing permissive app-owned directory as well as create private files.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ordinary.path)
        let assets = try child(ordinary, "assets")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: assets.path)
        let store = HistoryStore(directory: ordinary)
        try await store.save(capture("private payload"), retention: 0)
        try require(try mode(ordinary) == 0o700 && mode(assets) == 0o700, "History directories are not mode 0700")
        for file in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            let url = ordinary.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) {
                try require(try mode(url) == 0o600, "Metadata file \(file) is not mode 0600")
            }
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: assets.path) {
            try require(try mode(assets.appendingPathComponent(name)) == 0o600, "Content asset is not mode 0600")
        }
        let clip = try await page(store).clips[0]
        let db = try FixtureDatabase(ordinary)
        let assetName = try db.rows("SELECT filename FROM representation WHERE entry_id=?", [clip.id.uuidString])[0][0]
        let asset = assets.appendingPathComponent(assetName)
        let sentinel = directory.appendingPathComponent("symlink-read-target")
        let sentinelData = Data("private payload".utf8) // same size prevents a false pass based only on byte count
        try sentinelData.write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sentinel.path)
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: sentinel)
        try await expectError(.missingContent) { _ = try await store.representations(clip.id) }
        try require(try Data(contentsOf: sentinel) == sentinelData && mode(sentinel) == 0o644, "Asset read followed or changed symlink target")

        try await store.delete(clip.id)
        try require(try Data(contentsOf: sentinel) == sentinelData, "Delete followed an asset symlink")

        for component in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            for attackKind in ["hardlink", "directory", "fifo"] {
                let attack = try child(directory, "\(attackKind)-\(component.replacingOccurrences(of: ".", with: "-"))")
                let attemptedRoot = try child(attack, "store")
                let location = attemptedRoot.appendingPathComponent(component)
                let target = attack.appendingPathComponent("untouched")
                try Data("hardlink sentinel".utf8).write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                switch attackKind {
                case "hardlink": try FileManager.default.linkItem(at: target, to: location)
                case "directory": _ = try child(attemptedRoot, component)
                default: try require(mkfifo(location.path, 0o600) == 0, "Cannot create synthetic FIFO")
                }
                let attackedStore = HistoryStore(directory: attemptedRoot)
                try await expectError(.storage) { try await attackedStore.prepare() }
                try require(try String(contentsOf: target, encoding: .utf8) == "hardlink sentinel" && mode(target) == 0o644,
                            "\(attackKind) metadata rejection modified target")
            }
        }

        // Replacing the visible assets path after prepare must not redirect writes outside the owned FD.
        let swappedRoot = try child(directory, "swapped-store")
        let swappedStore = HistoryStore(directory: swappedRoot)
        try await swappedStore.prepare()
        let ownedAssets = swappedRoot.appendingPathComponent("assets")
        try FileManager.default.moveItem(at: ownedAssets, to: swappedRoot.appendingPathComponent("owned-assets"))
        let escapeTarget = try child(directory, "escape-target")
        try FileManager.default.createSymbolicLink(at: ownedAssets, withDestinationURL: escapeTarget)
        do {
            try await swappedStore.save(capture("must not escape owned assets"), retention: 0)
        } catch let error as LibraryError {
            try require(String(describing: error) == String(describing: LibraryError.storage), "Unexpected assets-swap error")
        }
        try require(try FileManager.default.contentsOfDirectory(atPath: escapeTarget.path).isEmpty,
                    "Active assets-directory replacement redirected a content write")

        for component in ["root", "assets", "history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            let attack = try child(directory, "attack-\(component.replacingOccurrences(of: ".", with: "-"))")
            let target: URL
            let attemptedRoot: URL
            if component == "root" || component == "assets" {
                target = try child(attack, "target")
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                let content = target.appendingPathComponent("sentinel")
                try Data("do not touch".utf8).write(to: content)
                if component == "root" {
                    attemptedRoot = attack.appendingPathComponent("linked-root")
                    try FileManager.default.createSymbolicLink(at: attemptedRoot, withDestinationURL: target)
                } else {
                    attemptedRoot = try child(attack, "store")
                    try FileManager.default.createSymbolicLink(at: attemptedRoot.appendingPathComponent("assets"), withDestinationURL: target)
                }
            } else {
                attemptedRoot = try child(attack, "store")
                target = attack.appendingPathComponent("target")
                try Data("do not touch".utf8).write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                try FileManager.default.createSymbolicLink(at: attemptedRoot.appendingPathComponent(component), withDestinationURL: target)
            }
            let targetMode = try mode(target)
            let attackedStore = HistoryStore(directory: attemptedRoot)
            try await expectError(.storage) { try await attackedStore.prepare() }
            let info = try target.resourceValues(forKeys: [.isDirectoryKey])
            let sentinelURL = info.isDirectory == true ? target.appendingPathComponent("sentinel") : target
            try require(try String(contentsOf: sentinelURL, encoding: .utf8) == "do not touch" && mode(target) == targetMode,
                        "\(component) symlink attack modified its target")
            if info.isDirectory == true {
                try require(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["sentinel"],
                            "\(component) symlink attack wrote through target directory")
            }
        }
    }

    static func rtf(_ count: Int, character: Character = "r") -> Data {
        Data(("{\\rtf1\\ansi " + String(repeating: String(character), count: count) + "}").utf8)
    }

    static func richText(_ directory: URL) async throws {
        let store = HistoryStore(directory: directory)
        let budget = ClipboardFormats.maximumRichTextPreviewBytes
        let oversized = rtf(budget + 1)
        let original = ClipCapture(kind: .text, title: "oversized RTF", excerpt: "", searchText: "", source: "Synthetic",
                                   sourceBundleID: "", representations: [ClipRepresentation(item: 0, type: "public.rtf", data: oversized)])
        try await store.save(original, retention: 0)
        let large = try await page(store).clips[0]
        let raw = try await store.representations(large.id)
        try require(raw[0].data == oversized, "Oversized RTF raw copy must remain available")
        let preview = try await store.preview(large.id)
        try require(preview.text.utf8.count <= 16_384 && !preview.text.contains(String(repeating: "r", count: 1_000)),
                    "Normal preview parsed over-budget RTF")
        try await expectError(.richTextTooLarge) { _ = try await store.plainText(large.id, kind: .text) }
        try require(ClipboardFormats.richText(oversized) == nil, "Rich-text parser accepted over-budget data")

        let parts = [ClipRepresentation(item: 0, type: "public.rtf", data: rtf(budget / 2 + 1, character: "a")),
                     ClipRepresentation(item: 1, type: "public.rtf", data: rtf(budget / 2 + 1, character: "b"))]
        try await store.save(ClipCapture(kind: .text, title: "aggregate RTF", excerpt: "", searchText: "", source: "Synthetic",
                                        sourceBundleID: "", representations: parts), retention: 0)
        let aggregate = try await page(store).clips.first(where: { $0.title == "aggregate RTF" || $0.id != large.id })!
        try await expectError(.richTextTooLarge) { _ = try await store.plainText(aggregate.id, kind: .text) }
        let aggregatePreview = try await store.preview(aggregate.id)
        try require(aggregatePreview.text.utf8.count <= 16_384, "Aggregate rich-text preview exceeded detail budget")

        let plaintext = String(repeating: "p", count: budget + 1)
        try await store.save(capture(plaintext), retention: 0)
        let plainID = try await page(store).clips.first(where: { $0.byteSize == plaintext.utf8.count })!.id
        let converted = try await store.plainText(plainID, kind: .text)
        try require(converted.count == 1 && converted[0].data == Data(plaintext.utf8), "RTF input budget incorrectly limits pure text")
        let small = rtf(12, character: "s")
        try await store.save(ClipCapture(kind: .text, title: "small RTF", excerpt: "", searchText: "", source: "Synthetic",
                                        sourceBundleID: "", representations: [ClipRepresentation(item: 0, type: "public.rtf", data: small)]), retention: 0)
        let smallPage = try await page(store, query: String(repeating: "s", count: 12))
        try require(smallPage.total == 1, "Small RTF was not extracted for search")
        let smallText = try await store.plainText(smallPage.clips[0].id, kind: .text)
        try require(String(data: smallText[0].data, encoding: .utf8) == String(repeating: "s", count: 12), "Small RTF conversion failed")
        let truncatedRTF = rtf(20_000, character: "z")
        try await store.save(ClipCapture(kind: .text, title: "preview truncation", excerpt: "", searchText: "", source: "Synthetic",
                                        sourceBundleID: "", representations: [ClipRepresentation(item: 0, type: "public.rtf", data: truncatedRTF)]), retention: 0)
        let truncatedID = try await page(store, query: String(repeating: "z", count: 12)).clips[0].id
        let truncatedPreview = try await store.preview(truncatedID)
        try require(truncatedPreview.text.hasPrefix(String(repeating: "z", count: 16_000))
                    && truncatedPreview.text.contains("预览已截断") && truncatedPreview.text.utf8.count <= 16_384,
                    "RTF preview omitted its truncation notice or exceeded the detail budget")
        let completeRTF = try await store.plainText(truncatedID, kind: .text)
        try require(completeRTF[0].data == Data(String(repeating: "z", count: 20_000).utf8),
                    "Preview metadata budget truncated plain-text RTF recovery")
        let mixed = [ClipRepresentation(item: 0, type: "public.rtf", data: oversized),
                     ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: Data("preferred text".utf8))]
        try await store.save(capture("preferred text", representations: mixed), retention: 0)
        let mixedID = try await page(store, query: "preferred text").clips[0].id
        let preferred = try await store.plainText(mixedID, kind: .text)
        try require(String(data: preferred[0].data, encoding: .utf8) == "preferred text", "Unused RTF should not consume conversion budget")
    }
}
