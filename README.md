# 项目管家（Project Handoff Manager）

面向 Windows Codex 桌面版的项目文件夹管理 Skill。它帮助用户在本机与 NTFS 移动硬盘之间安全归还、借出完整项目，并在迁移前更新交接记录、缓存清单和离线依赖信息。

## 当前状态

项目正在按 6 个独立 PR 开发。当前开发分支已实现项目总览、自动纳管、交接同步、安全暂停、事务式归还 T9，以及带环境恢复检查的事务式借出。

## 安全原则

- 校验目标副本成功前绝不删除源副本。
- 清理源副本必须是单独确认的操作。
- 不读取或迁移 Codex 桌面版数据库和对话数据库。
- 不迁移令牌、Cookie、密码和系统级软件。
- 公开仓库仅使用虚拟测试数据，不包含真实项目和设备身份。
- 只有完整项目路径或其已确认父进程关系能证明归属时，进程才进入停止候选。
- Codex 主程序、Windows 系统保护进程和只有项目名称的模糊匹配默认跳过。

## 暂停项目

第一次运行只生成预览：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action pause -ProjectPath 'D:\项目\示例项目'
```

确认预览中的 PID、命令和判定证据后，再明确执行：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action pause -ProjectPath 'D:\项目\示例项目' -ConfirmStop
```

## 归还到 T9

第一次运行只显示完整计划，不复制：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action checkin -ProjectPath 'D:\项目\示例项目' -ConfigPath 'D:\AI项目管理\项目管家配置.json'
```

确认磁盘身份、源路径、暂存路径、正式路径、文件数量、敏感文件和进程清单后，执行复制与校验：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action checkin -ProjectPath 'D:\项目\示例项目' -ConfigPath 'D:\AI项目管理\项目管家配置.json' -ConfirmTransfer -ConfirmProcessStop
```

这一步不会删除本机来源。目标校验通过且没有继续修改项目后，再使用结果中的精确目标路径完成清理：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action checkin -ProjectPath 'D:\项目\示例项目' -TargetPath 'T:\AI开发工作盘\项目仓库\暂停项目\示例项目' -ConfirmCleanup
```

如果本机或 T9 副本在等待清理期间发生变化，工具会阻止删除并标记冲突。

## 从 T9 借出到本机

配置文件中的 `local.currentProjectsRoot` 是本机正式项目根，`local.receivingRoot` 是借出暂存根。第一次运行只生成预览，不复制：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action checkout -ProjectPath 'T:\AI开发工作盘\项目仓库\暂停项目\示例项目' -ConfigPath 'D:\AI项目管理\项目管家配置.json'
```

确认磁盘身份、来源路径确实位于该磁盘盘符、空间、冲突、重解析点、来源清单、本机暂存路径和正式路径后，执行复制、来源复核、目标哈希校验和原子提升：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action checkout -ProjectPath 'T:\AI开发工作盘\项目仓库\暂停项目\示例项目' -ConfigPath 'D:\AI项目管理\项目管家配置.json' -ConfirmTransfer
```

这一步会生成环境检查结果和 `项目交接/继续项目提示词.md`，但不会删除 T9 来源。停止修改两端文件，使用结果中的精确本机路径再次确认清理：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action checkout -ProjectPath 'T:\AI开发工作盘\项目仓库\暂停项目\示例项目' -TargetPath 'D:\AI项目管理\01-当前项目\示例项目' -ConfirmCleanup
```

工具会复核两端借出回执、项目编号和复制后摘要；任一副本发生变化都会保留双份。清理成功后，打开本机正式项目，先读交接报告和环境清单，验证或重建 Node/Python 环境，再继续上次未完成工作。项目缓存、离线依赖、`node_modules` 和 `.venv` 的存在只代表它们随项目保留，不承诺可直接运行。

如果复制提升后的交接最终化失败，或清理 T9 来源时磁盘占用导致删除失败，不要重新借出，也不要手工删除。保持 T9 连接，使用本机正式项目路径运行恢复；入口会自动识别应继续“最终化”还是只重试“清理与登记”：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action repair -TargetPath 'D:\AI项目管理\01-当前项目\示例项目' -ConfigPath 'D:\AI项目管理\项目管家配置.json'
```

恢复会重新校验设备身份、磁盘盘符、仓库边界、恢复记录和项目身份。清理恢复不会重新复制项目；若 T9 来源在失败后发生变化，会停止删除并保留现状。

## 运行骨架

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action menu
```

## 测试

```powershell
Invoke-Pester -Path .\tests
```

## 兼容目标

- Windows 10/11
- Windows PowerShell 5.1 或 PowerShell 7+
- NTFS 移动硬盘
- Codex 桌面版项目工作流

## 许可证

[MIT](LICENSE)
