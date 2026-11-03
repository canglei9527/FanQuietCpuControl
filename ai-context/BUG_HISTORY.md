# Bug History

## Initial Record

- Created: 2026-08-19
- Technology route: PowerShell WPF and CLI utility using Windows `powercfg` `PROCFREQMAX` in MHz, based on the power-policy patterns from `FanQuiet`.

## 2026-08-19 FanQuiet GUI Integration

- User clarified that concrete CPU frequency control should live inside the FanQuiet GUI, not only in a separate CPU frequency window.
- Updated `vendor/FanQuiet/FanQuiet.ps1` to import the shared CPU frequency module and expose MHz/GHz apply, clear, restore, and unhide controls.
- Updated the root launcher so double-click startup opens the integrated FanQuiet GUI.

## 2026-10-01 Integrated UI Responsiveness

- Confirmed the integrated UI ran Lenovo telemetry, powercfg/CIM frequency status, XTU status discovery, and control writes synchronously inside WPF click handlers; the Legion mode setter also slept for 800 ms before readback.
- Added the project-owned canonical entry `src/FanQuietCpuControl.ps1`; the copied `vendor/FanQuiet` snapshot remains unchanged and is no longer used by launchers or the package build.
- Moved status refreshes and control actions to one background PowerShell worker, with asynchronous stdout/stderr draining, Dispatcher-only UI updates, a single-operation guard, separate action/status outcomes, visible errors, read-only refresh cancellation, and close deferral while a settings write is active.
- Added a synthetic WPF lifecycle check for dispatcher heartbeat, overlap blocking, failure reporting, and retry recovery. Real fan, power-policy, XTU writes, and a manually operated packaged window were not exercised.

## 2026-10-01 Integrated UI Layout

- Reorganized the integrated window into separate fan/CPU, program-priority, and graphics/display tabs; set a wider default window while clamping it to the desktop work area.
- Folded low-frequency CPU diagnostics and undervolting details, let the process table fill its tab, kept selected-process details and global status visible, and gave graphics its own scrollable body.
- Replaced the old fixed CPU-panel row-count assertion with XAML structure and WPF reachability checks. Default/minimum-size previews include long Chinese process/path and status fixtures, plus a minimum-size graphics view scrolled to expanded details; fixture previews do not alter machine settings.

## 2026-10-17 UI Aesthetics, Latency, and Layout

- Confirmed the UI still used default WPF control chrome, flat group boxes, and a dense status strip; the CPU page overflowed horizontally at 800×600, and key actions fell below the fold.
- Baseline worker timings on this machine: refresh 4.75–6.31 s, process page 6.88–7.58 s, graphics page 16.29–16.37 s. Root causes included a synchronous `Win32_ComputerSystemProduct` lookup before the first window, `Win32_VideoController` WMI at 12–18 s per refresh, `Get-StartApps` at 3–10 s, per-process `MainWindowHandle` and `MainModule` access, a per-process module compile for every worker, and a 1.1 s WMI CPU telemetry read for every status refresh.
- Rebuilt the integrated window with a card-based visual system: metric tiles, rounded white cards, a teal accent for active modes and primary actions, custom buttons/inputs/combo boxes/tabs/tables/expanders/scrollbars, a severity-colored status bar, and a compact process toolbar. The CPU page now orders actions before reference cards, disables horizontal scrolling, and the layout fixture asserts no horizontal overflow; graphics entries precede the MUX notes; diagnostics and undervolt details stay folded.
- Removed the synchronous model WMI call (registry BIOS values), guarded WPF assembly loading to the UI host, compiled the EnergyDrv helper only when fan data is needed, added `Get-CpuMaxFrequencyStatus -SkipTelemetry`, switched undervolt CPU detection to registry values, cached the Lenovo WMI controller instance, and added partial CPU snapshots for frequency/undervolt/restore-power actions so they do not re-read the fan controller.
- Process page: replaced per-process `MainWindowTitle`/`MainModule` with one native `EnumWindows` title map and `QueryFullProcessImageName`, and prebuilt the priority-backup index. Graphics page: replaced the video-controller WMI query with PCI display-class registry enumeration, and `Get-StartApps` with one Shell COM `shell:AppsFolder` pass. After changes: refresh 4.14–4.97 s, process page 4.46–5.34 s, graphics page 4.31–5.02 s; partial CPU snapshots measured 1.74–2.43 s.
- Updated the layout fixture (status indicator, metrics, minimum-size process table, graphics reachability, horizontal-overflow guard) and ran the full isolated suite, async lifecycle test, IExpress package build/payload check, and packaged `-ValidateOnly` check successfully. Real fan, power-policy, XTU, GPU-switching, and BIOS writes and an interactively operated packaged window were not exercised.
