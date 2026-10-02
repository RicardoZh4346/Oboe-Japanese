# Oboe

[![CI](https://github.com/RicardoZh4346/Oboe-Japanese/actions/workflows/ci.yml/badge.svg)](https://github.com/RicardoZh4346/Oboe-Japanese/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/RicardoZh4346/Oboe-Japanese)](https://github.com/RicardoZh4346/Oboe-Japanese/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Oboe 是一款开源、离线优先的 iPhone 与 iPad 日语学习应用。它把资料采集、AI 辅助整理、制卡和 FSRS-6 间隔复习放在同一个本地工作流里；没有账号、业务后端或云同步，AI 默认关闭。

当前版本为 **v0.7.5（构建号 58）**，最低支持 iOS / iPadOS 17。

> GitHub Release 提供 arm64 未签名 IPA。安装前需要使用你自己的证书重新签名；项目不包含开发团队、证书、描述文件或 App Store 上传配置。

## v0.7.5 更新

- **学习单元架构**：知识状态升级为义项级学习单元（词条绑定 current 义项 ∪ 笔记载体单元），词典换库同层重绑可追溯；词级「忽略」退出运行态，历史数据保留审计。
- **「太简单」标记**：复习/词典/点词三处可标记，单元 flag + CAS + 事件留痕，约 10 秒可撤销；同单元卡片当场驱逐出会话，跨窗口即时生效。
- **Reader AI 学习管线**：预检→范围→分析→预览→确认→摘要；确认前零写入，manifest 定稿后可断点续跑/取消/暂停，receipt 幂等防重复制卡。
- **Reader 对照翻译**：原文/对照/译文三模式，源文 hash 变更自动重挂锚点，修订链可回滚。
- **牌组进度与双向导航**：牌组行词义数+进度、牌组详情文章覆盖区（暂停词不计入）、Reader↔牌组直达；同单元多牌组一次评分全局刷新。
- **备份 v9 默认导出**：50 类记录（新增学习单元/AI 作业/翻译块/出现记录/覆盖快照），v1–v8 只读恢复；密钥/Prompt/缓存/瞬态不入包。
- **统计学习漏斗**：准备/解析/OOV 与 复用/新增/跳过/太简单 双漏斗 + 覆盖率 v2 快照。

## 主要功能

### 学习与复习

- 单词、语法、例句、标签、收藏、多卡片方向和重复提示；
- FSRS-6 调度、每日新卡额度（按词计）、04:00 学习日、四档评分、撤销、历史与统计；
- 今日页按主牌组学习，牌组详情可按单个牌组学习，显示真实的剩余、新卡、已完成和结束统计；
- 30 天逐日学习统计与连续学习天数，撤销后同步更新；
- 学习统计概览、记忆保持、复习预测与易错弱点按冻结口径聚合；
- 自适应复习按评分历史识别易错卡，易错中心支持暂停、恢复与跳转编辑，同一词的多方向卡不连续出现；
- 可选「中文→日文输入」与「听力输入」回忆（新用户默认开启），作答后与标准答案逐字对比再自评；听力卡问题面不泄题、语音不可用时安全降级；
- AI 修卡对易错卡给出最小上下文建议，逐字段预览差异、显式确认后原子写入；
- 牌组内可按预设、标签、JLPT、收藏与顺序创建专项学习；练习模式不改变 FSRS，提前调度模式写入正式复习记录；
- 设备 `ja-JP` 系统语音朗读，核心学习流程可在飞行模式使用。
- Cloze 句子挖空卡与词汇卡共用同一复习管线：正面遮罩、四档评分、撤销、专项「仅练习」隔离；每条 sentence 笔记恰好一条挖空定义与一张挖空卡。
- 活用练习覆盖 13 种活用形与各词性，含不规则动词；练习次、正确率单独记录，不写正式调度。
- iPhone / 窄窗口使用双 Tab 与设置齿轮；常规宽度 iPad 使用自适应侧边栏和多栏导航，并支持常用键盘快捷键。

### 阅读与挖词

- 个人图书馆支持粘贴文本、TXT、EPUB（非 DRM 可重排）、SRT、VTT 五种输入；流式解析与按块渲染，大文件不阻塞滚动；章节导航、书签、阅读位置与进度跨启动保留。
- 正文按 token 形态学切分，词汇知识状态实时着色（unknown/learning/known/ignored），覆盖率先按已分析部分标注、不冒充全书覆盖。
- 点词唤起词典详情（原形/假名/活用形归一），可直接制卡或创建挖空卡；Inspector 支持多选批量挖词，重复挖取由 receipt 幂等去重。
- 未知词分页列表与覆盖率趋势可按词典/形态学版本分段回看；删除文档不清除历史统计。
- 原文文件只保存在本机受控目录，不进入备份；换机恢复后可在库内重新关联原文（SHA-256 或 canonical hash 命中）。

### 采集与制卡

- 手动输入和用户主动触发的 `UIPasteControl` 粘贴，不在后台读取剪贴板；
- 系统分享扩展接收文本，并通过 App Group 队列交给主 App；
- 本机 Vision OCR 支持图片预览、文本块选择、编辑和失败后的手动输入；
- 收集箱统一承接四种来源，可搜索、编辑、归档、删除和继续处理；
- 受控词性集合（名词、动词、形容词等）应用于手动编辑、AI 生成/修卡、句子分析和 JLPT 导入；
- 词汇音调按假名读音 mora 数提供 0–N 选项，详情页显示音调位置；
- 多供应商 AI：DeepSeek、Kimi、GLM、ChatGPT / OpenAI API、Claude、Gemini、Qwen、Grok 及自定义 OpenAI 兼容服务；填 Key 后获取模型列表选择模型；Claude 使用 Anthropic Messages、Gemini 使用 Google 原生 generateContent 协议；
- AI 单词/语法候选、句子分析和选中项目批量制卡，保存前均由用户确认。
- 内置 JMdict 离线词典支持日文、假名和常见活用形检索；词条详情可一键预填词汇卡，编辑器内也可直接查词；
- CSV/TSV 五步导入向导（文件→编码→列映射→重复策略→预览确认），UTF-8/UTF-16 BOM 检测、三种重复策略、10 万行有界内存与断点续跑；词汇 CSV 导出为 10 字段、不含内部调度键；
- 制卡时可保存来源句和截图，复习背面显示来源上下文，附件丢失时安全降级。

### 本地资料与数据安全

- 日文、假名、平/片假名、半角及中文本地搜索；
- 内置 8,334 个社区 JLPT N5–N1 参考词汇，带可追溯音调与中文例句翻译，可离线浏览、搜索、朗读并幂等导入；
- 内置 218,807 条 JMdict 词条的只读离线词典，中文释义层按 sense 指纹对齐，未对齐时使用英文释义兜底；
- `.oboe-backup` 全量导出学习数据、来源上下文、专项学习记录与图片附件，提供流式读写、逐文件校验、严格预检、原子恢复和三份本机滚动快照；默认导出为 v9 包（学习单元、AI 作业、翻译块、出现记录与覆盖快照等 50 类记录），恢复端兼容 v1–v8；
- 备份可通过系统分享页（包括 AirDrop）发送，也可从文件 App、AirDrop 或设置入口统一预检并恢复；
- API Key 仅保存在 iOS Keychain，不写入 SQLite、日志或可携带备份；
- 跟随系统、浅色和深色外观，支持辅助功能字号和 VoiceOver 语义。

## 获取与安装

在 [Releases 页面](https://github.com/RicardoZh4346/Oboe-Japanese/releases) 下载 v0.7.5 对应的 `Oboe-v0.7.5.ipa`。该文件是支持 iPhone / iPad 的 **arm64 未签名构建**，需要用自己的 Apple Account 重新签名后安装。以下流程仅首次配置需要电脑，之后可在同一 Wi-Fi 下通过 SideStore 刷新。

已配置 SideStore 的设备也可以直接添加 Oboe 源：打开 [Oboe 侧载源安装页](https://ricardozh4346.github.io/Oboe-Japanese/) 点按「在 SideStore 中添加源」，或在 SideStore / AltStore 的 Sources 页粘贴 `https://ricardozh4346.github.io/Oboe-Japanese/source.json`。添加后可在 My Apps 内直接安装并接收新版本更新提醒，无需再手动下载 IPA。

> iLoader、LocalDevVPN 和 SideStore 均为第三方项目，不属于 Oboe，也不受本项目维护或担保。请只从其官方页面下载，不要向他人发送 Apple Account 验证信息或设备配对文件。

### 准备工作

- 一台运行 iOS / iPadOS 17 或更高版本、已设置锁屏密码的 iPhone 或 iPad；
- 一个 Apple Account；
- 一台用于首次安装的电脑和一根可传输数据的 USB 线；
- 设备与电脑连接到同一 Wi-Fi；蜂窝网络不能替代此连接；
- 从 [iLoader 官网](https://iloader.app/) 或 [iLoader GitHub 仓库](https://github.com/nab138/iloader) 下载 iLoader；
- 按 [SideStore 官方准备指南](https://docs.sidestore.io/docs/installation/prerequisites) 在设备上安装 LocalDevVPN。

### 1. 使用 iLoader 安装 SideStore

1. 通过 USB 将 iPhone 或 iPad 连接到电脑，在两端确认“信任此电脑”。
2. 打开 iLoader，登录 Apple Account，并选择已连接的设备。
3. 选择 **Install SideStore (Stable)**，等待 SideStore 安装完成；iLoader 会同时处理设备配对文件。
4. 在设备上打开“设置 → 通用 → VPN 与设备管理”，选择对应的开发者 App 并确认信任。
5. 打开“设置 → 隐私与安全性 → 开发者模式”，启用后按提示重启并再次确认。
6. 打开 LocalDevVPN，点按 **Connect**。
7. 打开 SideStore，登录与 iLoader 中相同的 Apple Account。
8. 进入 **My Apps**，点按 SideStore 右侧的 **7 DAYS** 完成首次刷新；出现证书撤销或刷新提示时按提示确认。

如 iOS 更新、还原或重新配对后 SideStore 报配对错误，请重新连接电脑，并使用 iLoader 替换配对文件。完整安装流程见 [SideStore 官方安装指南](https://docs.sidestore.io/docs/installation/install)。

### 2. 使用 SideStore 安装 Oboe

1. 在设备上从 [Releases 页面](https://github.com/RicardoZh4346/Oboe-Japanese/releases) 下载 `Oboe-v0.7.5.ipa`，并保存到“文件”App。
2. 确认设备已连接 Wi-Fi，且 LocalDevVPN 处于 **Connected** 状态。
3. 打开 SideStore，进入 **My Apps**，点按右上角 **+**，选择刚下载的 IPA。
4. 等待 SideStore 完成签名与安装，然后从主屏幕启动 Oboe。
5. 免费 Apple Account 签名通常 7 天到期；到期前保持 Wi-Fi 和 LocalDevVPN 已连接，在 SideStore 的 **My Apps** 中刷新 Oboe。

免费 Apple Account 最多同时激活 3 个 App（包含 SideStore），并且 7 天内最多注册 10 个 App ID。安装或刷新失败时，先确认 Wi-Fi 与 LocalDevVPN 均已连接；仍然失败可参考 [SideStore 常见问题](https://docs.sidestore.io/docs/troubleshooting/common-issues)。

重签可能改变 Bundle ID、App Group 和 Keychain access group，因此旧安装中的 API Key 可能无法继续读取；App Group 授权不匹配时，分享扩展会禁用保存并显示签名诊断。

## 开发

需要 macOS、Xcode 16.3+、Swift 6.1+ 和 iOS 17+ Simulator，克隆后需 git-lfs 拉取内置词典产物。自动化覆盖 iPhone 与 iPad Simulator，并已适配 iPad regular `NavigationSplitView`。CI 分两道：`ci.yml`（push/PR）跑 OboeCore 全量（Domain+Infrastructure）、Scripts 工具链单测、词典/JLPT 校验、App 单元测试和 iPhone/iPad navigation smoke，并对每个 job 断言实际执行用例数下限；`ci-heavy.yml`（`workflow_dispatch` 按套件选跑，夜间自动跑 Core 重型子集）覆盖完整 UI 回归（iPhone+iPad）、AX5 大字号切片、门控性能与大导入/EPUB/备份故障注入套件。SwiftPM 锁定：

- GRDB 7.11.1；
- `swift-fsrs` revision `4fbaf20184d62f82a9f44f343337c61a2c5483e9`。

运行核心测试和模拟器构建：

```sh
swift test --package-path Packages/OboeCore

xcodebuild -project Oboe.xcodeproj -scheme Oboe \
  -destination 'generic/platform=iOS Simulator' clean build
```

运行 App 单元测试和 UI 测试：

```sh
xcodebuild -project Oboe.xcodeproj -scheme Oboe \
  -destination 'platform=iOS Simulator,name=<available iPhone>,OS=latest' \
  -only-testing:OboeAppTests test

xcodebuild -project Oboe.xcodeproj -scheme Oboe \
  -destination 'platform=iOS Simulator,name=<available iPhone>,OS=latest' \
  -only-testing:OboeUITests/OboeNavigationUITests/testPrimaryNavigationSmoke test
```

可运行的模拟器构建不要设置 `CODE_SIGNING_ALLOWED=NO`，否则安装时会缺少 Keychain entitlement。CI 中禁用签名的命令只用于编译检查。

## 数据、隐私与网络边界

学习数据库、草稿、收集箱和设置默认只保存在 App 容器。Oboe 不包含广告、行为分析 SDK、远程崩溃收集或云同步，也不申请相机、麦克风、通讯录、定位或全图库权限。

- 粘贴只在用户点击系统粘贴控件时发生。
- 分享扩展只在用户从系统分享页主动保存时运行，并把文本信封写入 App Group 共享队列。
- 图片附件保存在 App 自有受控目录；Vision OCR 全部在本机执行，原图与识别文本不会上传。
- AI 默认关闭。只有用户主动启用并执行测试、生成或分析时，当前输入和所选语境才会发送到用户配置的 AI 服务；整个牌组、评分历史和本机数据库不会自动上传。获取模型列表只把 API Key 发给所选供应商做鉴权，不发送学习内容。ChatGPT 订阅不包含 OpenAI API 额度，两者计费独立。
- API Key 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存入 Keychain，并与服务类型及 HTTPS 主机绑定；跨来源重定向不会携带鉴权头。

AI 服务的数据保留、移动端直连限制和地区政策由对应服务商决定。卸载 App 会由 iOS 删除应用容器中的学习数据库、图片附件和本机快照；用户另行导出的备份需自行保管。

## 备份与恢复

`.oboe-backup` 是未加密的 ZIP 容器，包含 `manifest.json`、`records.ndjson`、`checksums.json` 和可选的 `attachments/`。其中 `records.ndjson` 使用固定记录顺序和 SHA-256 footer，保存学习数据、设置、`note_decks` 成员关系、来源上下文、专项学习会话、练习记录及以下收集箱记录：

- `inboxItem`；
- `inboxProcessingContext`；
- `captureImportReceipt`；
- `inboxCommitReceipt`。

备份会把收集箱及来源上下文引用的图片附件连同 MIME、大小、SHA-256 和像素元数据写入包内，并以 256KiB 分块流式读写。备份仍不包含 API Key、AI 连接配置、内置只读词库、搜索派生索引、本机快照或尚未导入的共享队列文件；易错与趋势属派生数据，恢复后由评分日志重建。

v8 记录协议在此基础上新增 15 类记录：Reader 文档/章节元数据、阅读位置与书签、Cloze 挖空定义、词元与词汇知识覆盖、阅读事件/挖词回执/覆盖率快照、CSV 导入作业与行回执、活用练习会话与记录。v9 再增 14 类（共 50 类）：义项级学习单元与知识事件、「太简单」标记、Reader AI 学习作业/解析/选择/回执、对照翻译块、出现记录与覆盖率 v2 快照。Reader 正文本体（`reader_blocks`）、安装态资产路径（`reader_assets`）、分词缓存（`reader_token_cache`）、词典产物台账/绑定与导入暂存文件**不进入备份**：恢复后 Reader 文档先落为 `missing`，由「重新关联原文」流程按 `source_sha256` 或 canonical hash 校验后重建章块并回到 `available`；同机恢复若文件仍在原位则自动自愈。Cloze 卡保存独立句子快照，原文缺失或被删除不影响复习。

App 默认导出 v9 包；v1–v8 备份仍可恢复，旧格式只读、不再生成。旧版本 App 无法读取 v9 包，跨版本迁移请先升级两端到 v0.7.5。

恢复前 App 会检查 ZIP 结构、路径穿越、符号链接、压缩与解压限额、CRC、逐文件 SHA-256、附件类型和像素，以及记录格式、数量、外键、调度状态和算法版本；预检不修改当前数据库。正式恢复是**完整替换**而不是合并导入：恢复窗口先关门抽干在册的导入/挖词任务（配合世代屏障拒绝陈旧写入），数据库与附件在临时位置准备，附件目录通过 journal 记录的原子交换安装，失败或进程中断时自动回滚或完成收敛。Oboe 可按内容自动识别并恢复 v1～v6 明文 NDJSON 与 v7–v9 附件包；旧备份缺失的新增字段会补默认值，缺失图片安全降级，并明确拒绝未来格式、未知调度算法和版本不一致的包。

## 内置 JLPT 词汇库

Oboe 随 App 提供只读 SQLite 衍生数据库，共 8,334 个社区整理的 JLPT N5–N1 参考词汇：N5 662、N4 632、N3 1,784、N2 1,793、N1 3,463。这不是 JLPT 官方固定词表。

当前随 App 提交的数据集为 schema v2 / `2026.09.21-2`，已为 8,132 个词补充可追溯音调（另 202 个无法可靠匹配的词合法保持 NULL），并为全部 14,362 条既有例句补充非空简体中文翻译。来源包括 [OpenJLPT](https://github.com/evanclan/OpenJLPT)、[Tomoshi Dictionary Open Data](https://github.com/tomoshi-app/tomoshi-dict-data)、UniDic CWJ、kanjium、Tatoeba 和构建期离线 OPUS-MT。衍生数据库整体按 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode) 提供；Tatoeba 文本适用 [CC BY 2.0 FR](https://creativecommons.org/licenses/by/2.0/fr/)，OPUS-MT 模型适用 Apache 2.0。完整版本锁定、署名和许可见 `OboeApp/Resources/JLPT/NOTICE.txt`。

schema v2 离线构建边界由 `Scripts/jlpt_sources_v2.json` 锁定：OpenJLPT、Tomoshi、UniDic CWJ 3.1.0、kanjium 和 2026-09-19 Tatoeba 日中导出的每个实际输入都记录版本、下载地址、字节数、SHA-256、许可与署名。构建脚本**不会下载网络内容**，只读取命令行明确传入的本地文件；任一文件缺失、大小/哈希不符或许可元数据缺失都会在创建输出前失败。UniDic、Tomoshi 和 Tatoeba 原始大文件不得放入 `OboeApp`，也不随 App 分发。

已审核翻译覆盖位于 `Scripts/JLPTData/example-translations-zh.jsonl`，模型、运行时和 Tatoeba 英文补充输入由 `Scripts/jlpt_translation_model_v1.json` 固定。若需要重新生成覆盖文件，先在隔离 Python 3.9 环境安装 manifest 中锁定的依赖，并执行：

```sh
python Scripts/generate_jlpt_translations.py \
  --jlpt /path/to/base-jlpt-library.sqlite \
  --tatoeba-jpn /path/to/jpn_sentences.tsv.bz2 \
  --tatoeba-cmn /path/to/cmn_sentences.tsv.bz2 \
  --tatoeba-links /path/to/jpn-cmn_links.tsv.bz2 \
  --tatoeba-eng /path/to/eng_sentences.tsv.bz2 \
  --tatoeba-eng-cmn-links /path/to/eng-cmn_links.tsv.bz2 \
  --model /path/to/opus-mt-en-zh \
  --model-manifest Scripts/jlpt_translation_model_v1.json \
  --review-overrides Scripts/JLPTData/example-translations-zh-overrides.json \
  --generated-at 2026-09-21T00:00:00+00:00 \
  --output /tmp/example-translations-zh.jsonl \
  --report /tmp/translation-quality-report.json
```

使用锁定输入和已审核覆盖重建 schema v2（路径按本机下载/解压位置替换，`--generated-at` 必须显式固定）：

```sh
python3 Scripts/build_jlpt_library.py \
  --source-manifest Scripts/jlpt_sources_v2.json \
  --openjlpt /path/to/OpenJLPT \
  --tomoshi /path/to/tomoshi-dict-open.db \
  --unidic-cwj /path/to/unidic-cwj-3.1.0-full/lex_3_1.csv \
  --kanjium /path/to/kanjium/accents.txt \
  --tatoeba-jpn /path/to/jpn_sentences.tsv.bz2 \
  --tatoeba-cmn /path/to/cmn_sentences.tsv.bz2 \
  --tatoeba-links /path/to/jpn-cmn_links.tsv.bz2 \
  --translation-coverage Scripts/JLPTData/example-translations-zh.jsonl \
  --translation-model-manifest Scripts/jlpt_translation_model_v1.json \
  --quality-report-dir /tmp/jlpt-pitch-quality \
  --generated-at 2026-09-21T00:00:00+00:00 \
  --output /tmp/jlpt-library-v2.sqlite \
  --notice /tmp/JLPT-NOTICE.txt \
  --report /tmp/jlpt-build-report.json
```

相同锁定输入连续两次重建的数据库 SHA-256 均为 `45e20e715c1ceaa2594fca08377b3dcce0829016867e9aba3e9633f9bcc3f45c`。

校验已提交的数据库：

```sh
python3 Scripts/build_jlpt_library.py --validate-existing \
  --output OboeApp/Resources/JLPT/jlpt-library.sqlite \
  --notice OboeApp/Resources/JLPT/NOTICE.txt
```

## 内置日语词典

v0.6.0 随 App 提供独立只读 SQLite 词典，共 218,807 条 JMdict 词条、253,651 个义项、233,511 个书写形式和 265,701 个读音。词典支持原形、假名与有界反活用查询，不依赖网络，也不会写入用户学习数据库。

数据源由 `Scripts/dictionary_sources_v1.json` 锁定：主词典为 EDRDG 的 JMdict，简体中文释义层来自 Tomoshi Dictionary Open Data，并按每个 JMdict sense 的稳定指纹校验后覆盖；无法可靠对齐的行不进入发布库，界面会明确显示英文兜底。词典 SQLite 不进入可携带备份。

校验已提交的词典：

```sh
python3 Scripts/build_dictionary.py --validate-existing \
  --qa-cases Scripts/DictionaryData/dictionary_qa_cases.json \
  --output OboeApp/Resources/Dictionary/japanese-dictionary.sqlite \
  --notice OboeApp/Resources/Dictionary/NOTICE.txt
```

校验会同时核对数据库、随包许可说明及 QA 样例。

## 项目结构

```text
OboeApp/                   SwiftUI 主应用、功能页面与资源
OboeShareExtension/        系统分享扩展
Packages/OboeCore/         Domain、Infrastructure、共享采集协议
OboeAppTests/              布局、导航状态和恢复接线单元测试
OboeUITests/               导航、布局与端到端 UI 测试
Scripts/                   JLPT、日语词典与 SideStore source 生成/校验工具
distribution/              SideStore/AltStore 静态安装页与 canonical source.json
.github/workflows/         ci.yml（快道）、ci-heavy.yml（重型回归）、release.yml（发布）
```

## 已知限制

- 没有账号、云同步、嵌套牌组、Anki 格式导入、备份合并或备份加密；
- 不支持相机直接拍摄或云 OCR；备份可迁移已进入收集箱的图片附件，尚未导入的分享队列文件不包含在备份内；
- Reader 原文不进入备份：恢复后需在库内重新关联原文文件（SHA-256/canonical hash 校验），否则文档保持 `missing`；默认导出 v9 包；v1–v8 备份可恢复但不可再生成——旧版本 App 无法读取 v9 包，跨版本迁移请先升级两端到 v0.7.5；
- 无 BOM 的 UTF-16 文件若采样前缀全为低 ASCII 内容，可能被误判为 UTF-8；导入向导中可手动指定编码覆盖；
- 10MB 病态单章 EPUB（全书 canonical-hash 扫描）在主机 Release 口径实测约 5.2s，超出 ≤3s 预算行，已按夹具形态记录偏差，真机数据待补；
- iPhone/iPad 模拟器自动化不能替代真机验收；SideStore 安装与刷新、AirDrop 双机传输、VoiceOver 完整走查仍需在对应真机环境验证；
- 克隆仓库需安装 git-lfs（内置词典 SQLite 经 LFS 追踪）；`--validate-existing` 校验脚本可对已有产物复检；
- 系统 TTS 不提供标准重音词典、真人录音、语速、音色或重音标注设置；音调来自 UniDic/kanjium 词典标注，202 个无法可靠匹配的词保持未设置，不做 AI 猜测；
- 音调选择器取值范围由假名读音的 mora 数决定，需先填写读音；
- 表单输入法自动切换需系统已添加对应键盘；
- 免费 Apple ID 重签无法注册 App Group，分享扩展在该环境下可能不可用（主 App 功能不受影响）；
- AI 输出质量取决于用户配置的服务，未做真实服务质量门控，建议内容仍须由用户审核。

## 贡献

请至少运行核心测试和模拟器构建；涉及导航、布局、恢复或设置时还应运行 UI 测试。不要提交 API Key、签名证书、个人 Team ID、真实学习数据、导出的 `.oboe-backup` 或本机数据库。

数据库 schema 变化必须使用显式迁移且失败时不得清空原库；备份格式变化必须说明版本迁移、排除范围和恢复失败行为；调度逻辑应继续通过锁定的 FSRS-6 参考向量与事务测试。

## 许可

Oboe 源代码采用 [MIT License](LICENSE)。GRDB、`swift-fsrs` 与内置数据的版权及许可见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)、`OboeApp/Resources/JLPT/NOTICE.txt` 和 `OboeApp/Resources/Dictionary/NOTICE.txt`。内置 JLPT 衍生数据库和日语词典数据不受应用代码 MIT 许可覆盖，各自适用其来源许可。
