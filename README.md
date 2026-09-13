# Oboe

Oboe 是一个开源、离线优先的 iPhone 日语间隔重复应用。它支持手动或 AI 辅助制卡、FSRS-6 复习、日语搜索与系统发音、内置 JLPT 参考词库，以及可验证的完整备份和恢复。应用没有账号、业务后端或云同步，AI 默认关闭。

当前版本为 **0.1.0（构建号 1）**，最低支持 iOS 17，仅支持 iPhone。项目目前没有 App Store 上架计划，也不包含开发团队、证书、描述文件或商店上传配置。GitHub Release 提供的是未签名 IPA，安装前必须使用你自己的签名方式重新签名。

## 功能

- 牌组、单词、语法、例句、标签、收藏、重复提示和多卡片方向；
- FSRS-6 调度、每日新卡额度、04:00 学习日、四档评分、撤销、统计与历史；
- 日文、假名、平/片假名、半角及中文本地搜索；
- 内置 8,334 个社区 JLPT N5–N1 参考词汇，可离线浏览、搜索、朗读并幂等导入牌组；
- 使用设备 `ja-JP` 系统语音朗读单词和例句，核心学习流程可在飞行模式使用；
- 明文 `.oboe-backup` 全量导出、严格预检、完整替换恢复和三份本机滚动快照；
- DeepSeek 预设及自定义 Chat Completions 兼容服务，API Key 只存 Keychain；
- AI 单词/语法候选、句子分析和选中项目批量制卡，全部经本地校验与用户确认；
- 跟随系统、浅色和深色外观，支持辅助功能字号、小屏布局和 VoiceOver 语义。

## 环境、构建与测试

需要 macOS、Xcode 16.3+、Swift 6.1+ 和 iOS 17+ Simulator。已验证工具链为 macOS 26.6.2、Xcode 26.6、Swift 6.3.3 和 iOS 26.5 Simulator。SwiftPM 锁定 GRDB 7.11.1 与 `swift-fsrs` revision `4fbaf20184d62f82a9f44f343337c61a2c5483e9`。

```sh
swift test --package-path Packages/OboeCore

xcodebuild -project Oboe.xcodeproj -scheme Oboe \
  -destination 'generic/platform=iOS Simulator' clean build
```

模拟器 UI 测试：

```sh
xcodebuild -project Oboe.xcodeproj -scheme Oboe \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' test
```

也可以直接用 Xcode 打开 `Oboe.xcodeproj`，选择 iOS 17+ iPhone Simulator 后运行。可运行的模拟器构建不要设置 `CODE_SIGNING_ALLOWED=NO`，否则安装时会缺少 Keychain entitlement；CI 中禁用签名的命令只用于编译检查。

### 安装到自己的 iPhone

1. 打开 `Oboe.xcodeproj`，在 Oboe target 的 Signing & Capabilities 中选择自己的开发团队。
2. 把占位 Bundle ID `org.example.Oboe` 改成你有权使用的唯一 Bundle ID。
3. 保留 Keychain Sharing 和 `$(AppIdentifierPrefix)$(CFBundleIdentifier)` access group。
4. 连接并信任 iPhone，开启开发者模式，选择该设备后运行。

GitHub Release 中的 IPA 为 arm64 未签名构建，不能直接安装。第三方侧载工具不属于 Oboe，也不受本项目维护或担保；重签可能改变 Bundle ID 和 Keychain access group，因此旧安装保存的 API Key 可能无法继续读取。

## 数据、隐私与网络边界

牌组、知识点、卡片调度、评分历史、草稿和设置默认只保存在 App 容器。Oboe 不包含广告、行为分析 SDK、远程崩溃收集或云同步，不自动读取剪贴板，也不申请相机、麦克风、通讯录或定位权限。手动学习、词库浏览与搜索、复习、系统 TTS、备份和恢复都不要求网络。

AI 默认关闭。只有用户主动启用并点击连接测试、生成草稿或分析句子时，当前输入与所选语境才会发送到用户配置的 AI 服务；整个牌组、评分历史和本机数据库不会自动上传。API Key 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存入 iOS Keychain，不写入 SQLite、UserDefaults、日志或可携带备份，并与服务类型及 HTTPS 主机绑定。跨来源重定向不会携带 Authorization。

AI 服务由用户选择并直接连接，其数据保留、移动端直连限制和地区政策由对应服务商决定。当前版本没有诊断上传功能。卸载 App 会由 iOS 删除应用容器里的学习数据库和本机快照；用户另行导出的备份由用户自行管理。

## 备份格式与恢复

`.oboe-backup` v2 是未压缩、未加密的 UTF-8 NDJSON，采用固定记录顺序和 SHA-256 footer。它包含知识点、内置词条来源标识、例句、标签、卡片、FSRS 配置、评分历史、学习日、今日任务、草稿和非敏感学习设置；不包含内置只读词库本身、API Key、AI 连接配置、搜索派生索引或本机快照。

v2 在 v1 的 `note` 记录上增加可空的 `source_ref`，用于保留 `origin=builtin_jlpt` 的稳定来源标识，使恢复后的重复导入仍可幂等跳过。Oboe 继续兼容 v1；v1 恢复时 `source_ref` 按 `null` 处理。未来格式版本和未知调度算法会被旧版 App 明确拒绝，不会猜测导入或静默重置卡片。

导出与完整恢复流程：

1. 在“设置 → 数据管理”选择“导出全部学习数据”，通过系统文件选择器保存到可信位置。
2. 恢复前再次导出当前数据，然后选择“检查备份并预览”。
3. App 会在临时区检查版本、大小、UTF-8/LF、行格式、记录顺序、数量、SHA-256、外键、调度状态和算法版本；预检不会修改当前数据库。
4. 对比当前与备份的牌组、知识点、卡片、历史和草稿数量，再确认“完整替换并恢复”。这是整体替换，不是合并导入。
5. 恢复后检查今日页、牌组、搜索和历史，并重启 App 确认数据保持。

替换前 App 会创建回滚快照并关闭旧连接；安装、完整性检查、搜索索引重建或今日计划校正失败时自动回滚，进程中断后也会在下次启动时选择已验证的新库或原库。当前设备的 AI 连接配置和 Keychain 凭据不会被备份内容替换。

本机快照每日最多一份，滚动保留最近三份，也可手动创建和恢复。快照与 App 同处一个设备，不能防止卸载、设备丢失或系统抹除，不能替代保存到 App 外部的可携带备份。

## 内置 JLPT 词汇库

Oboe 随 App 提供只读 SQLite 衍生数据库，包含 8,334 个社区整理的 JLPT N5–N1 参考词汇：N5 662、N4 632、N3 1,784、N2 1,793、N1 3,463。这不是 JLPT 官方固定词表。

词库支持日文、假名和中文搜索，展示英文释义与日英例句，并使用系统日语语音朗读。用户可导入单词或整级词汇；稳定 `source_ref` 确保重复导入不会覆盖正文或重置 Card/FSRS 进度。缺少可靠中文匹配的词仍可浏览，但单条导入前需补充中文释义，整级导入时会跳过。批量导入按批次提交，取消或失败后可继续。

数据集版本为 `2026.09.13-1`：OpenJLPT revision `c42fd9fa3777bfc1775446f7c418d549dfd6e4cf`，Tomoshi Dictionary Open Data `v2026-09-02`（revision `88955b3af9cce9fd2a2d8a58eaaca43d9e72ffd7`）。其中 8,168 条获得唯一简体中文匹配，166 条未匹配，13 条存在歧义；包含 14,362 条例句，词条覆盖率 89.3329%。SQLite 已通过 `quick_check`、外键、schema/meta 和等级精确词数校验。

词形、读音、英文释义与例句来自 [OpenJLPT](https://github.com/evanclan/OpenJLPT) 及其注明的上游数据，简体中文释义、词性和频率来自 [Tomoshi Dictionary Open Data](https://github.com/tomoshi-app/tomoshi-dict-data)。衍生数据库整体按 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode) 提供，不受应用代码 MIT 许可覆盖；Tatoeba 例句适用 [CC BY 2.0 FR](https://creativecommons.org/licenses/by/2.0/fr/)。完整版本锁定、上游权利人、修改方式和署名随数据库保存在 `OboeApp/Resources/JLPT/NOTICE.txt`，并可在 App 的“设置 → 关于 Oboe → 内置 JLPT 词库来源”查看。不得用 Tomoshi 的名称或 logo 暗示背书关系。

重建词库需要显式提供 OpenJLPT 目录和 Tomoshi SQLite；脚本运行时只使用 Python 标准库，App 运行时不会下载数据：

```sh
python3 Scripts/build_jlpt_library.py \
  --openjlpt /path/to/OpenJLPT \
  --tomoshi /path/to/tomoshi-dict-open.db \
  --output OboeApp/Resources/JLPT/jlpt-library.sqlite \
  --notice OboeApp/Resources/JLPT/NOTICE.txt \
  --report build/jlpt-library-report.json
```

只校验已提交的数据库：

```sh
python3 Scripts/build_jlpt_library.py --validate-existing \
  --output OboeApp/Resources/JLPT/jlpt-library.sqlite \
  --notice OboeApp/Resources/JLPT/NOTICE.txt
```

## 项目结构

- `OboeApp/`：SwiftUI 应用、功能页面和资源；
- `Packages/OboeCore/`：领域与基础设施 Swift Package；
- `OboeUITests/`：导航、布局、设置和端到端流程测试；
- `Scripts/`：内置 JLPT 词库的生成与验证脚本；
- `.github/workflows/ci.yml`：核心测试、词库校验、模拟器构建和 UI 测试。

## 0.1.0 验证与已知限制

- 核心回归执行 142 项、0 失败，其中 1 项大数据性能测试按设计需显式启用；
- 标准性能数据集包含 10,000 个知识点、20,000 张卡片和 100,000 条评分记录；后端冷启动、首页查询、搜索和评分到下一张的 p95 分别为 5.601 ms、10.280 ms、3.322 ms 和 5.499 ms；
- iPhone SE 模拟器最慢首帧响应为 1.562 秒，小屏、最大辅助功能字号、发音设置和恢复专项回归通过；模拟器结果不等同于较老物理 iPhone 证据；
- iPhone 15 Pro 飞行模式下已验证冷启动、系统 TTS、添加、搜索、复习/撤销、历史、导出、完整恢复、恢复后页面切换和重启保持；
- 内置词库列表、三语搜索、导入幂等、备份 v1/v2 兼容与 UI 专项通过；包含搜索 p95 为 0.872 ms；
- DeepSeek `deepseek-v4-flash` 的既有 50 次自动质量评估未通过严格结构门槛；固定响应和离线业务测试通过，真实 AI 输出仍须由用户审核；
- 当前没有账号、同步、嵌套牌组、Anki/CSV 导入、备份合并或备份加密；系统 TTS 也不提供标准重音词典、真人录音、语速、音色或重音标注设置。

## 贡献

提交变更即表示你有权按项目 MIT 许可证贡献相应内容。请至少运行核心测试和模拟器构建；涉及导航、布局、恢复或设置时还应运行 UI 测试。不要提交 API Key、签名证书、个人 Team ID、真实学习数据、导出的 `.oboe-backup` 或本机数据库；新增词典、语料、音频或牌组前必须记录来源和可再分发许可。

数据库 schema 变化必须使用显式迁移且失败时不得清空原库；调度逻辑应继续通过锁定的 FSRS-6 参考向量与事务测试；备份格式变化必须包含版本迁移、限制和恢复失败测试；派生索引与缓存必须能从数据库事实重建；新功能应包含可访问性标签、错误/空/等待状态和相应测试。

## 许可

Oboe 源代码采用 [MIT License](LICENSE)。GRDB、`swift-fsrs` 与内置数据的版权及许可见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) 和 `OboeApp/Resources/JLPT/NOTICE.txt`，App 内“设置 → 关于 Oboe”也包含第三方声明。内置 JLPT 衍生数据库依 CC BY-SA 4.0 提供，不受应用代码 MIT 许可覆盖。
