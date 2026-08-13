# 项目管家（Project Handoff Manager）

面向 Windows Codex 桌面版的项目文件夹管理 Skill。它帮助用户在本机与 NTFS 移动硬盘之间安全归还、借出完整项目，并在迁移前更新交接记录、缓存清单和离线依赖信息。

## 当前状态

项目正在按 6 个独立 PR 开发。当前开发分支已实现项目总览、自动纳管、交接同步和安全暂停；T9 归还与借出将在后续里程碑加入。

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
