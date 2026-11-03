# FanQuiet CPU Max Frequency Control

Windows PowerShell FanQuiet GUI with an added CPU maximum frequency control panel. It sets the CPU maximum frequency by an explicit MHz/GHz value through the hidden Windows processor power setting `PROCFREQMAX` (`75b0ae3f-bce0-45a7-8c89-c9611c25e100`) under `SUB_PROCESSOR`.

This is separate from FanQuiet's older "maximum processor state" percentage option. The FanQuiet quiet-mode checkbox still controls the legacy percentage policy, while the new CPU frequency panel writes a concrete MHz value.

`0` means unrestricted. Normal set operations require a value from `100` to `100000` MHz; use `Clear` to write `0`.

## Run

Open the integrated FanQuiet desktop UI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\FanQuietCpuControl.ps1
```

You can also double-click:

```text
启动CPU频率控制工具.cmd
```

## EXE Package

The package builder is included, but generated binaries are not. After building, the ready-to-run single-file package appears at:

```text
dist\FanQuietCpuControl.exe
```

Double-click the EXE to open the same integrated FanQuiet GUI. The EXE uses Windows built-in IExpress and does not require a separate PowerShell packaging dependency. On first launch it copies the runtime scripts to `%LOCALAPPDATA%\FanQuietCpuControl` before the GUI requests administrator permission; this keeps the GUI and CPU frequency module available after UAC elevation.

Rebuild the package locally:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Exe.ps1
```

Package build verification:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Build-PackageTests.ps1
```

Read status from the standalone CLI without changing the active power plan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyCli.ps1 -Action Status
```

Set an exact maximum frequency:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyCli.ps1 -Action Set -MHz "2.2 GHz" -Power Both
```

Clear the frequency cap:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyCli.ps1 -Action Clear -Power Both
```

Restore the first saved values for the current active power scheme:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyCli.ps1 -Action Restore
```

Show the hidden Windows Advanced Power Options entry:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyCli.ps1 -Action Unhide
```

## Verification

The test runner does not change the active power plan, BIOS, or pre-existing user processes. Its process-priority integration test changes and restores only a short-lived test-owned PowerShell child:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

UI parse check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyControl.ps1 -ValidateOnly
```

Integrated FanQuiet UI parse check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\FanQuietCpuControl.ps1 -ValidateOnly
```

Run the WPF layout/reachability fixture (renders default/minimum-size PNGs under `build\layout-preview`):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\FanQuietLayoutTests.ps1
```

The fixture also verifies the status indicator, CPU metric tiles, the minimum-size process-table height, graphics-entry reachability, and that the CPU page has no horizontal overflow.

## FanQuiet Integration

The original FanQuiet files are kept locally in `vendor/FanQuiet` as a reference snapshot and are excluded from this public repository because no license information accompanies them. The canonical integrated UI is `src/FanQuietCpuControl.ps1`; it imports the sibling CPU modules and exposes these controls:

- Current AC/DC maximum frequency status.
- MHz/GHz input, for example `2200` or `2.2 GHz`.
- Scope selector for AC, DC, or both.
- Apply, clear, restore, and show-Windows-option buttons.

The integration keeps FanQuiet's existing patterns for:

- Windows PowerShell WPF entry point.
- Administrator relaunch for hardware/power-policy writes.
- `powercfg` wrapper with explicit failure handling.
- Per-power-scheme JSON backup before changing values.

Status reads and button actions run in one background PowerShell worker. The window stays responsive while the worker runs, reports action and refresh failures separately, and blocks overlapping operations. Closing during a read-only refresh cancels that worker; closing during a settings write waits for it to finish so the write is not interrupted. Frequency and undervolt actions return a partial CPU snapshot (power policy, CPU frequency, and undervolt status) without re-reading the Lenovo fan controller; full refreshes and fan-mode actions use the complete snapshot. `tests/Run-Tests.ps1` exercises this lifecycle with synthetic delayed/failing/partial-snapshot actions plus real read-only refreshes; it does not apply fan, power-policy, or XTU changes.

The integrated window has separate `风扇与 CPU`, `程序优先级`, and `显卡与显示` tabs. It opens at about 980×760 DIP and respects the available desktop work area. The visual system uses white rounded cards on a cool gray background, a teal accent for active modes and primary actions, metric tiles for temperatures/fans, and a severity-colored status bar with its own scrolling. The CPU page keeps the frequent controls before the reference cards and never requires horizontal scrolling; diagnostics and undervolting details start folded. The process page uses a compact toolbar, a full-height virtualized table with ellipsized cells, and a selected-row details panel. The graphics page puts the official-entry buttons before the MUX notes and scrolls independently. The layout test renders 980×760 and 800×600 fixtures and asserts that key controls remain reachable and that the CPU page has no horizontal overflow.

Worker processes do not load WPF assemblies. Model information comes from the BIOS registry values, display adapters from the Windows display class registry, and Start-menu app entries from a single Shell COM enumeration; the Lenovo EnergyDrv helper is compiled only when fan data is required. These changes remove the previous 12–18 s per-refresh WMI video-controller query and the 3–10 s `Get-StartApps` call.

The standalone `CpuMaxFrequencyControl.ps1` and `CpuMaxFrequencyCli.ps1` are still kept for direct testing and scripting, but the main GUI entry is now the integrated FanQuiet window.

## Program Priorities and Graphics

The `程序优先级` tab lists programs in the current user session, separated into desktop-window and background programs. Select one row, choose `Idle`, `BelowNormal`, `Normal`, `AboveNormal`, or `High`, then apply or restore. `Realtime` is unavailable. The tool saves the original priority before a change and rechecks PID, UTC start time, executable path, session, and user before applying or restoring. System-critical and desktop-shell processes, the tool itself, exited processes, other sessions, and processes whose identity or owner cannot be verified stay unavailable. It does not automatically change priorities.

Priority operations run through the existing background worker. List and graphics reads are cancellable read-only jobs; applying or restoring a priority is a write and is allowed to finish before the window closes. The list uses one native window-title enumeration and a direct process-image query instead of per-process module lookups, so it no longer pays the previous multi-second module-access penalty. The recovery list is stored at `%LOCALAPPDATA%\FanQuietCpuControl\process-priority-backups.json`. If the priority is restored but the record cannot be removed, the UI says the priority is already restored and leaves the record available for retry.

The `显卡与显示` tab reports installed PCI display adapters from the Windows display class registry, the active-display observation available from Windows, and NVIDIA display telemetry when available. Start-menu entries for the NVIDIA Control Panel and Lenovo Vantage are detected with a single Shell COM enumeration. This does not establish whether the laptop has a physical display multiplexer (MUX). In a read-only check of this Lenovo Legion Y7000 2019 1050 (`81V4`), Windows reported Intel UHD Graphics 630 and NVIDIA GeForce GTX 1050; the existing Lenovo GameZone GPU classes exposed temperature/overclock data but no CIM switching method, and no documented Lenovo graphics-switch provider was found. This leaves hardware MUX support unverified; it does not prove the hardware lacks a MUX. The utility does not disable the integrated GPU, write firmware settings, or claim to switch the display path.

The NVIDIA Control Panel and Lenovo Vantage buttons are enabled only when a registered app entry is detected. The Windows button opens the per-app GPU preference page; that preference selects an application's GPU and does not change which GPU physically drives the internal display. NVIDIA describes display MUX selection as choosing the GPU that drives a display, and says to check Advanced Optimus support in NVIDIA App under `System > My Rig > View Rig Details`. See the official [81V4 Lenovo PSREF](https://psref.lenovo.com/Detail/Lenovo_Legion_Y7000_2019_1050?M=81V4000LIN), [Y7000 2019 BIOS setup guide](https://download.lenovo.com/pccbbs/pubs/y7000_2019/html_ja/ja/task_start_bios_setup.html), [Lenovo Vantage self-help guide](https://download.lenovo.com/pccbbs/pubs/legion_y7000_2019_1050/html_en/en/self-help_resources.html), [NVIDIA Display Multiplexer reference](https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/3D%20Settings/Display_Multiplexer.htm), and [NVIDIA Advanced Optimus support check](https://www.nvidia.com/en-au/geforce/news/nvidia-app-update-dlss-overrides-and-more/).

## CPU Undervolting

The integrated FanQuiet GUI now includes CPU core voltage undervolting in fixed 20 mV steps: `0`, `-20`, `-40`, `-60`, `-80`, `-100`, and `-120 mV`. It starts at `-20 mV` so the user can test stability one step at a time.

This control uses Intel XTU's `XTUCli.exe` setting ID 34. Windows `powercfg` cannot change CPU voltage, so the control is disabled until a compatible XTU CLI is detected. Use `选择 XTU` in the GUI to select an existing `XTUCli.exe` when it is not in the standard Intel installation directory. The current machine did not have XTU installed during development, so the actual voltage write was not run here.

The displayed value is the last requested offset; legacy XTU CLI does not expose a reliable readback API. BIOS or microcode Undervolt Protection may reject the request. Start with `-20 mV`, test under load, and restore to `0 mV` if the system becomes unstable. A voltage offset can cause crashes, blue screens, data loss, or failure to resume from sleep.

## Limitations

Windows accepts `PROCFREQMAX` in MHz, but firmware, CPU generation, drivers, boost policy, virtualization, and OEM power managers can affect whether the observed clock exactly follows the cap. The status screen shows the configured cap and WMI-reported clock; it cannot guarantee every core will report the same instantaneous frequency.

Applying, clearing, restoring, or unhiding settings changes the active Windows power scheme and should be run as administrator.
