# Function Index

## Core Module

| Symbol | Source File | Responsibility | One-Hop Project Dependencies | Minimal Test | Expansion Condition |
|---|---|---|---|---|---|
| `Get-CpuMaxFrequencyStatus` | `src/CpuMaxFrequencyControl.psm1` | Read active scheme, AC/DC MHz limit, optional CPU telemetry, and availability; `-SkipTelemetry` avoids the expensive WMI CPU query for the integrated UI. | `Invoke-CpuPowerCfg`, `Get-ActivePowerScheme`, `Get-ProcessorFrequencySetting`, `Get-CpuTelemetry` (unless skipped) | `tests/Run-Tests.ps1` parse/skip-telemetry tests | powercfg output format or status schema changes. |
| `Set-CpuMaxFrequencyLimit` | `src/CpuMaxFrequencyControl.psm1` | Validate MHz, save backup, write AC/DC `PROCFREQMAX`, and reactivate scheme. | `Assert-CpuFrequencyLimitValue`, `Ensure-CpuFrequencyBackup`, `Set-CpuPowerSettingValue` | validation tests plus manual apply | backup schema or write command behavior changes. |
| `Clear-CpuMaxFrequencyLimit` | `src/CpuMaxFrequencyControl.psm1` | Set selected AC/DC `PROCFREQMAX` values to `0` for unrestricted frequency. | `Get-ActivePowerScheme`, `Get-ProcessorFrequencySetting`, `Ensure-CpuFrequencyBackup`, `Set-CpuPowerSettingValue` | manual clear | clear semantics change from `0`. |
| `Restore-CpuMaxFrequencyLimit` | `src/CpuMaxFrequencyControl.psm1` | Restore the active scheme's saved AC/DC values. | `Get-CpuFrequencyState`, `Set-CpuPowerSettingValue` | backup parsing test | state file format changes. |
| `Enable-CpuMaxFrequencySetting` | `src/CpuMaxFrequencyControl.psm1` | Remove the hidden attribute so Windows Advanced Power Options can show the MHz setting. | `Invoke-CpuPowerCfg` | manual unhide | GUID changes or UI exposure requirements change. |
| `ConvertTo-CpuFrequencyMHz` | `src/CpuMaxFrequencyControl.psm1` | Parse user text such as `2200`, `2200 MHz`, or `2.2 GHz` to integer MHz. | none | conversion tests | accepted input format changes. |
| `Test-CpuFrequencyLimitValue` | `src/CpuMaxFrequencyControl.psm1` | Validate practical MHz range for set operations. | none | validation tests | supported range changes. |
| `ConvertFrom-CpuPowerSettingText` | `src/CpuMaxFrequencyControl.psm1` | Parse localized `powercfg /qh` output and extract AC/DC MHz values. | none | parse tests | Windows output format changes. |
| `Format-CpuFrequencyMHz` | `src/CpuMaxFrequencyControl.psm1` | Render `0` as unrestricted and nonzero MHz with GHz equivalent. | none | formatting tests | display contract changes. |

## WPF Entry

| Symbol | Source File | Responsibility | One-Hop Project Dependencies | Minimal Test | Expansion Condition |
|---|---|---|---|---|---|
| `-ValidateOnly` | `CpuMaxFrequencyControl.ps1` | Load XAML and verify the UI can be constructed without applying settings. | `src/CpuMaxFrequencyControl.psm1` | UI parse check | XAML names or module import path changes. |

## FanQuiet Integrated Entry

| Symbol | Source File | Responsibility | One-Hop Project Dependencies | Minimal Test | Expansion Condition |
|---|---|---|---|---|---|
| `Get-UiStatusSnapshot` / `Get-CpuUiStatusSnapshot` / `Set-UiStatusSnapshot` | `src/FanQuietCpuControl.ps1` | Read full CPU/fan providers or a partial power/CPU/undervolt snapshot in the worker and apply it on the WPF Dispatcher without overwriting untouched fan fields. | Lenovo helpers; `Get-CpuMaxFrequencyStatus -SkipTelemetry`; `Get-CpuUndervoltStatus` | `-AsyncLifecycleTest` (full and partial snapshots) | Snapshot schema, WPF control names, or provider schema changes. |
| `ProcessPageRefresh` / `ProcessPrioritySet` / `ProcessPriorityRestore` | `src/FanQuietCpuControl.ps1` | Run process list reads and selected-process priority actions through the serialized worker; process lists use the native process-image/window-title helpers in the priority module. | `src/ProcessPriorityControl.psm1`; `Get-GraphicsCapabilitySnapshot` | `tests/ProcessPriorityTests.ps1`; `-AsyncLifecycleTest` | Worker action-data schema, process identity, or UI selection contract changes. |
| `Get-GraphicsCapabilitySnapshot` / `Set-GraphicsCapabilityUi` | `src/FanQuietCpuControl.ps1` | Read PCI adapters from the display class registry, display observations, and official-app entries, then update the graphics page without claiming MUX support. | `Get-DisplayAdapterObservation`, `Get-StartMenuAppEntries`, WMI monitor classes, `nvidia-smi` when available | `-AsyncLifecycleTest` read-only page refresh | A documented hardware-specific MUX API becomes available or observed schema changes. |
| `Get-DisplayAdapterObservation` / `Get-StartMenuAppEntries` | `src/FanQuietCpuControl.ps1` | Enumerate PCI display-class registry keys (excluding virtual display drivers) and detect NVIDIA/Vantage Start-menu entries through one Shell COM pass. | Registry display class; Shell `shell:AppsFolder` | `-AsyncLifecycleTest` graphics refresh | Adapter registry schema or app-identity format changes. |
| `Get-LegionControllerInstance` / `Initialize-EnergyFanDriver` | `src/FanQuietCpuControl.ps1` | Cache the Lenovo WMI controller instance for one worker and compile the EnergyDrv P/Invoke helper only when fan data is requested. | Lenovo WMI class; `$energyDriverSource` | `-DriverStatusOnly`; `-AsyncLifecycleTest` | Controller WMI schema or C# helper contract changes. |
| `ApplyFrequencyButton` | `src/FanQuietCpuControl.ps1` | Parse MHz/GHz input and apply a concrete `PROCFREQMAX` limit from the FanQuiet GUI. | `ConvertTo-CpuFrequencyMHz`, `Set-CpuMaxFrequencyLimit` | module conversion tests; manual apply | button contract, frequency module write behavior, or power-scope choices change. |
| `ClearFrequencyButton` | `src/FanQuietCpuControl.ps1` | Clear the selected AC/DC frequency cap by writing `0`. | `Clear-CpuMaxFrequencyLimit` | manual clear | clear semantics change from `0`. |
| `RestoreFrequencyButton` | `src/FanQuietCpuControl.ps1` | Restore saved AC/DC `PROCFREQMAX` values for the active scheme. | `Restore-CpuMaxFrequencyLimit` | manual restore | backup schema changes. |
| `UnhideFrequencyButton` | `src/FanQuietCpuControl.ps1` | Show the hidden Windows Advanced Power Options frequency setting. | `Enable-CpuMaxFrequencySetting` | manual unhide | GUID or Windows attributes behavior changes. |
| `ApplyUndervoltButton` | `src/FanQuietCpuControl.ps1` | Apply the selected 20 mV-step Intel XTU CPU core voltage offset. | `Set-CpuUndervoltOffset`, `Get-CpuUndervoltOffsetLevels` | status/schema tests; manual hardware apply | XTU CLI contract or voltage-protection behavior changes. |
| `ClearUndervoltButton` | `src/FanQuietCpuControl.ps1` | Request a 0 mV CPU core voltage offset through Intel XTU. | `Clear-CpuUndervoltOffset` | status/schema tests; manual hardware clear | XTU CLI contract changes. |
| `SelectXtuButton` | `src/FanQuietCpuControl.ps1` | Save a user-selected `XTUCli.exe` path for the optional undervolt backend. | `Set-CpuUndervoltBackendPath` | path validation test | configuration schema changes. |

## CPU Undervolt Module

| Symbol | Source File | Responsibility | One-Hop Project Dependencies | Minimal Test | Expansion Condition |
|---|---|---|---|---|---|
| `Get-CpuUndervoltStatus` | `src/CpuUndervolt.psm1` | Detect Intel CPU from registry CPU-name values (WMI fallback), XTU CLI, XTU service, administrator state, and last requested offset. | `Get-CpuUndervoltCpuInfo`, `Find-CpuUndervoltCli`, `Get-CpuUndervoltService` | `tests/Run-Tests.ps1` schema check | backend discovery or status contract changes. |
| `Set-CpuUndervoltOffset` | `src/CpuUndervolt.psm1` | Validate 20 mV step and invoke XTU setting ID 34. | `Invoke-CpuUndervoltXtu`, `Start-CpuUndervoltService` | validation tests; manual apply | XTU CLI or BIOS undervolt-protection behavior changes. |
| `Clear-CpuUndervoltOffset` | `src/CpuUndervolt.psm1` | Invoke XTU with a 0 mV offset. | `Set-CpuUndervoltOffset` | validation tests; manual clear | XTU CLI contract changes. |
| `Get-CpuUndervoltOffsetLevels` | `src/CpuUndervolt.psm1` | Canonical 0/-20...-120 mV level list. | none | level count/step tests | supported range decision changes. |

## Process Priority Module

| Symbol | Source File | Responsibility | One-Hop Project Dependencies | Minimal Test | Expansion Condition |
|---|---|---|---|---|---|
| `Get-ProcessPrioritySnapshot` | `src/ProcessPriorityControl.psm1` | List current-session desktop/background programs with priority, restore status, and eligibility reason; uses one native window-title map, direct process-image paths, and a prebuilt backup index. | `Get-ProcessPriorityBackupState`; `Initialize-FastProcessPath`; process identity helpers | `tests/ProcessPriorityTests.ps1` | Session scope or list row schema changes. |
| `Initialize-FastProcessPath` | `src/ProcessPriorityControl.psm1` | Compile the in-memory `FanQuietProcessPath` helper that queries process image names and visible window titles with Win32 APIs. | none | `tests/ProcessPriorityTests.ps1` | Win32 API or identity path contract changes. |
| `Set-ManagedProcessPriority` | `src/ProcessPriorityControl.psm1` | Save the original level, verify PID/start time/path/session/user, then set one supported non-Realtime priority. | identity and backup helpers | isolated child-process integration test | Allowed priority classes or identity contract changes. |
| `Restore-ManagedProcessPriority` | `src/ProcessPriorityControl.psm1` | Restore the saved level only for the same verified process identity and remove its record, reporting separately if record cleanup fails after the restore. | identity and backup helpers | isolated child-process integration test | Backup schema or retry behavior changes. |

## CLI Entry

| Symbol | Source File | Responsibility | One-Hop Project Dependencies | Minimal Test | Expansion Condition |
|---|---|---|---|---|---|
| `-Action Status|Set|Clear|Restore|Unhide` | `CpuMaxFrequencyCli.ps1` | Provide scriptable command surface and machine-readable JSON output. | `src/CpuMaxFrequencyControl.psm1` | read-only status and test runner | parameter contract changes. |
