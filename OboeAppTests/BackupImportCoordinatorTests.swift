import Foundation
import XCTest
@testable import Oboe
import OboeDomain
import OboeInfrastructure

/// S11 统一备份导入协调器测试：security-scope→staging→全量校验
/// →preview→确认 链路、串行接收、同源去重、冷启动暂存与取消语义。
@MainActor
final class BackupImportCoordinatorTests: XCTestCase {

    private final class Fixture {
        let baseURL: URL
        let database: OboeDatabase
        let container: AppFeatureContainer
        let backupFileURL: URL

        init(
            baseURL: URL,
            database: OboeDatabase,
            container: AppFeatureContainer,
            backupFileURL: URL
        ) {
            self.baseURL = baseURL
            self.database = database
            self.container = container
            self.backupFileURL = backupFileURL
        }

        func remove() {
            try? database.close()
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    /// 真实容器 + 真实导出文件：prepare 走完整校验链。
    private func makeFixture() async throws -> Fixture {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: baseURL, withIntermediateDirectories: true
        )
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: baseURL.appendingPathComponent(
                "Snapshots", isDirectory: true
            )
        )
        let database = try await lifecycle.open()
        guard let built = AppFeatureContainerFactory.makeServices(
            database: database,
            generation: 1,
            baseURL: baseURL,
            bootstrap: AppBootstrapEnvironment(),
            adaptiveInvalidationCenter: AdaptiveInvalidationCenter()
        ) else {
            throw XCTSkip("容器构建失败（内置词库缺失时跳过）。")
        }
        let container = built.container
        _ = try await container.decks.deckService.createDeck(named: "备份测试")
        let export = try await container.settings.exporter.export(
            appVersion: "0.6.0-test"
        )
        return Fixture(
            baseURL: baseURL,
            database: database,
            container: container,
            backupFileURL: export.url
        )
    }

    /// 等到 prepared/errorMessage 其一出现；超时即失败。
    private func awaitSettled(
        _ coordinator: BackupImportCoordinator
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while coordinator.prepared == nil,
              coordinator.errorMessage == nil,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            coordinator.prepared != nil || coordinator.errorMessage != nil,
            "协调器在超时内既未就绪也未报错。"
        )
    }

    func testSubmitProducesPreparedAfterFullVerification() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let coordinator = BackupImportCoordinator()
        coordinator.configure(
            preparer: fixture.container.settings.restorationPreparer,
            apply: { _ in },
            discard: { _ in }
        )

        coordinator.submit(fixture.backupFileURL)
        try await awaitSettled(coordinator)

        XCTAssertNil(coordinator.errorMessage)
        let prepared = try XCTUnwrap(coordinator.prepared)
        XCTAssertEqual(prepared.sourceFormatVersion, 7)
        XCTAssertEqual(prepared.backup.deckCount, 1)
        XCTAssertFalse(coordinator.isVerifying)
    }

    func testDuplicateSubmitOfSameURLIsDeduped() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let coordinator = BackupImportCoordinator()
        coordinator.configure(
            preparer: fixture.container.settings.restorationPreparer,
            apply: { _ in },
            discard: { _ in }
        )

        coordinator.submit(fixture.backupFileURL)
        coordinator.submit(fixture.backupFileURL)
        coordinator.submit(fixture.backupFileURL)
        try await awaitSettled(coordinator)

        // 同一来源三次投递只消化出一个 prepared（去重+串行）。
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNotNil(coordinator.prepared)
        coordinator.discardPrepared()
        XCTAssertNil(coordinator.prepared)
        // 队列消化完不再有第二次校验产出。
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(coordinator.prepared)
    }

    func testNonFileURLRejected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let coordinator = BackupImportCoordinator()
        coordinator.configure(
            preparer: fixture.container.settings.restorationPreparer,
            apply: { _ in },
            discard: { _ in }
        )

        coordinator.submit(URL(string: "https://example.com/backup")!)

        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertNil(coordinator.prepared)
    }

    func testColdStartSubmissionReplaysAfterConfigure() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let coordinator = BackupImportCoordinator()

        // 冷启动到达：容器未配置，URL 入队不消化。
        coordinator.submit(fixture.backupFileURL)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(coordinator.prepared)
        XCTAssertNil(coordinator.errorMessage)

        coordinator.configure(
            preparer: fixture.container.settings.restorationPreparer,
            apply: { _ in },
            discard: { _ in }
        )
        try await awaitSettled(coordinator)

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertNotNil(coordinator.prepared)
    }

    func testConfirmAppliesAndClears() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let coordinator = BackupImportCoordinator()
        var applied: PreparedRestoration?
        coordinator.configure(
            preparer: fixture.container.settings.restorationPreparer,
            apply: { preparation in applied = preparation },
            discard: { _ in }
        )
        coordinator.submit(fixture.backupFileURL)
        try await awaitSettled(coordinator)
        let prepared = try XCTUnwrap(coordinator.prepared)

        try await coordinator.confirmPrepared()

        XCTAssertEqual(applied?.id, prepared.id)
        XCTAssertNil(coordinator.prepared)
    }

    func testDiscardPreparedReleasesWithoutApplying() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let coordinator = BackupImportCoordinator()
        var applied = false
        coordinator.configure(
            preparer: fixture.container.settings.restorationPreparer,
            apply: { _ in applied = true },
            discard: { _ in }
        )
        coordinator.submit(fixture.backupFileURL)
        try await awaitSettled(coordinator)
        XCTAssertNotNil(coordinator.prepared)

        coordinator.discardPrepared()

        XCTAssertFalse(applied)
        XCTAssertNil(coordinator.prepared)
    }
}
