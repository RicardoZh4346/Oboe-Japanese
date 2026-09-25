import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// 便携备份 v7（设计 §11.2/§11.3）：ZIP 容器导出、读取校验、恢复准备。
/// 容器识别走 ZIP magic 而非扩展名；附件字节的真实 MIME/像素由
/// ImageIO 嗅探，manifest 只是声明，校验以字节为准。
final class PortableBackupV7PackageTests: XCTestCase {

    // MARK: - 导出

    func testExportWithoutAttachmentsProducesValidPackage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)

        let export = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)

        XCTAssertTrue(PortableBackupPackageReader.isPackage(fileURL: export.url))
        let files = try fixture.unzip(export.url)
        XCTAssertEqual(
            Set(files.keys),
            ["manifest.json", "records.ndjson", "checksums.json"]
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: files["manifest.json"]!)
                as? [String: Any]
        )
        XCTAssertEqual(manifest["format"] as? String, "oboe-portable-backup")
        XCTAssertEqual(manifest["formatVersion"] as? Int, 7)
        XCTAssertEqual(manifest["container"] as? String, "zip")
        XCTAssertEqual(manifest["recordFormatVersion"] as? Int, 7)
        let declaredAttachments = try XCTUnwrap(
            manifest["attachments"] as? [Any]
        )
        XCTAssertTrue(declaredAttachments.isEmpty)
        let scopes = try XCTUnwrap(manifest["excludedScopes"] as? [String])
        XCTAssertFalse(scopes.contains("imageAttachments"))
        XCTAssertTrue(scopes.contains("credentials"))

        // records.ndjson 就是一个完整可读的 v7 记录流（外层包版本恒 7）。
        let records = try XCTUnwrap(files["records.ndjson"])
        let lines = records.split(separator: 0x0A)
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any]
        )
        XCTAssertEqual(first["recordType"] as? String, "manifest")
        XCTAssertEqual(first["formatVersion"] as? Int, 7)
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines.last!)) as? [String: Any]
        )
        XCTAssertEqual(last["recordType"] as? String, "footer")

        let checksums = try XCTUnwrap(
            JSONSerialization.jsonObject(with: files["checksums.json"]!)
                as? [String: Any]
        )
        let digests = try XCTUnwrap(checksums["files"] as? [String: String])
        XCTAssertEqual(
            digests,
            ["records.ndjson": fixture.sha256Hex(records)]
        )

        // manifest 直接可解码成公开模型。
        let decoded = try PortableBackupPackageReader().readManifest(
            fileURL: export.url
        )
        XCTAssertEqual(decoded.formatVersion, 7)
        XCTAssertEqual(decoded.attachments, [])
        XCTAssertEqual(decoded.counts["deck"], 1)
    }

    func testExportWithSingleAttachment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)
        let image = try fixture.store.importImage(data: PackageTestImage.make())
        try await fixture.seedInboxItem(into: source, imageReference: image.id)

        let export = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)

        XCTAssertEqual(export.unresolvedAttachmentIDs, [])
        XCTAssertEqual(export.attachments.count, 1)
        let descriptor = export.attachments[0]
        XCTAssertEqual(descriptor.id, image.id)
        XCTAssertEqual(descriptor.relativePath, "attachments/\(image.id).jpg")
        XCTAssertEqual(descriptor.mimeType, "image/jpeg")
        XCTAssertEqual(descriptor.pixelWidth, 120)
        XCTAssertEqual(descriptor.pixelHeight, 60)

        let files = try fixture.unzip(export.url)
        XCTAssertEqual(files.count, 4)
        let payload = try XCTUnwrap(files["attachments/\(image.id).jpg"])
        XCTAssertEqual(descriptor.byteCount, payload.count)
        XCTAssertEqual(descriptor.sha256, fixture.sha256Hex(payload))
        let checksums = try XCTUnwrap(
            JSONSerialization.jsonObject(with: files["checksums.json"]!)
                as? [String: Any]
        )["files"] as? [String: String]
        XCTAssertEqual(checksums?[descriptor.relativePath], descriptor.sha256)
    }

    func testExportWithMultipleAttachments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)
        var ids: [String] = []
        for _ in 0..<3 {
            let image = try fixture.store.importImage(data: PackageTestImage.make())
            ids.append(image.id)
            try await fixture.seedInboxItem(into: source, imageReference: image.id)
        }

        let export = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)

        XCTAssertEqual(Set(export.attachments.map(\.id)), Set(ids))
        let files = try fixture.unzip(export.url)
        XCTAssertEqual(files.count, 3 + 3)
    }

    /// 两条 inbox item 引用同一资源 id：manifest 与包内文件都只有一份。
    func testDuplicateReferencesAreDeduplicated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)
        let image = try fixture.store.importImage(data: PackageTestImage.make())
        try await fixture.seedInboxItem(into: source, imageReference: image.id)
        try await fixture.seedInboxItem(into: source, imageReference: image.id)

        let export = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)

        XCTAssertEqual(export.attachments.map(\.id), [image.id])
        let files = try fixture.unzip(export.url)
        XCTAssertEqual(
            files.keys.filter { $0.hasPrefix("attachments/") },
            ["attachments/\(image.id).jpg"]
        )
    }

    /// 引用了但文件已缺失：导出继续，id 进入 unresolved 清单，
    /// manifest 不声明它——恢复端按惯例把该引用降级为 NULL。
    func testMissingAttachmentFileIsUnresolved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)
        try await fixture.seedInboxItem(
            into: source,
            imageReference: "missing-image-id"
        )

        let export = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)

        XCTAssertEqual(export.unresolvedAttachmentIDs, ["missing-image-id"])
        XCTAssertEqual(export.attachments, [])
        let files = try fixture.unzip(export.url)
        XCTAssertEqual(files.count, 3)
    }

    // MARK: - 校验拒绝路径

    func testMissingManifestFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let tampered = try fixture.repackaging(package.url) { files in
            files.removeValue(forKey: "manifest.json")
        }
        await fixture.assertFails(
            tampered, equals: .missingEntry("manifest.json")
        )
    }

    func testMissingRecordsFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let tampered = try fixture.repackaging(package.url) { files in
            files.removeValue(forKey: "records.ndjson")
        }
        await fixture.assertFails(
            tampered,
            equals: .missingEntry("records.ndjson")
        )
    }

    func testMissingChecksumsFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let tampered = try fixture.repackaging(package.url) { files in
            files.removeValue(forKey: "checksums.json")
        }
        await fixture.assertFails(
            tampered, equals: .missingEntry("checksums.json")
        )
    }

    func testUnsupportedPackageVersionFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let older = try fixture.repackaging(package.url) { files in
            files["manifest.json"] = try fixture.rewritingManifest(
                files["manifest.json"]!
            ) { $0["formatVersion"] = 5 }
        }
        await fixture.assertFails(
            older, equals: .unsupportedPackageVersion(5)
        )
        let newer = try fixture.repackaging(package.url) { files in
            files["manifest.json"] = try fixture.rewritingManifest(
                files["manifest.json"]!
            ) { $0["formatVersion"] = 8 }
        }
        await fixture.assertFails(newer, equals: .futurePackageVersion(8))
    }

    /// manifest 声明了附件但包内缺文件 → attachmentMissing。
    func testDeclaredAttachmentMissingFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let attachmentName = try XCTUnwrap(
try fixture.unzip(package.url).keys
                .first(where: { $0.hasPrefix("attachments/") })
        )
        let tampered = try fixture.repackaging(package.url) { files in
            files.removeValue(forKey: attachmentName)
        }
        await fixture.assertFails(
            tampered,
            equals: .attachmentMissing(id: String(
                attachmentName.dropFirst("attachments/".count).dropLast(4)
            ))
        )
    }

    /// 附件字节被替换（重新打包会重算 CRC，所以 ZIP 层完好）——
    /// 必须由 manifest/checksums 的 SHA-256 抓出来。
    func testTamperedAttachmentBytesFail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let attachmentName = try XCTUnwrap(
try fixture.unzip(package.url).keys
                .first(where: { $0.hasPrefix("attachments/") })
        )
        var corrupted = try XCTUnwrap(
            try fixture.unzip(package.url)[attachmentName]
        )
        corrupted[0] ^= 0xFF
        let tampered = try fixture.repackaging(package.url) { files in
            files[attachmentName] = corrupted
        }
        let reader = PortableBackupPackageReader()
        do {
            _ = try reader.extractAndValidate(
                fileURL: tampered,
                to: fixture.extractionURL
            )
            XCTFail("应拒绝被篡改的附件")
        } catch PortableBackupPackageError.attachmentChecksumMismatch {
            // JPEG 头被翻转后字节数不变、摘要不同——按设计报摘要错。
        } catch PortableBackupPackageError.attachmentSizeMismatch {
            // 兜底：若实现先比大小也算拒绝成功。
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    /// checksums.json 里的摘要被改 → checksumMismatch / attachmentChecksumMismatch。
    func testTamperedChecksumsFileFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let tampered = try fixture.repackaging(package.url) { files in
            var checksums = try XCTUnwrap(
                JSONSerialization.jsonObject(with: files["checksums.json"]!)
                    as? [String: Any]
            )
            var digests = checksums["files"] as! [String: String]
            digests["records.ndjson"] = String(repeating: "0", count: 64)
            checksums["files"] = digests
            files["checksums.json"] = try JSONSerialization.data(
                withJSONObject: checksums, options: [.sortedKeys]
            )
        }
        await fixture.assertFails(
            tampered,
            equals: .checksumMismatch(file: "records.ndjson")
        )
    }

    func testIllegalMIMEFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let tampered = try fixture.repackaging(package.url) { files in
            files["manifest.json"] = try fixture.rewritingManifest(
                files["manifest.json"]!
            ) { manifest in
                var attachments = manifest["attachments"] as! [[String: Any]]
                attachments[0]["mimeType"] = "text/plain"
                manifest["attachments"] = attachments
            }
        }
        let reader = PortableBackupPackageReader()
        do {
            _ = try reader.extractAndValidate(
                fileURL: tampered,
                to: fixture.extractionURL
            )
            XCTFail("应拒绝非法 MIME")
        } catch PortableBackupPackageError.invalidManifest {
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testPathTraversalEntryFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let tampered = try fixture.repackaging(package.url) { files in
            files["../escape.jpg"] = Data([0xFF])
        }
        await fixture.assertFails(
            tampered, equals: .invalidEntryPath("../escape.jpg")
        )
        let absolute = try fixture.repackaging(package.url) { files in
            files["/etc/passwd"] = Data([0xFF])
        }
        await fixture.assertFails(
            absolute, equals: .invalidEntryPath("/etc/passwd")
        )
    }

    func testSymlinkEntryFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let files = try fixture.unzip(package.url)
        let data = try ZipArchive.archive(
            entries: files.sorted(by: { $0.key < $1.key }).map {
                ZipArchive.WriteEntry(name: $0.key, data: $0.value)
            } + [
                // UNIX mode S_IFLNK|0777 —— 符号链接条目必须被拒。
                ZipArchive.WriteEntry(
                    name: "attachments/evil.jpg",
                    data: Data([0x41]),
                    externalAttributes: UInt32(0o120777) << 16
                )
            ]
        )
        let tampered = fixture.uniqueURL("symlink.oboe-backup")
        try data.write(to: tampered)
        await fixture.assertFails(
            tampered,
            equals: .nonRegularFileEntry("attachments/evil.jpg")
        )
    }

    func testDuplicateEntryFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let files = try fixture.unzip(package.url)
        let data = try ZipArchive.archive(
            entries: files.sorted(by: { $0.key < $1.key }).map {
                ZipArchive.WriteEntry(name: $0.key, data: $0.value)
            } + [ZipArchive.WriteEntry(name: "manifest.json", data: Data([0x7B]))]
        )
        let tampered = fixture.uniqueURL("dup.oboe-backup")
        try data.write(to: tampered)
        await fixture.assertFails(
            tampered, equals: .duplicateEntry("manifest.json")
        )
    }

    /// 加密标志位（local header + central directory 两处）必须被拒。
    func testEncryptedEntryFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        var data = try Data(contentsOf: package.url)
        let eocd = data.count - 22
        let cdOffset = Int(fixture.littleEndianUInt32(data, at: eocd + 16))
        data[cdOffset + 8] |= 0x01
        let localOffset = Int(fixture.littleEndianUInt32(data, at: cdOffset + 42))
        data[localOffset + 6] |= 0x01
        let tampered = fixture.uniqueURL("encrypted.oboe-backup")
        try data.write(to: tampered)
        await fixture.assertFails(tampered, equals: .encryptedArchive)
    }

    func testOversizedEntryFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let files = try fixture.unzip(package.url)
        let attachmentName = try XCTUnwrap(
            files.keys.first { $0.hasPrefix("attachments/") }
        )
        let attachmentSize = Int64(files[attachmentName]!.count)
        let recordsSize = Int64(files["records.ndjson"]!.count)
        // 限额夹在 records 与附件之间：records 过、附件拒。
        guard attachmentSize > recordsSize else {
            throw XCTSkip("测试附件小于 records，跳过此断言")
        }
        let limits = PortableBackupPackageLimits(
            maximumEntryBytes: attachmentSize - 1
        )
        do {
            _ = try PortableBackupPackageReader(limits: limits)
                .extractAndValidate(
                    fileURL: package.url,
                    to: fixture.extractionURL
                )
            XCTFail("应拒绝超限条目")
        } catch PortableBackupPackageError.entryTooLarge(
            let name, let actual, let limit
        ) {
            XCTAssertEqual(name, attachmentName)
            XCTAssertEqual(actual, attachmentSize)
            XCTAssertEqual(limit, attachmentSize - 1)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testTotalExtractionLimitFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let files = try fixture.unzip(package.url)
        let total = files.values.reduce(0) { $0 + Int64($1.count) }
        let limits = PortableBackupPackageLimits(
            maximumTotalUncompressedBytes: total - 1
        )
        do {
            _ = try PortableBackupPackageReader(limits: limits)
                .extractAndValidate(
                    fileURL: package.url,
                    to: fixture.extractionURL
                )
            XCTFail("应拒绝超限总量")
        } catch PortableBackupPackageError.totalUncompressedTooLarge(
            let actual, let limit
        ) {
            XCTAssertEqual(actual, total)
            XCTAssertEqual(limit, total - 1)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testTooManyEntriesFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let limits = PortableBackupPackageLimits(maximumEntryCount: 2)
        do {
            _ = try PortableBackupPackageReader(limits: limits)
                .extractAndValidate(
                    fileURL: package.url,
                    to: fixture.extractionURL
                )
            XCTFail("应拒绝过多条目")
        } catch PortableBackupPackageError.tooManyEntries(
            let actual, let limit
        ) {
            XCTAssertEqual(actual, 3)
            XCTAssertEqual(limit, 2)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testUnexpectedEntryFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage()
        let tampered = try fixture.repackaging(package.url) { files in
            files["unexpected.txt"] = Data([0x41])
        }
        await fixture.assertFails(
            tampered, equals: .unexpectedEntry("unexpected.txt")
        )
    }

    func testNonPackageFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let notZip = fixture.uniqueURL("plain.oboe-backup")
        try Data("not a zip".utf8).write(to: notZip)
        XCTAssertFalse(PortableBackupPackageReader.isPackage(fileURL: notZip))
        await fixture.assertFails(notZip, equals: .notAPackage)
    }

    /// MIME 魔数与声明不符：manifest 声称 png 但字节是 jpeg。
    func testMIMETypeMismatchFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let tampered = try fixture.repackaging(package.url) { files in
            files["manifest.json"] = try fixture.rewritingManifest(
                files["manifest.json"]!
            ) { manifest in
                var attachments = manifest["attachments"] as! [[String: Any]]
                attachments[0]["mimeType"] = "image/png"
                attachments[0]["relativePath"] = attachments[0]["relativePath"]
                manifest["attachments"] = attachments
            }
        }
        // relativePath 扩展名 .jpg 与 png 白名单冲突 → 先撞结构校验。
        let reader = PortableBackupPackageReader()
        do {
            _ = try reader.extractAndValidate(
                fileURL: tampered,
                to: fixture.extractionURL
            )
            XCTFail("应拒绝 MIME 不符")
        } catch PortableBackupPackageError.invalidManifest {
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    // MARK: - 恢复准备

    /// 完整闭环：v7 包 → preparePackage → staged 附件目录就绪、
    /// 临时库 attachments 行齐全、image_reference 保留、线上零接触。
    func testPreparePackageStagesAttachmentsAndImports() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 2)
        let imageIDs = package.attachments.map(\.id).sorted()
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        defer { try? current.close() }
        try await fixture.seedDeck(into: current, name: "当前资料")

        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        let prepared = try await preparer.preparePackage(fileURL: package.url)

        XCTAssertEqual(prepared.sourceFormatVersion, 7)
        XCTAssertEqual(prepared.preparedFormatVersion, 7)
        XCTAssertTrue(prepared.restoresInboxData)
        XCTAssertEqual(prepared.attachmentDescriptors.count, 2)
        XCTAssertEqual(
            Set(prepared.attachmentDescriptors.map(\.id)),
            Set(imageIDs)
        )
        let stagedURL = try XCTUnwrap(prepared.stagedAttachmentsDirectoryURL)
        let stagedFiles = try FileManager.default.contentsOfDirectory(
            atPath: stagedURL.path
        ).sorted()
        XCTAssertEqual(stagedFiles, imageIDs.map { "\($0).jpg" }.sorted())

        // 临时库：attachments 行 + inbox 引用保留。
        let imported = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)
        let importedState = try await imported.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachments"),
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT image_reference FROM inbox_items
                        WHERE image_reference IS NOT NULL ORDER BY 1
                        """
                ),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items")
            )
        }
        XCTAssertEqual(importedState.0, 2)
        XCTAssertEqual(importedState.1, imageIDs.sorted())
        XCTAssertEqual(importedState.2, 2)
        try imported.close()

        // 线上库与线上附件目录未被触碰。
        let currentDecks = try await current.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(currentDecks, ["当前资料"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.liveStoreURL.path),
            []
        )

        try await preparer.discard(prepared)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: prepared.temporaryDatabaseURL.path)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    /// 恢复引用未声明的附件 → 降级为 NULL（与 v3–v6 对缺失文件的惯例一致）。
    func testPreparePackageNullsUndeclaredReferences() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)
        let image = try fixture.store.importImage(data: PackageTestImage.make())
        try await fixture.seedInboxItem(into: source, imageReference: image.id)
        try await fixture.seedInboxItem(
            into: source,
            imageReference: "not-in-package"
        )
        let package = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        defer { try? current.close() }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        let prepared = try await preparer.preparePackage(fileURL: package.url)
        defer {
            Task { try? await preparer.discard(prepared) }
        }
        // 一条引用指向包内附件 → 保留；另一条未声明 → 置 NULL。
        let imported = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)
        let counts = try await imported.pool.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM inbox_items WHERE image_reference = ?",
                    arguments: [image.id]
                ),
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM inbox_items WHERE image_reference IS NULL"
                )
            )
        }
        try imported.close()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    /// 失败路径：被篡改的包在 preparePackage 抛错后，preparations 目录
    /// 不留残渣，线上库与线上附件目录完全未动。
    func testFailedPreparationLeavesLiveStateUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try await fixture.exportPackage(attachments: 1)
        let attachmentName = try XCTUnwrap(
try fixture.unzip(package.url).keys
                .first(where: { $0.hasPrefix("attachments/") })
        )
        var corrupted = try fixture.unzip(package.url)[attachmentName]!
        corrupted[0] ^= 0xFF
        let tampered = try fixture.repackaging(package.url) { files in
            files[attachmentName] = corrupted
        }

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        defer { try? current.close() }
        try await fixture.seedDeck(into: current, name: "当前资料")
        let liveImage = try fixture.liveStore.importImage(
            data: PackageTestImage.make()
        )
        let liveStoreContentsBefore = try FileManager.default
            .contentsOfDirectory(atPath: fixture.liveStoreURL.path)

        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        do {
            _ = try await preparer.preparePackage(fileURL: tampered)
            XCTFail("应拒绝被篡改的包")
        } catch {
            // 任意校验错误均可。
        }

        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: fixture.preparationsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "失败的准备残留了文件：\(leftovers)")
        XCTAssertTrue(fixture.liveStore.exists(liveImage.id))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.liveStoreURL.path
            ).sorted(),
            liveStoreContentsBefore.sorted()
        )
        let currentDecks = try await current.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(currentDecks, ["当前资料"])
    }

    /// 内容路由：ZIP magic → v7 路径，NDJSON → 既有 v1–v6 路径。
    func testAutomaticRoutingByContent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)
        let package = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)
        let ndjson = try await PortableBackupExporter(
            database: source,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "6.0-test", at: fixture.exportedAt)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        defer { try? current.close() }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )

        let fromPackage = try await preparer.prepareAutomatically(fileURL: package.url)
        XCTAssertEqual(fromPackage.sourceFormatVersion, 7)
        try await preparer.discard(fromPackage)

        let fromNDJSON = try await preparer.prepareAutomatically(fileURL: ndjson.url)
        XCTAssertEqual(fromNDJSON.sourceFormatVersion, 7)
        XCTAssertNil(fromNDJSON.stagedAttachmentsDirectoryURL)
        try await preparer.discard(fromNDJSON)

        // 扩展名是障眼法：把 ZIP 改名成 .ndjson 也按内容走 v7。
        let renamed = fixture.uniqueURL("renamed.ndjson")
        try FileManager.default.copyItem(at: package.url, to: renamed)
        let fromRenamed = try await preparer.prepareAutomatically(fileURL: renamed)
        XCTAssertEqual(fromRenamed.sourceFormatVersion, 7)
        try await preparer.discard(fromRenamed)
    }

    /// 凭据不出包：records.ndjson 不得包含 AI 密钥串。
    func testPackageContainsNoCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        defer { try? source.close() }
        try await fixture.seedDeck(into: source)
        try await source.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        daily_new_card_limit, retention_preset,
                        auto_play_word_audio, auto_play_example_audio,
                        appearance, ai_provider_id, ai_base_url, ai_model_id,
                        ai_credential_id
                    ) VALUES(
                        1, 1, 'Asia/Shanghai', 10, 90, 1, 0, 'dark',
                        'secret-provider', 'https://secret.example/token',
                        'secret-model', 'secret-credential-id'
                    )
                    """
            )
        }
        let package = try await fixture.makePackageExporter(database: source)
            .export(appVersion: "7.0-test", at: fixture.exportedAt)

        let wholePackage = try Data(contentsOf: package.url)
        XCTAssertNil(wholePackage.range(of: Data("secret".utf8)))
        XCTAssertNil(wholePackage.range(of: Data("credential".utf8)))
        let files = try fixture.unzip(package.url)
        let records = try XCTUnwrap(files["records.ndjson"])
        XCTAssertNil(records.range(of: Data("secret".utf8)))
        XCTAssertNil(records.range(of: Data("ai_base_url".utf8)))
    }

    // MARK: - journal / swap

    func testAttachmentSwapInstallAndRecover() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let parent = fixture.rootURL.appendingPathComponent("swap", isDirectory: true)
        let target = parent.appendingPathComponent("attachments", isDirectory: true)
        let aside = parent.appendingPathComponent("attachments.aside", isDirectory: true)
        let staged = parent.appendingPathComponent("staged", isDirectory: true)
        let journalURL = parent.appendingPathComponent("restore-journal.json")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("old.jpg"))
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("new.jpg"))
        let store = AttachmentRestoreJournalStore(fileURL: journalURL)

        let journal = try AttachmentDirectorySwap.installStagedDirectory(
            stagedURL: staged,
            at: target,
            asideURL: aside,
            journalStore: store
        )
        XCTAssertEqual(journal.phase, .installedNewDirectory)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: target.path),
            ["new.jpg"]
        )
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: aside.path),
            ["old.jpg"]
        )

        try AttachmentDirectorySwap.completeSwap(
            journal: journal,
            journalStore: store
        )
        XCTAssertFalse(fileManager.fileExists(atPath: aside.path))
        XCTAssertNil(try store.load())
    }

    /// 崩溃窗口期恢复：journal 停在 movedCurrentAside 且 target 缺失 →
    /// aside 移回原位，线上目录内容还原。
    func testAttachmentSwapRecoveryRollsBackAside() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let parent = fixture.rootURL.appendingPathComponent("swap2", isDirectory: true)
        let target = parent.appendingPathComponent("attachments", isDirectory: true)
        let aside = parent.appendingPathComponent("attachments.aside", isDirectory: true)
        let journalURL = parent.appendingPathComponent("restore-journal.json")
        try fileManager.createDirectory(at: aside, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: aside.appendingPathComponent("old.jpg"))
        let store = AttachmentRestoreJournalStore(fileURL: journalURL)
        try store.save(AttachmentRestoreJournal(
            phase: .movedCurrentAside,
            targetPath: target.path,
            oldPath: aside.path,
            newPath: "/nonexistent/staged"
        ))

        let usedStaged = try AttachmentDirectorySwap
            .recoverInterruptedSwap(journalStore: store)
        XCTAssertEqual(usedStaged, false)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: target.path),
            ["old.jpg"]
        )
        XCTAssertNil(try store.load())
    }
}

// MARK: - 测试夹具

private extension PortableBackupV7PackageTests {
    struct Fixture {
        let rootURL: URL
        let sourceDatabaseURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL
        let extractionURL: URL
        /// 源库用的图片存储（导出从这里读附件）。
        let storeURL: URL
        let store: InboxImageStore
        /// 模拟“线上”附件目录（恢复期间绝不能被碰）。
        let liveStoreURL: URL
        let liveStore: InboxImageStore
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupV7PackageTests-\(UUID().uuidString)",
                isDirectory: true
            )
            sourceDatabaseURL = rootURL.appendingPathComponent("source.sqlite")
            currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
            exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
            preparationsURL = rootURL.appendingPathComponent(
                "preparations",
                isDirectory: true
            )
            extractionURL = rootURL.appendingPathComponent(
                "extraction",
                isDirectory: true
            )
            storeURL = rootURL.appendingPathComponent(
                "source-images",
                isDirectory: true
            )
            store = InboxImageStore(rootDirectoryURL: storeURL)
            liveStoreURL = rootURL.appendingPathComponent(
                "live-images",
                isDirectory: true
            )
            liveStore = InboxImageStore(rootDirectoryURL: liveStoreURL)
            try FileManager.default.createDirectory(
                at: liveStoreURL,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func makePackageExporter(database: OboeDatabase) -> PortableBackupPackageExporter {
            PortableBackupPackageExporter(
                database: database,
                imageStore: store,
                workingDirectoryURL: exportsURL
            )
        }

        /// 导出只含 deck +（可选）附件 inbox 项的最小合法包。
        /// 附件 id 从 `export.attachments` 读。
        @discardableResult
        func exportPackage(
            attachments: Int = 0
        ) async throws -> PortableBackupPackageExport {
            let source = try OboeDatabase(path: sourceDatabaseURL.path)
            defer { try? source.close() }
            try await seedDeck(into: source)
            for _ in 0..<attachments {
                let image = try store.importImage(data: PackageTestImage.make())
                try await seedInboxItem(into: source, imageReference: image.id)
            }
            return try await makePackageExporter(database: source)
                .export(appVersion: "7.0-test", at: exportedAt)
        }

        func seedDeck(
            into database: OboeDatabase,
            name: String = "源牌组"
        ) async throws {
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, ?, 0, 1, 2)
                        """,
                    arguments: [DatabaseValueCodec.encode(UUID()), name]
                )
            }
        }

        func seedInboxItem(
            into database: OboeDatabase,
            imageReference: String?
        ) async throws {
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO inbox_items(
                            id, text, source_type, status, content_revision,
                            image_reference, created_at_ms, updated_at_ms
                        ) VALUES (?, '截图', 'manual', 'unprocessed', 1, ?, 1, 2)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        imageReference.map(Optional.some) ?? nil
                    ]
                )
            }
        }

        func uniqueURL(_ name: String) -> URL {
            rootURL.appendingPathComponent(
                "\(UUID().uuidString.lowercased())-\(name)"
            )
        }

        // MARK: - ZIP 读写（走内部实现，@testable）

        func unzip(_ url: URL) throws -> [String: Data] {
            let reader = try ZipArchive.Reader(data: Data(contentsOf: url))
            var result: [String: Data] = [:]
            for entry in reader.entries where !entry.isDirectory {
                result[entry.name] = try reader.extract(entry)
            }
            return result
        }

        /// 解包 → transform → 重新打包（CRC/sizes 全部重算）。
        /// 这样“篡改”只落在被改字段上，不会误伤容器结构。
        func repackaging(
            _ sourceURL: URL,
            transform: (inout [String: Data]) throws -> Void
        ) throws -> URL {
            var files = try unzip(sourceURL)
            try transform(&files)
            let data = try ZipArchive.archive(
                entries: files.sorted(by: { $0.key < $1.key }).map {
                    ZipArchive.WriteEntry(name: $0.key, data: $0.value)
                }
            )
            let destination = uniqueURL("tampered.oboe-backup")
            try data.write(to: destination)
            return destination
        }

        func rewritingManifest(
            _ data: Data,
            _ mutate: (inout [String: Any]) -> Void
        ) throws -> Data {
            var manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            mutate(&manifest)
            return try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys]
            )
        }

        func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
            UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
        }

        /// 断言 reader 对给定包抛出指定的等值错误。
        func assertFails(
            _ packageURL: URL,
            equals expected: PortableBackupPackageError,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try PortableBackupPackageReader().extractAndValidate(
                    fileURL: packageURL,
                    to: extractionURL
                )
                XCTFail("应抛出 \(expected)", file: file, line: line)
            } catch let error as PortableBackupPackageError {
                XCTAssertEqual(error, expected, file: file, line: line)
            } catch {
                XCTFail("错误类型不符：\(error)", file: file, line: line)
            }
        }
    }
}

/// 确定性测试图片（与 InboxImageTests 同款的纯 ImageIO 生成）。
private enum PackageTestImage {
    static func make() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 120,
            height: 60,
            bitsPerComponent: 8,
            bytesPerRow: 120 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("无法创建测试位图")
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        context.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 40, height: 20))
        guard let image = context.makeImage() else {
            fatalError("无法生成测试图片")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            fatalError("无法创建 JPEG 目标")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
