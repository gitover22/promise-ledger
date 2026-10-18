# 你的智能 AI 账本 · Promise Ledger

轻量原生 macOS 客户端：截下订单，或导入手机截图，让 AI 整理账单，并保留交易承诺的原文依据。

当前为可运行的 0.1 MVP，使用 SwiftUI / AppKit、ScreenCaptureKit、Vision 和 SQLite，无第三方运行时和包依赖。最低 macOS 14；当前开发构建为 Apple Silicon 原生程序。

## 启动

需要 macOS 和 Xcode Command Line Tools，不要求安装完整 Xcode：

```sh
./scripts/run.sh
```

脚本会编译 release 程序、生成图标、打包并进行本机 ad-hoc 签名，再打开 `dist/Promise Ledger.app`。只构建不启动可运行 `./scripts/build.sh`。首次构建需要等待 Swift 编译系统框架。

这是本机开发构建，尚未做 Developer ID 签名、公证、自动更新或 App Store 分发；不可视为已完成可分发的安装包。升级构建后，系统有时需要重新确认屏幕录制权限。

## 第一条账单

1. 打开应用，点「导入订单图片」，或把 PNG / JPEG / HEIC / TIFF 图片拖入窗口。单次最多 10 张，每张不超过 40 MB。
2. 首次使用先阅读并同意 AI 文字发送说明。原图不上传；识别出的全部 OCR 文字会发送至配置的 MaaS 服务，可能含姓名或地址，请先检查订单内容。
3. 等待「读取图片文字 → AI 整理」完成，记录自动保存在本地数据库，状态为「待确认」。
4. 打开记录，对照左侧原图修改金额、币种、日期或分类，点击「确认无误，入账」。模型自评不是经过校准的准确率。
5. 截图时在目标订单页面按 **Control + Option + L**。多显示器环境会截取鼠标所在显示器的完整画面，并排除本应用窗口。屏幕其他可见内容也可能被 OCR，请注意隐私。

第一次截图需要在系统设置的「隐私与安全性 → 屏幕与系统音频录制」授权。拒绝后不会绕过系统限制；仍可使用图片导入。系统要求时重启应用后重试。

关闭主窗口不会退出程序；菜单栏保留账本图标，可截图、导入或重新打开窗口。退出请使用菜单栏的「退出 AI 账本」或 Command + Q。应用没有持续录屏、后台轮询或自动调用模型；仅处理用户主动触发的任务。开机自启暂未实现。

## AI 配置与密钥

配置读取自当前 macOS 用户的 `~/.config/promise-ledger/model.json`。当前用户已完成配置，不需要重新提供 key。

- 默认模型：`GPT-5.6 Sol`；不因某次 GLM 测试而切换默认模型。
- 服务：已配置的 Rednote MaaS Chat Completions HTTPS 端点。
- 从配置读取 Authorization 请求头、Bearer 前缀、流式开关及 `include_usage`，不在代码中另选供应商。
- 应用标识：用户指定的 `seal`，通过 `x-maas-app-id` 请求头传递；账单抽取场景使用 `x-maas-scenario: bill-extraction`。
- 密钥只在调用进程内，通过 `/usr/bin/security` 读取 macOS 钥匙串，捕获而不显示 stdout；service 为 `promise-ledger.maas.api-key`，account 为 `promise-ledger`。
- 密钥不进入前端状态、源码、SQLite、错误信息或日志。仓库中的 `config/model.example.json` 仅为不含密钥的配置结构参考，不会覆盖本机配置。
- 不将密钥复制到 H20、其他服务器或 Pod。未来如需远程服务，必须另外授权运行时 secret 注入。

本版以 **本机 Vision OCR + 文本模型** 实现图片理解，不假定 MaaS 支持图片输入，也不将完整原图上传给模型。流式响应必须收到 `finish_reason=stop` 和 `[DONE]` 才接受结果；中断或截断不会被当成成功账单。

当前 Mac 的原生 URLSession 与该 MaaS 端点实测发生 TLS 握手失败，而系统 curl 可正常完成严格校验的请求。因此本版使用 `/usr/bin/curl` 作为单次请求传输层：密钥和请求体只通过进程 stdin 传入，不出现在命令行参数或临时文件中。保留 HTTPS 及证书校验，不读取用户 `.curlrc`，不跟随重定向，不自动重试请求。

## 代码结构

- `LedgerCore`：账单与承诺模型、字段校验、MaaS 配置与客户端、SSE 完整性校验、SQLite 持久化。
- `LedgerMac`：图片归一化与 SHA-256 去重、本地 OCR、按需全屏截图、Carbon 全局快捷键。
- `PromiseLedger`：应用生命周期、菜单栏、串行识别任务队列、SwiftUI 首页、复核和隐私设置。
- `LedgerCheck`：只使用自动生成的虚构收据进行 OCR / AI / 数据库存储诊断，不读取真实屏幕，不写入用户账本。
- `Tests/LedgerCoreTests`：金额精度、日期、原文证据、非账单拒绝、完整与中断流、SQL 参数化、去重、重启恢复测试。

## 数据与恢复

本地数据位于 `~/Library/Application Support/PromiseLedger/`：`ledger.sqlite3` 及 WAL 辅助文件保存记录；`Images/` 保存规范化的 JPEG 原始凭据副本。OCR 文字、订单号、模型抽取结果也会留存在数据库中。导入手机图片时应用会生成独立副本，不会修改用户原文件。

目录权限为 700，新建数据库与图片权限为 600。当前尚无应用层加密；请使用 FileVault 保护磁盘。程序没有账户体系和云同步。备份时退出应用后复制整个数据目录，不能只复制正在写入的 SQLite 主文件而忽略 WAL。

任务串行处理，以免同时触发大量 AI 请求。相同规范化图片会复用原记录。模型失败或网络中断会保留凭据并显示重试入口；应用重启会把未完成任务恢复为等待状态，不会自动重新发送。对仍在等待的记录点击「开始识别」继续。

金额使用十进制字符串与 `Decimal`，不使用二进制浮点进行入账计算。首页仅汇总有明确交易日期且已确认的当月金额，不折算币种，也不将导入日期充当交易日期；多币种时显示「多币种」，不混加金额。这是账单确认金额，不是对退款或待付款作会计处理后的净支出。

承诺只保留能在 OCR 中匹配到原文引述的内容；不凭商品类别推断七天无理由、保价或保修权益。日期缺失时不猜测年份或计算到期日。本版不提供权益到期通知、网页监控、退款操作或法律判断。

## 验证

```sh
# 不访问网络、不读取密钥；使用独立测试程序，无需 XCTest 或完整 Xcode
swift run LedgerTests
swift run LedgerCheck

# 可选真实模型测试：只发送程序生成的虚构收据 OCR
swift run LedgerCheck --live-ai

# 生成一张可在界面中手动导入的虚构收据
swift run LedgerCheck --make-fixture dist/fixtures/diagnostic-receipt.png

# 可选：使用全新的隔离临时账本验收界面（先退出已运行的实例）
open "dist/Promise Ledger.app" --args --preview
```

预览模式会在临时目录创建新的空账本并隔离 AI 发送授权，不生成假模型结果，也不写入真实账本。手动导入虚构收据后可以验证完整的授权、识别、复核与入账流程。退出后正常启动即可回到真实账本。

屏幕授权与系统级快捷键需要在真实桌面手动验收；无权限时不能仅以编译通过声称截图已验证。OCR 质量取决于截图清晰度，文字识别不保证恢复原始视觉布局；多笔订单或金额歧义会交由用户复核。

平台接口参考：[Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)、[Apple Vision OCR](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)。

## 2026-10-18 本机验收记录

- Apple Silicon / macOS 26.4.1 / Swift 6.3.2：debug 与 release 构建成功，生成本机签名的 `.app`，签名完整性检查通过。
- 独立核心测试 13/13 通过，包括数据库主文件、WAL 和 SHM 的私有权限检查。
- 真实 MaaS 测试：只发送程序生成的虚构收据 OCR，GPT-5.6 Sol 正确抽取 CNY 129.00，并成功保存和重新读取隔离的 SQLite 数据库。
- 原生界面验收：隔离预览空间内完成图片选择、首次 AI 发送授权、真实模型识别、原图对照、手动修正商家名称、确认入账及首页汇总更新。关闭窗口后进程继续存活，随后正常退出测试实例。
- 未执行对用户真实桌面的自动截图或上传；实际屏幕捕获、全局按键触发以及不同 macOS 版本的系统授权交互，仍需用户手动验收。截图实现与快捷键注册代码已编译并接入，但不把编译通过当作这些交互均已实测。
