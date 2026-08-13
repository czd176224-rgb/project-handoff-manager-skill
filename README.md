# 项目管家（Project Handoff Manager）

面向 Windows Codex 桌面版的项目文件夹管理 Skill。它帮助用户在本机与 NTFS 移动硬盘之间安全归还、借出完整项目，并在迁移前更新交接记录、缓存清单和离线依赖信息。

## 当前状态

项目正在按 6 个独立 PR 开发。当前 `0.1.0` 是安全骨架：可以显示四项中文操作菜单，真实扫描、暂停、归还和借出将在后续里程碑加入。

## 安全原则

- 校验目标副本成功前绝不删除源副本。
- 清理源副本必须是单独确认的操作。
- 不读取或迁移 Codex 桌面版数据库和对话数据库。
- 不迁移令牌、Cookie、密码和系统级软件。
- 公开仓库仅使用虚拟测试数据，不包含真实项目和设备身份。

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

公开发布前确定。
