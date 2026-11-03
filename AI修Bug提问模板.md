# AI 修 Bug 提问模板

请尽量提供以下信息：

- 运行命令：例如 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyCli.ps1 -Action Status`
- Windows 版本、PowerShell 版本、是否管理员运行。
- 当前电源计划名称和 `powercfg /getactivescheme` 输出。
- 期望设置的频率值和实际看到的频率/错误信息。
- 是否使用了厂商电源管理软件或 BIOS 静音/性能模式。
