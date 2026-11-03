# Project AI Maintenance Rules

## Read Boundary

- `project_root`: this directory only.
- Start with `ai-context/ARCHITECTURE.md`, `ai-context/FUNCTION_INDEX.md`, and `ai-context/BUG_HISTORY.md`.
- Do not scan the parent workspace to discover source files.
- Default scope for changes is the named entry script, module function, or test file plus one-hop project-owned dependencies.

## Search Gate

- Search only this project root unless the user explicitly names another path.
- Prefer exact function names, file names, command names, setting GUIDs, or error text.
- Exclude `.git`, build output, caches, credentials, and unrelated sibling projects.

## Modification Rules

- Do not overwrite or delete files outside this project.
- Keep the local `vendor/FanQuiet` reference snapshot out of public uploads unless its license and attribution are confirmed.
- Public behavior for CPU frequency control belongs in `src/CpuMaxFrequencyControl.psm1`; UI and CLI should call that module instead of duplicating powercfg logic.

## Verification

- Fast test: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`
- UI parse check: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyControl.ps1 -ValidateOnly`
- FanQuiet integrated UI parse check: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\FanQuietCpuControl.ps1 -ValidateOnly`
- Read-only status check: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CpuMaxFrequencyCli.ps1 -Action Status`
- Package build check: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Build-PackageTests.ps1`
- Undervolt level/status test: covered by `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`; do not run an XTU apply action in automated tests.
