# 项目管家（Project Handoff Manager）

面向 Windows 本地 AI 开发环境的项目文件夹管理 Skill。它帮助用户在本机与 NTFS 移动硬盘之间安全归还、借出完整项目，并在迁移前更新交接记录、缓存清单和离线依赖信息，可在 Codex、DeepSeek 等不同 AI 软件中继续同一个本地任务。

## 当前状态

`1.1.1` 稳定版。保持四项菜单和简单迁移流程，补充真实交接结果、AI 中立继续提示词、归还清理恢复和简洁中文呈现。迁移预览只读取元数据；完整复制校验会计算哈希，并在后续校验中复用元数据未变化文件的既有哈希。

## 四项日常操作

1. 开始或继续当前项目：补齐管理结构，读取交接记录，刷新环境清单。
2. 暂停当前项目：预览并仅停止能证明属于项目的进程，记录下一步。
3. 将当前项目归还到 T9：暂存复制、哈希校验、正式提升，独立确认后清理本机来源。
4. 从 T9 借出项目到本机：暂存复制、校验提升、恢复环境与交接，独立确认后清理 T9 来源。

## 安装、验证与升级

从仓库根目录安装完整 Skill；`-DestinationRoot` 指向 Codex 的用户 `skills` 根，而不是具体 Skill 子目录：

```powershell
.\scripts\install.ps1 -DestinationRoot 'D:\CodexUser\skills'
.\scripts\verify_install.ps1 -DestinationRoot 'D:\CodexUser\skills'
```

省略 `-DestinationRoot` 时，安装器优先使用 `$env:CODEX_HOME\skills`，否则使用当前用户的 `.codex\skills`。目标内容完全相同时会返回“已安装”且不重复复制；目标不同会停止。确认升级时显式使用 `-Force`，安装器会先创建可恢复备份，再校验暂存副本并替换：

```powershell
.\scripts\install.ps1 -DestinationRoot 'D:\CodexUser\skills' -Force
```

安装完成后重新启动 Codex 或开始一个新任务，使 Skill 清单重新加载。

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

这一步会生成环境检查结果和一份 AI 软件中立的 `项目交接/继续项目提示词.md`，但不会删除 T9 来源。用户可以先在本机继续工作；需要释放移动硬盘空间时，再使用结果中的精确本机路径发布独立清理指令：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action checkout -ProjectPath 'T:\AI开发工作盘\项目仓库\暂停项目\示例项目' -TargetPath 'D:\AI项目管理\01-当前项目\示例项目' -ConfirmCleanup
```

工具会复核设备身份、仓库边界、借出回执、项目编号和精确路径，然后只删除 T9 上的旧来源；本机在借出后产生的新工作不会阻断该独立清理。清理成功后，打开本机正式项目，先读交接报告和环境清单，验证或重建 Node/Python 环境，再继续上次未完成工作。项目缓存、离线依赖、`node_modules` 和 `.venv` 的存在只代表它们随项目保留，不承诺可直接运行。

如果复制提升后的交接最终化失败，或清理 T9 来源时磁盘占用导致删除失败，不要重新借出，也不要手工删除。保持 T9 连接，使用本机正式项目路径运行恢复；入口会自动识别应继续“最终化”还是只重试“清理与登记”：

```powershell
pwsh -File .\project-handoff-manager\scripts\project_manager.ps1 -Action repair -TargetPath 'D:\AI项目管理\01-当前项目\示例项目' -ConfigPath 'D:\AI项目管理\项目管家配置.json'
```

恢复会重新校验设备身份、磁盘盘符、仓库边界、恢复记录和项目身份。借出清理恢复不会重新复制项目，只重试尚未完成的 T9 旧来源清理与登记。

如果归还清理已删除本机来源，但移动硬盘目标的身份、交接报告或登记更新失败，对包含 `项目交接/归还清理恢复.json` 的移动硬盘项目运行 `repair`。它只补齐目标状态和登记，不重新复制，也不会再次删除来源。

脚本继续返回稳定 JSON 供 AI 软件解析；默认用户界面只显示简洁中文菜单、关键路径、校验结果、安全状态和唯一下一步，不直接铺开原始 JSON。

## 在另一台电脑继续

1. 在电脑 A 将项目归还到已验证的 T9，完成校验后再单独确认清理 A。
2. 将 T9 连接到电脑 B，先完成该电脑的一次性设备信任配置。
3. 在电脑 B 预览并执行“从 T9 借出项目到本机”，校验成功后再单独确认清理 T9 来源。
4. 打开本机正式项目，阅读 `项目交接/项目交接报告.md` 和 `项目交接/继续项目提示词.md`，按 `环境清单.json` 验证或重建环境，再继续工作。
5. 工作完成后从电脑 B 重新归还到 T9；校验成功并清理 B 后，T9 才再次成为唯一正式副本。

## 依赖环境边界

- Skill 管理项目文件和项目内的环境说明，不安装系统级软件，不迁移登录凭据、令牌或 Cookie。
- `.venv`、`node_modules`、项目缓存和离线依赖可以作为项目内容保留，但跨电脑复制后不保证可直接运行。
- 应根据锁文件、版本清单和环境检查结果验证或重建 Python、Node.js 等运行环境。
- 不读取、修改或复制 Codex 桌面版数据库与对话数据库。

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

这是可独立安装和发布的开源项目，采用 [MIT](LICENSE) 许可证，不依赖原开发仓库才能运行。
