# project-handoff-manager v1.0.0

## 发布摘要

说明本版本解决的问题、适用场景及主要安全边界。

## 安装与验证

```powershell
.\scripts\install.ps1 -DestinationRoot '<隔离的 Codex skills 根>'
.\scripts\verify_install.ps1 -DestinationRoot '<隔离的 Codex skills 根>'
```

## 验证证据

- [ ] 全套 Pester 通过
- [ ] Skill 结构验证通过
- [ ] Windows PowerShell 5.1 smoke 通过
- [ ] 隐私扫描通过
- [ ] 隔离安装与安装验证通过
- [ ] 发布包仅包含 `project-handoff-manager` Skill 文件夹

## 已知限制

列出依赖环境重建、NTFS 移动盘、人工确认阶段及任何残余风险。
