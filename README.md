# KirkLogging

面向 macOS 14 及以上的本机诊断包。CocoaLumberjack 负责文件写入、轮转和保留份数。此包定义诊断字段、控制写入和提供筛选导出。要求 Swift 6.0 工具链。

```swift
import Foundation
import KirkLogging

let log = try DiagnosticLog(
    configuration: .init(app: "Example", channel: .dev, role: "host", version: "1.0.0", build: "42"),
    enabled: true
)
let operation = UUID()
log.record(.info, module: "translation", event: "started", operationID: operation)
log.record(.error, module: "translation", event: "failed", operationID: operation,
           errorCode: "timeout", elapsedMS: 42)
```

日志默认写入 `~/Library/Logs/<app>/<channel>/<role>/`。同一角色只允许一个写入实例。每个事件独立排队，退出前尚在队列中的事件可能丢失。默认约 1 MiB 或一天轮转，保留最多三个归档；时间参数控制轮转，并非按日期删除。队列达到容量时丢弃新事件，可从 `droppedEvents` 查看计数。

宿主决定是否启用记录，并在开始、关键阶段和完成时调用。插件使用独立角色，协议允许时传递同一个随机操作编号。使用 `export(to:matching:including:)` 以时间、模块或级别过滤，导出同一通道多个角色的 JSON。使用 `clear()` 清除当前角色的记录。宿主负责选择输出位置和用户界面。版本、构建号只传公开的版本标识，事件与错误使用固定分类，避免记录截图、文本、凭据、URL 和路径。

运行 `swift test` 验证轮转、筛选与通道隔离。消费包时通过 Git 版本标签固定依赖。手工打包 App 时检查 CocoaLumberjack 随包提供的隐私清单资源及许可证是否随产物分发。

## 发布 Swift Package

`make release-dry-run` 仅根据本地标签预览版本。首次发布为 `0.1.0`，以后默认递增 patch，可用 `BUMP=minor` 或 `BUMP=major` 调整。

先将要发布的源码提交到本地 `master`。运行 `make release` 即确认发布。脚本会校验工作区和远端状态，运行测试和 Release 构建，在已验证的提交上创建 SemVer 标签，再原子推送 `master` 和该标签。包版本以 Git 标签为准。

如果推送失败，修复原因后执行脚本输出的原命令，重试同一个提交和标签。
