# Architecture

## Technology Route

PowerShell 5.1-compatible Windows desktop utility. The exact CPU maximum frequency is controlled through the hidden Windows power setting `PROCFREQMAX` (`75b0ae3f-bce0-45a7-8c89-c9611c25e100`) under `SUB_PROCESSOR`. Values are stored in MHz. `0` means unrestricted.

The primary UI is the integrated FanQuiet WPF window at `src/FanQuietCpuControl.ps1`. It keeps the Lenovo fan controls and imports sibling CPU frequency, undervolt, and process-priority modules. CPU status sampling and settings actions run in one background PowerShell worker; process-priority actions use the same serialized worker but return only the relevant process list, while graphics information is read only when its tab is opened. Frequency and undervolt actions return a partial CPU snapshot (power policy, CPU frequency, and undervolt status); full refreshes and fan-mode actions read the Lenovo controller. The WPF Dispatcher applies returned JSON data. Model/BIOS data comes from registry values, PCI display adapters from the display class registry, and Start-menu app entries from one Shell COM enumeration. Worker processes do not load WPF assemblies, and the Lenovo EnergyDrv helper is compiled only when fan data is needed. The optional local `vendor/FanQuiet/` reference snapshot is excluded from the public repository pending license and attribution details; it is not a runtime or build source. The standalone WPF and CLI entries also share `src/CpuMaxFrequencyControl.psm1`.
CPU undervolting is a separate optional responsibility in `src/CpuUndervolt.psm1`. It uses the installed Intel XTU CLI (`XTUCli.exe`, setting ID 34) and never substitutes a percentage power policy or an arbitrary kernel/MSR driver.

## Directory Structure

| Path | Responsibility |
|---|---|
| `CpuMaxFrequencyControl.ps1` | WPF desktop entry point and elevation wrapper. |
| `CpuMaxFrequencyCli.ps1` | Scriptable CLI for status, set, clear, restore, and unhide actions. |
| `src/FanQuietCpuControl.ps1` | Canonical integrated FanQuiet WPF entry; runs status reads and actions in a single background worker. |
| `启动CPU频率控制工具.cmd` | Double-click launcher for the integrated FanQuiet entry point. |
| `packaging/Build-Exe.ps1` | Builds the single-file IExpress EXE from the integrated FanQuiet entry and required CPU/process modules. |
| `packaging/Launcher.ps1` | Expands the packaged runtime into `%LOCALAPPDATA%` before launching FanQuiet, so UAC elevation retains its dependencies. |
| `dist/FanQuietCpuControl.exe` | Generated single-file Windows GUI package; not source-controlled. |
| `src/CpuMaxFrequencyControl.psm1` | Core powercfg adapter, validation, backup, restore, formatting, and telemetry helpers. |
| `src/CpuUndervolt.psm1` | Intel XTU discovery, 20 mV level validation, backend selection, and XTU voltage-offset invocation. |
| `src/ProcessPriorityControl.psm1` | Current-session process classification, PID/start-time/path/user validation, bounded priority choices, and original-priority recovery records. |
| `tests/Run-Tests.ps1` | Dependency-free PowerShell test runner. |
| `vendor/FanQuiet/` | Optional local reference snapshot; excluded from the public repository pending license and attribution details; not used by launchers or packaging. |
| `ai-context/` | Maintenance records and function index. |

## Module Responsibilities

| Module | Responsibilities | Public Interfaces | Function Index | Read Boundary |
|---|---|---|---|---|
| `src/CpuMaxFrequencyControl.psm1` | Owns all Windows power setting access, input validation, backup JSON state, and status model. `-SkipTelemetry` omits the expensive WMI CPU telemetry for the integrated UI. | `Get-CpuMaxFrequencyStatus` (`-SkipTelemetry`), `Set-CpuMaxFrequencyLimit`, `Clear-CpuMaxFrequencyLimit`, `Restore-CpuMaxFrequencyLimit`, `Enable-CpuMaxFrequencySetting`, `ConvertTo-CpuFrequencyMHz`, `Test-CpuFrequencyLimitValue`, `ConvertFrom-CpuPowerSettingText`, `Format-CpuFrequencyMHz` | `FUNCTION_INDEX.md#core-module` | Target function plus one-hop helper and related test. |
| `src/FanQuietCpuControl.ps1` | Owns the integrated Lenovo fan WPF UI, serialized worker request dispatch, partial/full CPU snapshots, fast process/graphics page providers, and Dispatcher-only UI updates. | UI buttons, `-ValidateOnly`, `-DriverStatusOnly`, internal `-WorkerAction`, test-only `-AsyncLifecycleTest` | `FUNCTION_INDEX.md#fanquiet-integrated-entry` | Integrated entry plus shared modules and lifecycle test. |
| `vendor/FanQuiet/FanQuiet.ps1` | Optional local reference snapshot only; not included in the public repository or used at runtime. | none | `FUNCTION_INDEX.md#fanquiet-integrated-entry` | Read only when comparing the local reference snapshot. |
| `CpuMaxFrequencyControl.ps1` | Owns WPF window, user interaction, and admin relaunch. | `-ValidateOnly` | `FUNCTION_INDEX.md#wpf-entry` | Entry file plus module public functions it calls. |
| `CpuMaxFrequencyCli.ps1` | Owns command-line parameter contract and output formatting. | `-Action Status|Set|Clear|Restore|Unhide`, `-MHz`, `-Power`, `-Json` | `FUNCTION_INDEX.md#cli-entry` | Entry file plus module public functions it calls. |

## Call Flow

The integrated UI, standalone UI, or CLI imports `src/CpuMaxFrequencyControl.psm1`, reads the active power scheme, queries `PROCFREQMAX` with `powercfg /qh`, and parses AC/DC MHz values. The integrated UI serializes refreshes and actions through one child PowerShell worker, drains stdout and stderr asynchronously, and updates WPF controls on the Dispatcher. Frequency and undervolt actions return a partial snapshot built from the power policy, CPU frequency, and undervolt status; full refreshes and fan-mode actions also read the cached Lenovo WMI instance and EnergyDrv. A read-only refresh can be cancelled on timeout or window close; a settings write is never terminated and keeps the window open until it completes. Mutating frequency actions first save the current AC/DC values for the active scheme to `%LOCALAPPDATA%\CpuMaxFrequencyControl\power-frequency-backup.json`, then call `powercfg /setacvalueindex` and/or `/setdcvalueindex`, followed by `powercfg /setactive`.
The FanQuiet UI also imports `src/CpuUndervolt.psm1`. It discovers Intel XTU CLI automatically or stores a user-selected path in `%LOCALAPPDATA%\FanQuietCpuControl\undervolt-backend.json`; an apply action calls `XTUCli.exe -t -id 34 -v <offset-mV>`. The module records the last requested offset separately because legacy XTU CLI does not provide a reliable readback API.

The FanQuiet UI also imports `src/ProcessPriorityControl.psm1`. A user-selected current-session process is validated by PID, UTC start-time ticks, full executable path, session, and owner before setting or restoring one of `Idle`, `BelowNormal`, `Normal`, `AboveNormal`, or `High`; the first original level is saved under `%LOCALAPPDATA%\FanQuietCpuControl\process-priority-backups.json`. The process list uses one native window-title enumeration (`EnumWindows`) and a direct process-image query instead of per-process `MainWindowHandle`/`MainModule` access. The graphics page reads PCI display adapters from the Windows display class registry, display observations from WMI/WinForms, and Start-menu entries through Shell COM, but does not infer physical MUX support from Windows per-app GPU preference or NVIDIA telemetry.

## Verification Boundary

Fast tests cover parsing, validation, GHz/MHz conversion, process priority backup/identity/restore against a test-owned child process, and the asynchronous UI lifecycle with synthetic delayed/success/failure/partial-snapshot worker actions plus real read-only snapshots; they do not run fan, power-policy, XTU, GPU-switching, or BIOS writes, and do not change pre-existing processes. The layout fixture renders default/minimum sizes, checks the status indicator and CPU metric tiles, asserts no CPU-page horizontal overflow, and verifies process-table and graphics-entry reachability. Read-only status can run on the local machine. Applying a limit changes the active Windows power scheme and should be verified manually on the intended hardware.
Undervolt tests cover 20 mV level validation and backend status schema without invoking XTU. Applying an offset is deliberately not run during automated verification because it changes CPU voltage and can destabilize the machine. The actual fan/power-policy/XTU writes and an interactive packaged window were not exercised in this pass.

## Scope Expansion Conditions

Expand beyond the target file only when a failing test, stack trace, public parameter change, setting GUID change, or runtime error proves the current one-hop context is insufficient.
