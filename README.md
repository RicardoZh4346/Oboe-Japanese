# Oboe

[![CI](https://github.com/RicardoZh4346/Oboe-Japanese/actions/workflows/ci.yml/badge.svg)](https://github.com/RicardoZh4346/Oboe-Japanese/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/RicardoZh4346/Oboe-Japanese)](https://github.com/RicardoZh4346/Oboe-Japanese/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Oboe 是一款开源、离线优先的 iPhone 日语学习应用。它把资料采集、AI 辅助整理、制卡和 FSRS-6 间隔复习放在同一个本地工作流里；没有账号、业务后端或云同步，AI 默认关闭。

当前版本为 **v0.5.5（构建号 48）**，最低支持 iOS 17，仅支持 iPhone。

> GitHub Release 提供 arm64 未签名 IPA。安装前需要使用你自己的证书重新签名；项目不包含开发团队、证书、描述文件或 App Store 上传配置。

## v0.5.5 更新

- **三个根 Tab**：导航精简为「今日 / 牌组 / 设置」，独立「添加」入口移除；新建词汇、语法和句子分析统一从牌组详情进入，JLPT 导入需显式选择目标牌组。
- **今日页重做**：圆形「开始学习」按钮整合连续学习天数、学习状态与主牌组名，下方依次是紧凑任务摘要和「每日统计 / 收集箱」等宽快捷入口；常规字号无需滚动，所有二级及更深页面自动隐藏底部导航。
- **30 天逐日统计与连续天数**：今日页可进入每日统计，按学习日（04:00 边界）展示最近 30 天新学与复习记录；撤销评分后统计与连续天数同步更新。
- **主牌组学习范围**：今日学习只覆盖主牌组；无牌组时不能制卡或学习，牌组详情仍可按单个牌组学习。
- **重复内容复用**：添加已存在的单词或语法时可直接「加入当前牌组」——同一 Note 归属多个牌组共享一份卡片、调度进度与复习日志，不复制数据；仍可选择明确另建义项。
- **主动回忆默认开启**：新安装的「中文→日文输入」与「听力输入」回忆选项默认开启；已有用户的开关选择保持不变。
- **AI 服务扩展**：除 DeepSeek 与自定义兼容服务外，新增 Kimi、GLM、ChatGPT / OpenAI API、Claude、Gemini、Qwen 与 Grok 预设；填入 API Key 后先获取模型列表再选择模型，「保存并测试」成功后才可启用；Claude 使用 Anthropic Messages 协议。
- **兼容不变**：数据库仍为 schema v13、备份仍为 v6，v1～v6 备份继续可恢复，旧库升级保留全部设置与牌组归属。

## 主要功能

### 学习与复习

- 单词、语法、例句、标签、收藏、多卡片方向和重复提示；
- FSRS-6 调度、每日新卡额度（按词计）、04:00 学习日、四档评分、撤销、历史与统计；
- 今日页按主牌组学习，牌组详情可按单个牌组学习，显示真实的剩余、新卡、已完成和结束统计；
- 30 天逐日学习统计与连续学习天数，撤销后同步更新；
- 自适应复习按评分历史识别易错卡，易错中心支持暂停、恢复与跳转编辑，同一词的多方向卡不连续出现；
- 可选「中文→日文输入」与「听力输入」回忆（新用户默认开启），作答后与标准答案逐字对比再自评；听力卡问题面不泄题、语音不可用时安全降级；
- AI 修卡对易错卡给出最小上下文建议，逐字段预览差异、显式确认后原子写入；
- 设备 `ja-JP` 系统语音朗读，核心学习流程可在飞行模式使用。

### 采集与制卡

- 手动输入和用户主动触发的 `UIPasteControl` 粘贴，不在后台读取剪贴板；
- 系统分享扩展接收文本，并通过 App Group 队列交给主 App；
- 本机 Vision OCR 支持图片预览、文本块选择、编辑和失败后的手动输入；
- 收集箱统一承接四种来源，可搜索、编辑、归档、删除和继续处理；
- 受控词性集合（名词、动词、形容词等）应用于手动编辑、AI 生成/修卡、句子分析和 JLPT 导入；
- 词汇音调按假名读音 mora 数提供 0–N 选项，详情页显示音调位置；
- 多供应商 AI：DeepSeek、Kimi、GLM、ChatGPT / OpenAI API、Claude、Gemini、Qwen、Grok 及自定义 OpenAI 兼容服务；填 Key 后获取模型列表选择模型；
- AI 单词/语法候选、句子分析和选中项目批量制卡，保存前均由用户确认。

### 本地资料与数据安全

- 日文、假名、平/片假名、半角及中文本地搜索；
- 内置 8,334 个社区 JLPT N5–N1 参考词汇，带可追溯音调与中文例句翻译，可离线浏览、搜索、朗读并幂等导入；
- 明文 `.oboe-backup` 全量导出、严格预检、完整替换恢复和三份本机滚动快照；
- API Key 仅保存在 iOS Keychain，不写入 SQLite、日志或可携带备份；
- 跟随系统、浅色和深色外观，支持辅助功能字号和 VoiceOver 语义。

## 获取与安装

在 [Releases 页面](https://github.com/RicardoZh4346/Oboe-Japanese/releases) 下载 v0.5.5 对应的 `Oboe-v0.5.5.ipa`。该文件是 **arm64 未签名构建**，需要用自己的 Apple Account 重新签名后安装。以下流程仅首次配置需要电脑，之后可在同一 Wi-Fi 下通过 SideStore 刷新。

> iLoader、LocalDevVPN 和 SideStore 均为第三方项目，不属于 Oboe，也不受本项目维护或担保。请只从其官方页面下载，不要向他人发送 Apple Account 验证信息或设备配对文件。

### 准备工作

- 一台运行 iOS 17 或更高版本、已设置锁屏密码的 iPhone；
- 一个 Apple Account；
- 一台用于首次安装的电脑和一根可传输数据的 USB 线；
- iPhone 与电脑连接到同一 Wi-Fi；蜂窝网络不能替代此连接；
- 从 [iLoader 官网](https://iloader.app/) 或 [iLoader GitHub 仓库](https://github.com/nab138/iloader) 下载 iLoader；
- 按 [SideStore 官方准备指南](https://docs.sidestore.io/docs/installation/prerequisites) 在 iPhone 上安装 LocalDevVPN。

### 1. 使用 iLoader 安装 SideStore

1. 通过 USB 将 iPhone 连接到电脑，在两端确认“信任此电脑”。
2. 打开 iLoader，登录 Apple Account，并选择已连接的 iPhone。
3. 选择 **Install SideStore (Stable)**，等待 SideStore 安装完成；iLoader 会同时处理设备配对文件。
4. 在 iPhone 上打开“设置 → 通用 → VPN 与设备管理”，选择对应的开发者 App 并确认信任。
5. 打开“设置 → 隐私与安全性 → 开发者模式”，启用后按提示重启并再次确认。
6. 打开 LocalDevVPN，点按 **Connect**。
7. 打开 SideStore，登录与 iLoader 中相同的 Apple Account。
8. 进入 **My Apps**，点按 SideStore 右侧的 **7 DAYS** 完成首次刷新；出现证书撤销或刷新提示时按提示确认。

如 iOS 更新、还原或重新配对后 SideStore 报配对错误，请重新连接电脑，并使用 iLoader 替换配对文件。完整安装流程见 [SideStore 官方安装指南](https://docs.sidestore.io/docs/installation/install)。

### 2. 使用 SideStore 安装 Oboe

1. 在 iPhone 上从 [Releases 页面](https://github.com/RicardoZh4346/Oboe-Japanese/releases) 下载 `Oboe-v0.5.5.ipa`，并保存到“文件”App。
2. 确认 iPhone 已连接 Wi-Fi，且 LocalDevVPN 处于 **Connected** 状态。
3. 打开 SideStore，进入 **My Apps**，点按右上角 **+**，选择刚下载的 IPA。
4. 等待 SideStore 完成签名与安装，然后从主屏幕启动 Oboe。
5. 免费 Apple Account 签名通常 7 天到期；到期前保持 Wi-Fi 和 LocalDevVPN 已连接，在 SideStore 的 **My Apps** 中刷新 Oboe。

免费 Apple Account 最多同时激活 3 个 App（包含 SideStore），并且 7 天内最多注册 10 个 App ID。安装或刷新失败时，先确认 Wi-Fi 与 LocalDevVPN 均已连接；仍然失败可参考 [SideStore 常见问题](https://docs.sidestore.io/docs/troubleshooting/common-issues)。

重签可能改变 Bundle ID、App Group 和 Keychain access group，因此旧安装中的 API Key 可能无法继续读取；App Group 授权不匹配时，分享扩展会禁用保存并显示签名诊断。

## 开发

需要 macOS、Xcode 16.3+、Swift 6.1+ 和 iOS 17+ Simulator。v0.5.5 验证使用 macOS 26、Xcode 27、Swift 6.4 和 iOS 26.5 Simulator（iPhone SE 第 3 代）。SwiftPM 锁定：

- GRDB 7.11.1；
- `swift-fsrs` revision `4fbaf20184d62f82a9f44f343337c61a2c5483e9`。

运行核心测试和模拟器构建：

```sh
swift test --package-path Packages/OboeCore

xcodebuild -project Oboe.xcodeproj -scheme Oboe \
  -destination 'generic/platform=iOS Simulator' clean build
```

运行 UI 测试：

```sh
xcodebuild -project Oboe.xcodeproj -scheme Oboe \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation),OS=latest' test
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

`.oboe-backup` v6 是未压缩、未加密的 UTF-8 NDJSON，使用固定记录顺序和 SHA-256 footer。它包含学习数据、设置、`note_decks` 成员关系记录及以下收集箱记录：

- `inboxItem`；
- `inboxProcessingContext`；
- `captureImportReceipt`；
- `inboxCommitReceipt`。

备份不包含 API Key、AI 连接配置、内置只读词库、搜索派生索引、本机快照、图片附件文件或尚未导入的共享队列文件；易错与趋势属派生数据，恢复后由评分日志重建。跨设备恢复后，收集箱正文会保留，缺失的图片引用会安全降级。

恢复前 App 会检查格式版本、UTF-8/LF、记录顺序、数量、SHA-256、外键、调度状态和算法版本；预检不修改当前数据库。正式恢复是**完整替换**而不是合并导入，替换前会创建回滚快照，失败或进程中断时恢复到已验证的数据库。Oboe 可恢复 v1～v6 备份（更早版本的记录自动补齐新增列与默认值，无 `noteDeck` 记录的备份按 `notes.deck_id` 重建成员关系），并明确拒绝未来格式和未知调度算法。

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

## 项目结构

```text
OboeApp/                   SwiftUI 主应用、功能页面与资源
OboeShareExtension/        系统分享扩展
Packages/OboeCore/         Domain、Infrastructure、共享采集协议
OboeUITests/               导航、布局与端到端 UI 测试
Scripts/                   JLPT 词库生成与校验工具
.github/workflows/ci.yml   持续集成
```

## 已知限制

- 没有账号、云同步、嵌套牌组、Anki/CSV 导入、备份合并或备份加密；
- 不支持相机直接拍摄或云 OCR；图片附件不随可携带备份迁移；
- 系统 TTS 不提供标准重音词典、真人录音、语速、音色或重音标注设置；音调来自 UniDic/kanjium 词典标注，202 个无法可靠匹配的词保持未设置，不做 AI 猜测；
- 音调选择器取值范围由假名读音的 mora 数决定，需先填写读音；
- 表单输入法自动切换需系统已添加对应键盘；
- 免费 Apple ID 重签无法注册 App Group，分享扩展在该环境下可能不可用（主 App 功能不受影响）；
- AI 输出质量取决于用户配置的服务，未做真实服务质量门控，建议内容仍须由用户审核。

## 贡献

请至少运行核心测试和模拟器构建；涉及导航、布局、恢复或设置时还应运行 UI 测试。不要提交 API Key、签名证书、个人 Team ID、真实学习数据、导出的 `.oboe-backup` 或本机数据库。

数据库 schema 变化必须使用显式迁移且失败时不得清空原库；备份格式变化必须说明版本迁移、排除范围和恢复失败行为；调度逻辑应继续通过锁定的 FSRS-6 参考向量与事务测试。

## 许可

Oboe 源代码采用 [MIT License](LICENSE)。GRDB、`swift-fsrs` 与内置数据的版权及许可见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) 和 `OboeApp/Resources/JLPT/NOTICE.txt`。内置 JLPT 衍生数据库依 CC BY-SA 4.0 提供，不受应用代码 MIT 许可覆盖。
