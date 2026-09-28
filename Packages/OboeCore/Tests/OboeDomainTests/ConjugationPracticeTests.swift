import Foundation
import XCTest
@testable import OboeDomain

/// S15 活用练习域服务测试：出题快照、判分规范化、会话生命周期、
/// 撤销、幂等回放、负时长/已结束会话错误。
final class ConjugationPracticeServiceTests: XCTestCase {

    /// 内存 ConjugationPracticeStore（域服务驱动 seam 的 fake）。
    private actor InMemoryStore: ConjugationPracticeStore {
        var sessions: [UUID: ConjugationPracticeSession] = [:]
        var rows: [ConjugationPracticeAttempt] = []

        func insertSession(_ s: ConjugationPracticeSession) async throws {
            sessions[s.id] = s
        }
        func updateSessionStatus(
            id: UUID, status: ConjugationSessionStatus, finishedAt: Date?
        ) async throws {
            guard var s = sessions[id] else {
                throw ConjugationPracticeError.sessionNotFound(id)
            }
            s = ConjugationPracticeSession(
                id: s.id, plannedQuestionCount: s.plannedQuestionCount,
                status: status, startedAt: s.startedAt,
                finishedAt: finishedAt)
            sessions[id] = s
        }
        func recordAttempt(
            _ a: ConjugationPracticeAttempt
        ) async throws -> ConjugationPracticeAttempt {
            if let existing = rows.first(where: { $0.eventID == a.eventID }) {
                guard existing.sessionID == a.sessionID,
                      existing.userInput == a.userInput,
                      existing.result == a.result
                else {
                    throw ConjugationPracticeError.conflictingEventID(
                        a.eventID)
                }
                return existing
            }
            rows.append(a)
            return a
        }
        func undoLatestAttempt(
            sessionID: UUID, undoneAt: Date
        ) async throws -> ConjugationPracticeAttempt? {
            guard let idx = rows.lastIndex(where: {
                $0.sessionID == sessionID && $0.undoneAt == nil
            }) else { return nil }
            let old = rows[idx]
            let undone = ConjugationPracticeAttempt(
                id: old.id, eventID: old.eventID, sessionID: old.sessionID,
                questionID: old.questionID, lemma: old.lemma,
                reading: old.reading,
                conjugationClass: old.conjugationClass, form: old.form,
                ruleID: old.ruleID, prompt: old.prompt,
                expectedPrimary: old.expectedPrimary,
                acceptedTexts: old.acceptedTexts, userInput: old.userInput,
                normalizedInput: old.normalizedInput, result: old.result,
                matchedAnswer: old.matchedAnswer,
                durationMilliseconds: old.durationMilliseconds,
                answeredAt: old.answeredAt, undoneAt: undoneAt)
            rows[idx] = undone
            return undone
        }
        func attempts(
            sessionID: UUID, includeUndone: Bool
        ) async throws -> [ConjugationPracticeAttempt] {
            rows.filter {
                $0.sessionID == sessionID
                    && (includeUndone || $0.undoneAt == nil)
            }
        }
        func session(id: UUID) async throws -> ConjugationPracticeSession? {
            sessions[id]
        }
    }

    private final class ClockBox: @unchecked Sendable {
        var ms: Int64
        init(_ ms: Int64) { self.ms = ms }
        var date: Date {
            Date(timeIntervalSince1970: Double(ms) / 1_000)
        }
    }

    private var store: InMemoryStore!
    private var clock: ClockBox!
    private var service: ConjugationPracticeService!

    override func setUp() {
        store = InMemoryStore()
        clock = ClockBox(1_700_000_000_000)
        let clock = self.clock!
        service = ConjugationPracticeService(
            store: store, now: { clock.date })
    }

    private func exercise(
        _ lemma: String = "食べる", reading: String? = "たべる",
        cls: ConjugationClass = .ichidan, form: ConjugationForm = .te
    ) -> ConjugationExercise {
        ConjugationExercise(
            lemma: lemma, reading: reading,
            conjugationClass: cls, form: form)
    }

    // MARK: - 出题

    func testMakeQuestionCarriesSnapshot() throws {
        let q = try service.makeQuestion(exercise())
        XCTAssertEqual(q.lemma, "食べる")
        XCTAssertEqual(q.conjugationClass, .ichidan)
        XCTAssertEqual(q.form, .te)
        XCTAssertEqual(q.ruleID, "conj.ichidan.te")
        XCTAssertEqual(q.prompt, "食べる（たべる）→ て形")
        XCTAssertEqual(q.accepted.map(\.text), ["食べて", "たべて"])
    }

    func testMakeQuestionUnsupportedFormThrows() {
        XCTAssertThrowsError(try service.makeQuestion(
            exercise("高い", cls: .iAdjective, form: .imperative)
        )) {
            XCTAssertEqual(
                $0 as? ConjugationError,
                .unsupportedForm(.iAdjective, .imperative))
        }
    }

    // MARK: - 判分

    func testGradeAcceptedVariants() throws {
        let q = try service.makeQuestion(
            exercise("食べる", cls: .ichidan, form: .imperative))
        // 规范形 / 等价变体 / 读音表记 全部 accepted
        for input in ["食べろ", "食べよ", "たべろ", "タベヨ"] {
            XCTAssertTrue(
                service.grade(question: q, input: input).isCorrect, input)
        }
        let wrong = service.grade(question: q, input: "食べる")
        XCTAssertFalse(wrong.isCorrect)
        XCTAssertNil(wrong.matched)
        XCTAssertEqual(wrong.normalizedInput, "食べる")
    }

    // MARK: - 会话与作答

    func testSessionLifecycleAndAttempts() async throws {
        let session = try await service.startSession(
            plannedQuestionCount: 3)
        XCTAssertEqual(session.status, .active)

        let q = try service.makeQuestion(exercise())
        let a1 = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 1200)
        XCTAssertEqual(a1.result, .correct)
        XCTAssertEqual(a1.matchedAnswer, "食べて")
        XCTAssertEqual(a1.lemma, "食べる")
        XCTAssertEqual(a1.ruleID, "conj.ichidan.te")
        XCTAssertEqual(a1.acceptedTexts, ["食べて", "たべて"])

        let a2 = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べる", durationMilliseconds: 800)
        XCTAssertEqual(a2.result, .incorrect)
        XCTAssertNil(a2.matchedAnswer)

        let list = try await store.attempts(
            sessionID: session.id, includeUndone: true)
        XCTAssertEqual(list.count, 2)

        try await service.finishSession(id: session.id)
        let finished = try await store.session(id: session.id)
        XCTAssertEqual(finished?.status, .finished)
        XCTAssertNotNil(finished?.finishedAt)
    }

    func testSubmitIdempotentReplay() async throws {
        let session = try await service.startSession()
        let q = try service.makeQuestion(exercise())
        let eventID = UUID()
        let first = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100, eventID: eventID)
        let replay = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100, eventID: eventID)
        XCTAssertEqual(first.id, replay.id)
        let list = try await store.attempts(
            sessionID: session.id, includeUndone: true)
        XCTAssertEqual(list.count, 1)
    }

    func testSubmitConflictingEventID() async throws {
        let session = try await service.startSession()
        let q = try service.makeQuestion(exercise())
        let eventID = UUID()
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100, eventID: eventID)
        await XCTAssertThrowsErrorAsync(
            try await service.submitAnswer(
                sessionID: session.id, question: q,
                input: "食べた", durationMilliseconds: 100,
                eventID: eventID)
        ) {
            XCTAssertEqual(
                $0 as? ConjugationPracticeError,
                .conflictingEventID(eventID))
        }
    }

    func testUndoLatestSoftDeletes() async throws {
        let session = try await service.startSession()
        let q = try service.makeQuestion(exercise())
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100)
        let second = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べた", durationMilliseconds: 200)

        let undone = try await service.undoLatestAnswer(
            sessionID: session.id)
        XCTAssertEqual(undone?.eventID, second.eventID)
        XCTAssertNotNil(undone?.undoneAt)
        // 行保留（includeUndone 仍见），活跃列表只剩 1 条
        let allCount = try await store.attempts(
            sessionID: session.id, includeUndone: true).count
        let activeCount = try await store.attempts(
            sessionID: session.id, includeUndone: false).count
        XCTAssertEqual(allCount, 2)
        XCTAssertEqual(activeCount, 1)
        // 再撤销回滚到第一条
        let undone2 = try await service.undoLatestAnswer(
            sessionID: session.id)
        XCTAssertNotNil(undone2)
        // 无可撤销 → nil（幂等）
        let third = try await service.undoLatestAnswer(
            sessionID: session.id)
        XCTAssertNil(third)
    }

    func testSubmitOnFinishedSessionThrows() async throws {
        let session = try await service.startSession()
        let q = try service.makeQuestion(exercise())
        try await service.finishSession(id: session.id)
        await XCTAssertThrowsErrorAsync(
            try await service.submitAnswer(
                sessionID: session.id, question: q,
                input: "食べて", durationMilliseconds: 1)
        ) {
            XCTAssertEqual(
                $0 as? ConjugationPracticeError,
                .sessionNotActive(session.id))
        }
    }

    func testUnknownSessionThrows() async {
        let q = try! service.makeQuestion(exercise())
        let unknown = UUID()
        await XCTAssertThrowsErrorAsync(
            try await service.submitAnswer(
                sessionID: unknown, question: q,
                input: "x", durationMilliseconds: 1)
        ) {
            XCTAssertEqual(
                $0 as? ConjugationPracticeError, .sessionNotFound(unknown))
        }
        await XCTAssertThrowsErrorAsync(
            try await service.undoLatestAnswer(sessionID: unknown)
        ) {
            XCTAssertEqual(
                $0 as? ConjugationPracticeError, .sessionNotFound(unknown))
        }
    }

    func testNegativeDurationRejected() async throws {
        let session = try await service.startSession()
        let q = try service.makeQuestion(exercise())
        await XCTAssertThrowsErrorAsync(
            try await service.submitAnswer(
                sessionID: session.id, question: q,
                input: "食べて", durationMilliseconds: -1)
        ) {
            XCTAssertEqual(
                $0 as? ConjugationPracticeError, .invalidDuration)
        }
    }
}

/// async 断言辅助：异步表达式在 XCTest autoclosures 里不能直接 `await`。
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected error: \(message)", file: file, line: line)
    } catch {
        handler(error)
    }
}
