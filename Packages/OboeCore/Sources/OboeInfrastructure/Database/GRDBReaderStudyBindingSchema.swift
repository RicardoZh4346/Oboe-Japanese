import Foundation
import GRDB

/// v24 `reader_study_binding`（v0.7.5，contracts-frozen §6 / decisions D14）。
///
/// 文章 ↔ 专属学习牌组绑定列与 Pipeline 来源去重键：
/// - `reader_documents.study_deck_id`：文档绑定的学习牌组；`REFERENCES
///   decks(id) ON DELETE SET NULL`——删牌组只解绑不陪葬文档。非空部分
///   唯一索引保证**一个牌组至多绑定一个文档**（同名文档可各有同名牌组，
///   按 ID 而非名称区分，§5）。
/// - `study_deck_name_follows_title`：默认跟随文档标题命名；用户手动改
///   牌组名后置 0（§5 生命周期）。
/// - `source_contexts.study_dedup_key`：Pipeline 来源的规范去重键
///   （noteID+documentID+sourceHash+locator+unitID+kind，§4.4/§8.2）。
///   旧行保留 NULL——部分唯一索引只约束新写入，不为建索引删历史重复。
///
/// 注册：`"v24_reader_study_binding"` 由 OboeDatabaseSchema switch 指向
/// 本 migrate；无新表，`tableNames` 不变（仅扩列）。
public enum GRDBReaderStudyBindingSchema {
    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE reader_documents
                ADD COLUMN study_deck_id TEXT
                REFERENCES decks(id) ON DELETE SET NULL;

            ALTER TABLE reader_documents
                ADD COLUMN study_deck_name_follows_title INTEGER NOT NULL
                DEFAULT 1
                CHECK (study_deck_name_follows_title IN (0, 1));

            CREATE UNIQUE INDEX reader_documents_on_study_deck
                ON reader_documents(study_deck_id)
                WHERE study_deck_id IS NOT NULL;

            ALTER TABLE source_contexts
                ADD COLUMN study_dedup_key TEXT;

            CREATE UNIQUE INDEX source_contexts_on_study_dedup_key
                ON source_contexts(study_dedup_key)
                WHERE study_dedup_key IS NOT NULL;
            """)
    }
}
