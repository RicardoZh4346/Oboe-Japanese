# Oboe

[![CI](https://github.com/RicardoZh4346/Oboe-Japanese/actions/workflows/ci.yml/badge.svg)](https://github.com/RicardoZh4346/Oboe-Japanese/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/RicardoZh4346/Oboe-Japanese)](https://github.com/RicardoZh4346/Oboe-Japanese/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Oboe 是一款开源、离线优先的 iPhone 日语学习应用。它把资料采集、AI 辅助整理、制卡和 FSRS-6 间隔复习放在同一个本地工作流里；没有账号、业务后端或云同步，AI 默认关闭。

当前版本为 **v0.4.0（构建号 45）**，最低支持 iOS 17，仅支持 iPhone。

> GitHub Release 提供 arm64 未签名 IPA。安装前需要使用你自己的证书重新签名；项目不包含开发团队、证书、描述文件或 App Store 上传配置。

## v0.4 新增

- **自适应复习**：按评分历史识别 Leech/易错卡；易错中心支持暂停、恢复与跳转编辑，不修改 FSRS 算法与 ReviewLog。
- **AI 修卡（预览确认）**：对易错卡生成最小上下文修卡建议，逐字段预览差异，显式确认后原子写入；拆卡操作把一张卡拆为独立方向卡，失败整体回滚，不未经确认修改数据。
- **输入式答题**：可选「中文→日文」输入回忆，作答后与标准答案逐字对比再自评；默认关闭。
- **听力方向**：新增「听力→中文」卡片类型，独立 FSRS 调度；问题面只显示播放按钮不泄题，语音不可用时安全降级且零写入。
- **Sibling 错开**：同一词的多方向卡不连续出现，仅调整队列展示顺序。
- **JLPT 进度与报告（P1 已纳入）**：内置词库分级进度 Dashboard、薄弱词汇列表与易错趋势报告。
- **新卡额度按词计**：每日新卡上限按词统计，一个词的全部方向一次收录；可设「主牌组」优先分配当日额度。
- **建卡简化**：新建/JLPT 导入默认创建全部方向；表单按字段语种自动切换日语/拼音输入法；牌组管理入口移至详情页顶部。
- **备份格式 v5**：设置记录新增主牌组与 v0.4 学习开关列，继续兼容 v1～v4 恢复。

> 已知限制：分享扩展依赖 App Group，自签/重签环境下可能不可用，需真实签名环境验证；AI 建议质量取决于用户自行配置的服务，未做真实服务质量门控；表单输入法自动切换需系统已添加对应键盘。

## v0.3 新增

- **收集箱工作流**：手动输入、系统粘贴、系统分享和图片 OCR 四种来源统一进入收集箱，可搜索、编辑、归档、删除和继续处理。
- **系统分享扩展**：从其他 App 分享文本到 Oboe；主 App 在冷启动、回到前台或打开收集箱时幂等导入，不重复、不丢失。
- **本机图片 OCR**：从照片或文件导入 JPEG、PNG、HEIC，使用 Apple Vision 在设备上识别日文优先文本；支持文本块选择、低置信度提示、校正和重新合并。
- **统一制卡链路**：采集内容可进入现有 AI 分析或手动编辑流程，并以原子事务保存为 Note/Card；失败重试不会重复制卡。
- **学习界面 v2**：重做问题面、答案面、评分区、范围进度、等待态与完成统计，补齐小屏、大字号、深色模式、VoiceOver 和 Reduce Motion 体验。
- **备份格式 v3**：全量备份新增收集箱、处理上下文及幂等回执，并继续兼容 v1/v2 恢复。

## 主要功能

### 学习与复习

- 单词、语法、例句、标签、收藏、多卡片方向和重复提示；
- FSRS-6 调度、每日新卡额度、04:00 学习日、四档评分、撤销、历史与统计；
- 按全部牌组或单个牌组学习，显示真实的剩余、新卡、已完成和结束统计；
- 设备 `ja-JP` 系统语音朗读，核心学习流程可在飞行模式使用。

### 采集与制卡

- 手动输入和用户主动触发的 `UIPasteControl` 粘贴，不在后台读取剪贴板；
- 系统分享扩展接收文本，并通过 App Group 队列交给主 App；
- 本机 Vision OCR 支持图片预览、文本块选择、编辑和失败后的手动输入；
- DeepSeek 预设及自定义 Chat Completions 兼容服务；
- AI 单词/语法候选、句子分析和选中项目批量制卡，保存前均由用户确认。

### 本地资料与数据安全

- 日文、假名、平/片假名、半角及中文本地搜索；
- 内置 8,334 个社区 JLPT N5–N1 参考词汇，可离线浏览、搜索、朗读并幂等导入；
- 明文 `.oboe-backup` 全量导出、严格预检、完整替换恢复和三份本机滚动快照；
- API Key 仅保存在 iOS Keychain，不写入 SQLite、日志或可携带备份；
- 跟随系统、浅色和深色外观，支持辅助功能字号和 VoiceOver 语义。

## 获取与安装

可在 [v0.4.0 Release](https://github.com/RicardoZh4346/Oboe-Japanese/releases/tag/v0.4.0) 下载 `Oboe-v0.4.0.ipa`。该文件是 **arm64 未签名构建**，需要用自己的 Apple Account 重新签名后安装。以下流程仅首次配置需要电脑，之后可在同一 Wi-Fi 下通过 SideStore 刷新。

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

1. 在 iPhone 上从 [v0.4.0 Release](https://github.com/RicardoZh4346/Oboe-Japanese/releases/tag/v0.4.0) 下载 `Oboe-v0.4.0.ipa`，并保存到“文件”App。
2. 确认 iPhone 已连接 Wi-Fi，且 LocalDevVPN 处于 **Connected** 状态。
3. 打开 SideStore，进入 **My Apps**，点按右上角 **+**，选择刚下载的 IPA。
4. 等待 SideStore 完成签名与安装，然后从主屏幕启动 Oboe。
5. 免费 Apple Account 签名通常 7 天到期；到期前保持 Wi-Fi 和 LocalDevVPN 已连接，在 SideStore 的 **My Apps** 中刷新 Oboe。

免费 Apple Account 最多同时激活 3 个 App（包含 SideStore），并且 7 天内最多注册 10 个 App ID。安装或刷新失败时，先确认 Wi-Fi 与 LocalDevVPN 均已连接；仍然失败可参考 [SideStore 常见问题](https://docs.sidestore.io/docs/troubleshooting/common-issues)。

重签可能改变 Bundle ID、App Group 和 Keychain access group，因此旧安装中的 API Key 可能无法继续读取；App Group 授权不匹配时，分享扩展会禁用保存并显示签名诊断。

## 开发

需要 macOS、Xcode 16.3+、Swift 6.1+ 和 iOS 17+ Simulator。v0.3 最终验证使用 macOS 26.6.2、Xcode 26.6、Swift 6.3.3 和 iOS 26.5 Simulator；v0.4 验证使用 Xcode 26（27A266a）、iPhone 17 Pro / iOS 26.5 Simulator 与 iPhone 15 Pro 真机侧载。SwiftPM 锁定：

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
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' test
```

可运行的模拟器构建不要设置 `CODE_SIGNING_ALLOWED=NO`，否则安装时会缺少 Keychain entitlement。CI 中禁用签名的命令只用于编译检查。

## 数据、隐私与网络边界

学习数据库、草稿、收集箱和设置默认只保存在 App 容器。Oboe 不包含广告、行为分析 SDK、远程崩溃收集或云同步，也不申请相机、麦克风、通讯录、定位或全图库权限。

- 粘贴只在用户点击系统粘贴控件时发生。
- 分享扩展只在用户从系统分享页主动保存时运行，并把文本信封写入 App Group 共享队列。
- 图片附件保存在 App 自有受控目录；Vision OCR 全部在本机执行，原图与识别文本不会上传。
- AI 默认关闭。只有用户主动启用并执行测试、生成或分析时，当前输入和所选语境才会发送到用户配置的 AI 服务；整个牌组、评分历史和本机数据库不会自动上传。
- API Key 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存入 Keychain，并与服务类型及 HTTPS 主机绑定；跨来源重定向不会携带 Authorization。

AI 服务的数据保留、移动端直连限制和地区政策由对应服务商决定。卸载 App 会由 iOS 删除应用容器中的学习数据库、图片附件和本机快照；用户另行导出的备份需自行保管。

## 备份与恢复

`.oboe-backup` v5 是未压缩、未加密的 UTF-8 NDJSON，使用固定记录顺序和 SHA-256 footer。它包含学习数据、设置及以下 v0.3 收集箱记录：

- `inboxItem`；
- `inboxProcessingContext`；
- `captureImportReceipt`；
- `inboxCommitReceipt`。

备份不包含 API Key、AI 连接配置、内置只读词库、搜索派生索引、本机快照、图片附件文件或尚未导入的共享队列文件；Leech/易错与趋势属派生数据，恢复后由评分日志重建。跨设备恢复后，收集箱正文会保留，缺失的图片引用会安全降级。

恢复前 App 会检查格式版本、UTF-8/LF、记录顺序、数量、SHA-256、外键、调度状态和算法版本；预检不修改当前数据库。正式恢复是**完整替换**而不是合并导入，替换前会创建回滚快照，失败或进程中断时恢复到已验证的数据库。Oboe 可恢复 v1～v5 备份（v4 及更早的设置记录自动补齐 v0.4 新增列），并明确拒绝未来格式和未知调度算法。

## 内置 JLPT 词汇库

Oboe 随 App 提供只读 SQLite 衍生数据库，共 8,334 个社区整理的 JLPT N5–N1 参考词汇：N5 662、N4 632、N3 1,784、N2 1,793、N1 3,463。这不是 JLPT 官方固定词表。

数据集版本为 `2026.09.13-1`，来源包括 [OpenJLPT](https://github.com/evanclan/OpenJLPT) 与 [Tomoshi Dictionary Open Data](https://github.com/tomoshi-app/tomoshi-dict-data)。衍生数据库整体按 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode) 提供；Tatoeba 例句适用 [CC BY 2.0 FR](https://creativecommons.org/licenses/by/2.0/fr/)。完整版本锁定、署名和许可见 `OboeApp/Resources/JLPT/NOTICE.txt`。

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

## v0.4 验证与已知限制

v0.4 发布候选（b45）已完成：

- 569 项 Swift 包测试，0 失败（4 项性能门控按预期跳过，性能测试已按门控单独验证）；覆盖 Leech 规则、AI 修卡事务与拆卡幂等、输入式答题、听力调度、Sibling 错开、JLPT 进度/趋势、按词额度、schema v1～v12 迁移与 v1～v5 备份恢复；
- 模拟器 UI 回归通过（含无障碍遍历、听力防泄题、AI 修卡预览/拆卡采用、复习全流程）；
- App 与分享扩展构建成功，v1～v4 备份恢复回归通过；
- iPhone 15 Pro 真机侧载验收通过（四轮反馈修复后由用户确认）。

升级前请在 设置 → 备份 导出 `.oboe-backup` 存档；恢复为完整替换，替换前自动创建回滚快照，升级异常可重装旧版 IPA 后恢复备份回退。

当前限制（在 v0.3 限制基础上新增）：

- 表单输入法自动切换需系统已添加对应键盘；
- 分享扩展依赖 App Group，自签/重签环境可能不可用，需真实签名环境验证；
- AI 修卡建议质量取决于用户配置的服务，未做真实服务质量门控（全部测试使用替代客户端）。

## v0.3 验证与已知限制

v0.3 发布候选已完成：

- 292 项 Swift 包测试，0 失败；2 项大数据性能测试按门控单独实测通过；
- 46 项模拟器 UI 测试，0 失败；
- App 与分享扩展构建成功，v1/v2/v3 恢复回归通过；
- iPhone 15 Pro 真机完成系统分享、主 App 导入、Vision OCR、离线采集、杀进程重启持久化、附件生命周期和 Note/Card 幂等验证；
- VoiceOver、Reduce Motion、深色模式、大字号和学习全流程人工验收通过。

当前限制：

- 没有账号、云同步、嵌套牌组、Anki/CSV 导入、备份合并或备份加密；
- 不支持相机直接拍摄或云 OCR；图片附件不随可携带备份迁移；
- 系统 TTS 不提供标准重音词典、真人录音、语速、音色或重音标注设置；
- 真实 AI 输出仍须由用户审核；既有 DeepSeek `deepseek-v4-flash` 自动质量评估未通过项目的严格结构门槛。

## 贡献

请至少运行核心测试和模拟器构建；涉及导航、布局、恢复或设置时还应运行 UI 测试。不要提交 API Key、签名证书、个人 Team ID、真实学习数据、导出的 `.oboe-backup` 或本机数据库。

数据库 schema 变化必须使用显式迁移且失败时不得清空原库；备份格式变化必须说明版本迁移、排除范围和恢复失败行为；调度逻辑应继续通过锁定的 FSRS-6 参考向量与事务测试。

## 许可

Oboe 源代码采用 [MIT License](LICENSE)。GRDB、`swift-fsrs` 与内置数据的版权及许可见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) 和 `OboeApp/Resources/JLPT/NOTICE.txt`。内置 JLPT 衍生数据库依 CC BY-SA 4.0 提供，不受应用代码 MIT 许可覆盖。
