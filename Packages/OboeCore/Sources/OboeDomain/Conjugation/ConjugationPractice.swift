import Foundation

/// S15 活用练习域模型与服务（需求 §13 / 技术文档 §12）。
///
/// 隔离红线：practice-only——结果只写 `conjugation_sessions` /
/// `conjugation_practice_attempts`（v21 迁移），**不调用 FSRS、不写
/// review_logs、不动 streak/retention/study_days 统计**。attempt 不持
/// cardID/noteID（练习题不锚定卡——技术文档 §12「不填虚构 cardID」），
/// lemma/读音/类别/形/accepted 答案全部快照入库。

/// 出题请求（词 + 类别 + 目标形）。
public struct ConjugationExercise: Equatable, Sendable, Hashable {
    public let lemma: String
    public let reading: String?
    public let conjugationClass: ConjugationClass
    public let form: ConjugationForm

    public init(
        lemma: String,
        reading: String? = nil,
        conjugationClass: ConjugationClass,
        form: ConjugationForm
    ) {
        self.lemma = lemma
        self.reading = reading
        self.conjugationClass = conjugationClass
        self.form = form
    }
}

/// 一道已生成的活用题（含判分所需的完整 accepted 快照）。
public struct ConjugationQuestion: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let lemma: String
    public let reading: String?
    public let conjugationClass: ConjugationClass
    public let form: ConjugationForm
    /// 生成规则 id（如 `conj.v5k.causativePassive`）。
    public let ruleID: String
    /// 出题展示串（如「食べる（たべる）→ 使役被动形」）。
    public let prompt: String
    /// accepted 答案快照（判分与会话记录均以它为准）。
    public let accepted: [AcceptedAnswer]

    public init(
        id: UUID, lemma: String, reading: String?,
        conjugationClass: ConjugationClass, form: ConjugationForm,
        ruleID: String, prompt: String, accepted: [AcceptedAnswer]
    ) {
        self.id = id
        self.lemma = lemma
        self.reading = reading
        self.conjugationClass = conjugationClass
        self.form = form
        self.ruleID = ruleID
        self.prompt = prompt
        self.accepted = accepted
    }

    public var primary: String { accepted[0].text }
}

/// 判分结果。
public struct ConjugationGradeResult: Equatable, Sendable {
    public let isCorrect: Bool
    /// 命中的 accepted 答案（incorrect 时 nil）。
    public let matched: AcceptedAnswer?
    /// 规范化后的输入（入库 `normalized_input`）。
    public let normalizedInput: String

    public init(
        isCorrect: Bool, matched: AcceptedAnswer?, normalizedInput: String
    ) {
        self.isCorrect = isCorrect
        self.matched = matched
        self.normalizedInput = normalizedInput
    }
}

/// 练习结果（入库 `result` 列）。
public enum ConjugationAttemptResult: String, Codable, Sendable {
    case correct
    case incorrect
}

/// 练习会话状态。
public enum ConjugationSessionStatus: String, Codable, Sendable {
    case active
    case finished
    /// 中途退出（区别于正常完成；进度行保留）。
    case abandoned
}

/// 练习会话（v21 `conjugation_sessions`）。
public struct ConjugationPracticeSession: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// 计划题数（0 = 自由练习不限量）。
    public let plannedQuestionCount: Int
    public let status: ConjugationSessionStatus
    public let startedAt: Date
    public let finishedAt: Date?

    public init(
        id: UUID,
        plannedQuestionCount: Int,
        status: ConjugationSessionStatus = .active,
        startedAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.plannedQuestionCount = plannedQuestionCount
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// 一次作答记录（v21 `conjugation_practice_attempts`）。
///
/// 幂等：`eventID` 为提交幂等键（UNIQUE）——同 eventID + 同语义字段
/// 的重放返回已存行；内容不一致抛 `conflictingEventID`（与 v16
/// `practice_attempts` 同约）。
///
/// 撤销：`undoneAt` 置位即撤销（软删除），不删行。
public struct ConjugationPracticeAttempt: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let eventID: UUID
    public let sessionID: UUID
    public let questionID: UUID
    // —— lemma 快照（Note/lexeme 删除不影响历史）——
    public let lemma: String
    public let reading: String?
    public let conjugationClass: String
    public let form: String
    public let ruleID: String
    public let prompt: String
    /// 首选标准答案。
    public let expectedPrimary: String
    /// 判分时刻的全部 accepted 文本快照。
    public let acceptedTexts: [String]
    // —— 作答 ——
    public let userInput: String
    public let normalizedInput: String
    public let result: ConjugationAttemptResult
    /// 命中的 accepted 文本（incorrect 为 nil）。
    public let matchedAnswer: String?
    public let durationMilliseconds: Int
    public let answeredAt: Date
    public let undoneAt: Date?

    public init(
        id: UUID, eventID: UUID, sessionID: UUID, questionID: UUID,
        lemma: String, reading: String?, conjugationClass: String,
        form: String, ruleID: String, prompt: String,
        expectedPrimary: String, acceptedTexts: [String],
        userInput: String, normalizedInput: String,
        result: ConjugationAttemptResult, matchedAnswer: String?,
        durationMilliseconds: Int, answeredAt: Date, undoneAt: Date? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.sessionID = sessionID
        self.questionID = questionID
        self.lemma = lemma
        self.reading = reading
        self.conjugationClass = conjugationClass
        self.form = form
        self.ruleID = ruleID
        self.prompt = prompt
        self.expectedPrimary = expectedPrimary
        self.acceptedTexts = acceptedTexts
        self.userInput = userInput
        self.normalizedInput = normalizedInput
        self.result = result
        self.matchedAnswer = matchedAnswer
        self.durationMilliseconds = durationMilliseconds
        self.answeredAt = answeredAt
        self.undoneAt = undoneAt
    }
}

/// 练习错误。
public enum ConjugationPracticeError: Error, Equatable, Sendable {
    /// 同 eventID 不同语义内容的重放。
    case conflictingEventID(UUID)
    case sessionNotFound(UUID)
    /// 会话已结束/放弃，不能再作答。
    case sessionNotActive(UUID)
    /// 时长为负。
    case invalidDuration
}

/// 练习持久化 seam（Domain 协议；GRDB 实现在 Infrastructure）。
/// 实现必须保证：`recordAttempt` 幂等（eventID 语义冲突抛
/// `conflictingEventID`）；`undoLatestAttempt` 只置 `undone_at`；
/// 任何方法不得触碰 review_logs / FSRS / 统计表。
public protocol ConjugationPracticeStore: Sendable {
    func insertSession(_ session: ConjugationPracticeSession) async throws
    func updateSessionStatus(
        id: UUID, status: ConjugationSessionStatus, finishedAt: Date?
    ) async throws
    /// 幂等写：命中既有 eventID 且语义一致 → 返回已存行。
    @discardableResult
    func recordAttempt(
        _ attempt: ConjugationPracticeAttempt
    ) async throws -> ConjugationPracticeAttempt
    /// 撤销该 session 最新一条未撤销 attempt；返回被撤销行或 nil。
    @discardableResult
    func undoLatestAttempt(
        sessionID: UUID, undoneAt: Date
    ) async throws -> ConjugationPracticeAttempt?
    /// 会话内 attempt 列表（`includeUndone=false` 过滤已撤销）。
    func attempts(
        sessionID: UUID, includeUndone: Bool
    ) async throws -> [ConjugationPracticeAttempt]
    func session(id: UUID) async throws -> ConjugationPracticeSession?
}

/// 活用练习服务：出题、判分、会话、结果落存储。
/// 无 FSRS/调度依赖——整类型只依赖 `ConjugationPracticeStore` seam。
public struct ConjugationPracticeService: Sendable {
    private let conjugator: JapaneseConjugator
    private let store: any ConjugationPracticeStore
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        conjugator: JapaneseConjugator = JapaneseConjugator(),
        store: any ConjugationPracticeStore,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.conjugator = conjugator
        self.store = store
        self.now = now
        self.makeID = makeID
    }

    // MARK: 出题

    /// 词+目标形 → 完整题（含 accepted 快照）。类别/形不支持或
    /// lemma 词尾不匹配时抛 `ConjugationError`——上层应据此跳过该词，
    /// 不提供「猜词性」路径。
    public func makeQuestion(
        _ exercise: ConjugationExercise
    ) throws -> ConjugationQuestion {
        let result = try conjugator.conjugate(
            lemma: exercise.lemma,
            reading: exercise.reading,
            conjugationClass: exercise.conjugationClass,
            form: exercise.form)
        let prompt = Self.makePrompt(
            lemma: result.lemma, reading: result.reading,
            form: exercise.form)
        return ConjugationQuestion(
            id: makeID(), lemma: result.lemma, reading: result.reading,
            conjugationClass: exercise.conjugationClass,
            form: exercise.form, ruleID: result.ruleID,
            prompt: prompt, accepted: result.accepted)
    }

    /// 判分（纯函数）：规范化后 ∈ accepted forms。
    public func grade(
        question: ConjugationQuestion,
        input: String
    ) -> ConjugationGradeResult {
        let normalized = SearchTextNormalizer.normalize(input)
        let hit = question.accepted.first { $0.text == normalized }
        return ConjugationGradeResult(
            isCorrect: hit != nil, matched: hit, normalizedInput: normalized)
    }

    // MARK: 会话

    /// 开练：`plannedQuestionCount=0` 表示不限量自由练习。
    public func startSession(
        plannedQuestionCount: Int = 0
    ) async throws -> ConjugationPracticeSession {
        let session = ConjugationPracticeSession(
            id: makeID(),
            plannedQuestionCount: max(0, plannedQuestionCount),
            startedAt: now())
        try await store.insertSession(session)
        return session
    }

    /// 提交一题：判分 + 幂等落 attempt。`eventID` 由调用方持有用于
    /// 重试去重；默认每次调用生成新 event。
    @discardableResult
    public func submitAnswer(
        sessionID: UUID,
        question: ConjugationQuestion,
        input: String,
        durationMilliseconds: Int,
        eventID: UUID? = nil
    ) async throws -> ConjugationPracticeAttempt {
        guard durationMilliseconds >= 0 else {
            throw ConjugationPracticeError.invalidDuration
        }
        guard let session = try await store.session(id: sessionID) else {
            throw ConjugationPracticeError.sessionNotFound(sessionID)
        }
        guard session.status == .active else {
            throw ConjugationPracticeError.sessionNotActive(sessionID)
        }
        let grade = grade(question: question, input: input)
        let attempt = ConjugationPracticeAttempt(
            id: makeID(), eventID: eventID ?? makeID(),
            sessionID: sessionID, questionID: question.id,
            lemma: question.lemma, reading: question.reading,
            conjugationClass: question.conjugationClass.rawValue,
            form: question.form.rawValue, ruleID: question.ruleID,
            prompt: question.prompt, expectedPrimary: question.primary,
            acceptedTexts: question.accepted.map(\.text),
            userInput: input, normalizedInput: grade.normalizedInput,
            result: grade.isCorrect ? .correct : .incorrect,
            matchedAnswer: grade.matched?.text,
            durationMilliseconds: durationMilliseconds,
            answeredAt: now())
        return try await store.recordAttempt(attempt)
    }

    /// 撤销会话内最新一条未撤销作答（软删除标记）。
    @discardableResult
    public func undoLatestAnswer(
        sessionID: UUID
    ) async throws -> ConjugationPracticeAttempt? {
        guard let session = try await store.session(id: sessionID) else {
            throw ConjugationPracticeError.sessionNotFound(sessionID)
        }
        guard session.status == .active else {
            throw ConjugationPracticeError.sessionNotActive(sessionID)
        }
        return try await store.undoLatestAttempt(
            sessionID: sessionID, undoneAt: now())
    }

    /// 正常结束会话。
    public func finishSession(id: UUID) async throws {
        try await updateStatus(id: id, status: .finished)
    }

    /// 中途放弃（进度行保留，attempts 不删）。
    public func abandonSession(id: UUID) async throws {
        try await updateStatus(id: id, status: .abandoned)
    }

    private func updateStatus(
        id: UUID, status: ConjugationSessionStatus
    ) async throws {
        guard let session = try await store.session(id: id) else {
            throw ConjugationPracticeError.sessionNotFound(id)
        }
        guard session.status == .active else { return }
        try await store.updateSessionStatus(
            id: id, status: status, finishedAt: now())
    }

    // MARK: - 内部

    static func makePrompt(
        lemma: String, reading: String?, form: ConjugationForm
    ) -> String {
        if let reading, !reading.isEmpty, reading != lemma {
            return "\(lemma)（\(reading)）→ \(form.displayName)"
        }
        return "\(lemma) → \(form.displayName)"
    }
}
