import Foundation
import OboeDomain
import OboeInfrastructure
import Testing
@testable import Oboe

/// PR 9 App 侧接线契约测试：v7 恢复链路依赖的目录解析、journal 与
/// PreparedRestoration 附件元数据在 app 层可见且语义正确。swap/journal
/// 的完整行为矩阵由 OboeInfrastructureTests 覆盖，这里只钉住 app
/// 依赖的最小契约。
@MainActor
struct AttachmentRestoreWiringTests {

    @Test
    func inboxImagesDirectoryURLDefaultsUnderBaseURL() throws {
        unsetenv("OBOE_UI_TEST_IMAGE_STORE")
        let baseURL = URL(fileURLWithPath: "/tmp/oboe-base", isDirectory: true)
        let resolved = AppBootstrapEnvironment.inboxImagesDirectoryURL(
            baseURL: baseURL
        )
        #expect(
            resolved.standardizedFileURL
                == baseURL.appendingPathComponent("InboxImages", isDirectory: true)
                .standardizedFileURL
        )
    }

    @Test
    func inboxImagesDirectoryURLHonoursUITestOverride() throws {
        let override = "/tmp/oboe-images-override"
        setenv("OBOE_UI_TEST_IMAGE_STORE", override, 1)
        defer { unsetenv("OBOE_UI_TEST_IMAGE_STORE") }
        let resolved = AppBootstrapEnvironment.inboxImagesDirectoryURL(
            baseURL: URL(fileURLWithPath: "/tmp/oboe-base", isDirectory: true)
        )
        #expect(resolved.path == override)
    }

    @Test
    func preparedRestorationCarriesAttachmentMetadata() throws {
        let descriptor = AttachmentDescriptor(
            id: "a1b2c3",
            relativePath: "attachments/a1b2c3.jpg",
            mimeType: "image/jpeg",
            byteCount: 2_048,
            sha256: String(repeating: "0", count: 64),
            pixelWidth: 100,
            pixelHeight: 80
        )
        let workingURL = FileManager.default.temporaryDirectory
        let preparation = PreparedRestoration(
            id: UUID(),
            temporaryDatabaseURL: workingURL.appendingPathComponent(
                "prepared-\(UUID().uuidString.lowercased()).sqlite"
            ),
            sourceFilename: "backup.oboebackup",
            sourceFormatVersion: 7,
            preparedFormatVersion: 7,
            sourceAppVersion: "1.0",
            exportedAt: Date(),
            backup: PortableBackupDataSummary(recordCounts: [:]),
            current: PortableBackupDataSummary(recordCounts: [:]),
            excludedScopes: [],
            stagedAttachmentsDirectoryURL: workingURL.appendingPathComponent(
                "staged-attachments-\(UUID().uuidString.lowercased())",
                isDirectory: true
            ),
            attachmentDescriptors: [descriptor]
        )
        #expect(preparation.attachmentDescriptors == [descriptor])
        #expect(preparation.stagedAttachmentsDirectoryURL != nil)
        #expect(preparation.sourceFormatVersion == 7)
    }

    @Test
    func journalStoreRoundTripsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AttachmentRestoreJournalStore(
            fileURL: directory.appendingPathComponent("swap.json")
        )
        #expect(try store.load() == nil)

        let journal = AttachmentRestoreJournal(
            phase: .movedCurrentAside,
            targetPath: "/tmp/target",
            oldPath: "/tmp/aside",
            newPath: "/tmp/staged"
        )
        try store.save(journal)
        #expect(try store.load() == journal)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test
    func recoverInterruptedSwapRestoresAsideWhenTargetMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let target = root.appendingPathComponent("InboxImages", isDirectory: true)
        let aside = root.appendingPathComponent("aside", isDirectory: true)
        let store = AttachmentRestoreJournalStore(
            fileURL: root.appendingPathComponent("journal.json")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try "old".write(to: aside.appendingPathComponent("x.jpg"), atomically: true, encoding: .utf8)
        try store.save(
            AttachmentRestoreJournal(
                phase: .movedCurrentAside,
                targetPath: target.path,
                oldPath: aside.path,
                newPath: root.appendingPathComponent("staged").path
            )
        )

        let installed = try AttachmentDirectorySwap.recoverInterruptedSwap(
            journalStore: store
        )
        #expect(installed == false)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("x.jpg").path))
        #expect(try store.load() == nil)
    }
}
