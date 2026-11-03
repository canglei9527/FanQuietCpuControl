Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AllowedProcessPriorities = @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')
$script:ProtectedProcessNames = @(
    'System', 'Registry', 'Idle', 'smss', 'csrss', 'wininit', 'services', 'lsass',
    'winlogon', 'dwm', 'svchost', 'explorer', 'fontdrvhost', 'sihost', 'ctfmon'
)

$script:FastProcessPathSource = @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

public static class FanQuietProcessPath
{
    private const uint QueryLimitedInformation = 0x1000;

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder text, ref int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    public static string Get(int processId)
    {
        IntPtr handle = OpenProcess(QueryLimitedInformation, false, processId);
        if (handle == IntPtr.Zero)
            return null;

        try
        {
            int size = 2048;
            StringBuilder text = new StringBuilder(size);
            if (!QueryFullProcessImageName(handle, 0, text, ref size))
                return null;

            return text.ToString();
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    public static Dictionary<int, string> GetWindowTitles()
    {
        Dictionary<int, string> titles = new Dictionary<int, string>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window))
                return true;

            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == 0)
                return true;

            StringBuilder text = new StringBuilder(512);
            if (GetWindowText(window, text, text.Capacity) <= 0)
                return true;

            string title = text.ToString();
            int key = (int)processId;
            if (title.Length > 0 && !titles.ContainsKey(key))
                titles[key] = title;

            return true;
        }, IntPtr.Zero);

        return titles;
    }
}
'@


function Initialize-FastProcessPath {
    if ($null -eq ('FanQuietProcessPath' -as [type])) {
        Add-Type -TypeDefinition $script:FastProcessPathSource
    }
}

function Get-ProcessPriorityBackupPath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA 不可用，无法安全保存进程优先级恢复记录。'
    }

    return Join-Path $env:LOCALAPPDATA 'FanQuietCpuControl\process-priority-backups.json'
}

function Get-ProcessPriorityBackupState {
    param([string]$BackupPath = (Get-ProcessPriorityBackupPath))

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        return [pscustomobject]@{ Version = 1; Backups = @() }
    }

    try {
        $state = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$state.Version -ne 1 -or $null -eq $state.Backups) {
            throw '备份格式或版本无效。'
        }
        return $state
    }
    catch {
        throw "进程优先级恢复记录无法读取；未修改进程：$($_.Exception.Message)"
    }
}

function Enter-ProcessPriorityBackupLock {
    param([Parameter(Mandatory)][string]$BackupPath)

    $canonicalPath = [System.IO.Path]::GetFullPath($BackupPath).ToUpperInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonicalPath))
        $pathHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }

    $mutexName = "Local\FanQuietCpuControl.ProcessPriority.$pathHash"
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    try {
        $lockAcquired = $false
        try {
            $lockAcquired = $mutex.WaitOne(15000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }
        if (-not $lockAcquired) {
            throw '等待进程优先级恢复记录锁超时。'
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw "无法取得进程优先级恢复记录锁；未修改目标进程：$($_.Exception.Message)"
    }
}

function Exit-ProcessPriorityBackupLock {
    param([Parameter(Mandatory)][System.Threading.Mutex]$Mutex)

    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Save-ProcessPriorityBackupState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$BackupPath
    )

    $directory = Split-Path -Parent $BackupPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = "$BackupPath.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $temporaryBackupPath = "$BackupPath.$PID.$([Guid]::NewGuid().ToString('N')).bak"
    $json = $State | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $BackupPath, $temporaryBackupPath, $false)
            if (Test-Path -LiteralPath $temporaryBackupPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryBackupPath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $BackupPath)
        }
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        throw "无法保存进程优先级恢复记录：$($_.Exception.Message)"
    }
}

function Get-ProcessPriorityIdentityKey {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$ExecutablePath
    )

    return "$ProcessId|$StartTimeUtcTicks|$($ExecutablePath.ToUpperInvariant())"
}

function Get-ProcessPriorityIdentity {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

    if ($Process.HasExited) {
        throw '目标进程已退出。'
    }

    try {
        $startTimeUtcTicks = [long]$Process.StartTime.ToUniversalTime().Ticks
        Initialize-FastProcessPath
        $executablePath = [FanQuietProcessPath]::Get([int]$Process.Id)
        if ([string]::IsNullOrWhiteSpace($executablePath)) {
            $executablePath = $Process.MainModule.FileName
        }
        $executablePath = [System.IO.Path]::GetFullPath($executablePath)
    }
    catch {
        throw "无法读取目标进程的启动时间或可执行文件路径；可能没有权限：$($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($executablePath)) {
        throw '无法确认目标进程的可执行文件路径。'
    }

    return [pscustomobject]@{
        ProcessId = [int]$Process.Id
        StartTimeUtcTicks = $startTimeUtcTicks
        ExecutablePath = $executablePath
    }
}

function Assert-CurrentUserProcess {
    param([Parameter(Mandatory)][int]$ProcessId)

    $processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    if ($null -eq $processInfo) {
        throw '目标进程已退出或无法查询。'
    }

    $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    if ([int]$processInfo.SessionId -ne $currentSessionId) {
        throw '拒绝调整其他会话中的进程。'
    }

    $owner = Invoke-CimMethod -InputObject $processInfo -MethodName GetOwner -ErrorAction Stop
    if ([int]$owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace([string]$owner.User)) {
        throw '无法确认目标进程所属用户，已跳过。'
    }

    try {
        $ownerName = if ([string]::IsNullOrWhiteSpace([string]$owner.Domain)) { [string]$owner.User } else { "$($owner.Domain)\$($owner.User)" }
        $ownerSid = (New-Object System.Security.Principal.NTAccount($ownerName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        throw "无法验证目标进程所属用户，已跳过：$($_.Exception.Message)"
    }

    if (-not [string]::Equals($ownerSid, $currentSid, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝调整其他用户的进程。'
    }
}

function Get-ProcessPrioritySnapshot {
    param(
        [int]$ProtectedProcessId = 0,
        [string]$BackupPath = (Get-ProcessPriorityBackupPath)
    )

    $state = Get-ProcessPriorityBackupState -BackupPath $BackupPath
    $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $workerProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $liveKeys = @{}
    $windowTitleMap = @{}
    try {
        Initialize-FastProcessPath
        $windowTitleMap = [FanQuietProcessPath]::GetWindowTitles()
    }
    catch {
    }
    $backupIndex = @{}
    foreach ($backup in @($state.Backups)) {
        $backupKey = Get-ProcessPriorityIdentityKey -ProcessId ([int]$backup.ProcessId) -StartTimeUtcTicks ([long]$backup.StartTimeUtcTicks) -ExecutablePath ([string]$backup.ExecutablePath)
        if (-not $backupIndex.ContainsKey($backupKey)) { $backupIndex[$backupKey] = $backup }
    }

    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $currentSessionId) { continue }
        }
        catch {
            continue
        }

        if ($process.Id -eq $workerProcessId) { continue }

        $isProtectedUi = $ProtectedProcessId -gt 0 -and $process.Id -eq $ProtectedProcessId
        $isCritical = $script:ProtectedProcessNames -contains $process.ProcessName
        $reason = $null
        $canAdjust = $true
        $priorityName = '不可读取'
        $startTimeUtcTicks = $null
        $executablePath = $null
        $windowTitle = ''

        try { $priorityName = [string]$process.PriorityClass } catch { $canAdjust = $false; $reason = '无法读取当前优先级，可能没有权限。' }
        $windowTitle = if ($windowTitleMap.ContainsKey($process.Id)) { [string]$windowTitleMap[$process.Id] } else { '' }

        if ($isProtectedUi) {
            $canAdjust = $false
            $reason = 'FanQuiet 控制窗口进程受保护。'
        }
        elseif ($isCritical) {
            $canAdjust = $false
            $reason = '系统关键或桌面 Shell 进程受保护。'
        }
        else {
            try {
                $identity = Get-ProcessPriorityIdentity -Process $process
                $startTimeUtcTicks = [long]$identity.StartTimeUtcTicks
                $executablePath = [string]$identity.ExecutablePath
            }
            catch {
                $canAdjust = $false
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = $_.Exception.Message }
            }
        }

        $hasBackup = $false
        $originalPriority = $null
        if ($null -ne $startTimeUtcTicks -and -not [string]::IsNullOrWhiteSpace($executablePath)) {
            $identityKey = Get-ProcessPriorityIdentityKey -ProcessId $process.Id -StartTimeUtcTicks $startTimeUtcTicks -ExecutablePath $executablePath
            $liveKeys[$identityKey] = $true
            if ($backupIndex.ContainsKey($identityKey)) {
                $hasBackup = $true
                $originalPriority = [string]$backupIndex[$identityKey].OriginalPriority
            }
        }

        $category = if (-not [string]::IsNullOrWhiteSpace($windowTitle)) { '桌面窗口' } else { '当前会话后台程序' }
        if ($canAdjust -and -not $hasBackup) { $reason = '当前会话；应用时复核 PID、启动时间、路径和用户。' }
        elseif ($canAdjust -and $hasBackup) { $reason = '已保存原优先级；恢复前会复核进程身份。' }

        $rows.Add([pscustomobject]@{
            ProcessName = [string]$process.ProcessName
            ProcessId = [int]$process.Id
            Category = $category
            WindowTitle = $windowTitle
            CurrentPriority = $priorityName
            OriginalPriority = $originalPriority
            CanAdjust = $canAdjust
            CanRestore = ($canAdjust -and $hasBackup)
            HasBackup = $hasBackup
            Reason = $reason
            ExecutablePath = $executablePath
            StartTimeUtcTicks = $startTimeUtcTicks
        })
    }

    foreach ($backup in @($state.Backups)) {
        $key = Get-ProcessPriorityIdentityKey -ProcessId ([int]$backup.ProcessId) -StartTimeUtcTicks ([long]$backup.StartTimeUtcTicks) -ExecutablePath ([string]$backup.ExecutablePath)
        if ($liveKeys.ContainsKey($key)) { continue }
        $rows.Add([pscustomobject]@{
            ProcessName = [string]$backup.ProcessName
            ProcessId = [int]$backup.ProcessId
            Category = '原恢复记录'
            WindowTitle = ''
            CurrentPriority = '进程已退出或身份变化'
            OriginalPriority = [string]$backup.OriginalPriority
            CanAdjust = $false
            CanRestore = $false
            HasBackup = $true
            Reason = '进程已退出或 PID/启动时间/路径不匹配，不能恢复到其他进程。'
            ExecutablePath = [string]$backup.ExecutablePath
            StartTimeUtcTicks = [long]$backup.StartTimeUtcTicks
        })
    }

    return @($rows | Sort-Object @{ Expression = { switch ($_.Category) { '桌面窗口' { 0 } '当前会话后台程序' { 1 } default { 2 } } } }, ProcessName, ProcessId)
}

function Get-VerifiedPriorityProcess {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [int]$ProtectedProcessId = 0
    )

    if ($ProcessId -eq $ProtectedProcessId -or $ProcessId -eq [System.Diagnostics.Process]::GetCurrentProcess().Id) {
        throw '拒绝调整 FanQuiet 控制窗口或 worker 本体。'
    }

    $process = $null
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($script:ProtectedProcessNames -contains $process.ProcessName) {
            throw '拒绝调整系统关键或桌面 Shell 进程。'
        }
        $identity = Get-ProcessPriorityIdentity -Process $process
        if ($identity.StartTimeUtcTicks -ne $StartTimeUtcTicks -or -not [string]::Equals($identity.ExecutablePath, [System.IO.Path]::GetFullPath($ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw '进程身份已变化（PID、启动时间或路径不匹配），请刷新列表后重试。'
        }
        $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        if ($process.SessionId -ne $currentSessionId) {
            throw '拒绝调整其他会话中的进程。'
        }
        Assert-CurrentUserProcess -ProcessId $ProcessId
        return $process
    }
    catch {
        if ($null -ne $process) { $process.Dispose() }
        throw
    }
}

function Set-ManagedProcessPriority {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$Priority,
        [int]$ProtectedProcessId = 0,
        [string]$BackupPath = (Get-ProcessPriorityBackupPath)
    )

    if ($script:AllowedProcessPriorities -notcontains $Priority) {
        throw "不支持的进程优先级：$Priority。可选 Idle、BelowNormal、Normal、AboveNormal 或 High；Realtime 已禁用。"
    }

    $lock = Enter-ProcessPriorityBackupLock -BackupPath $BackupPath
    $process = $null
    try {
        $process = Get-VerifiedPriorityProcess -ProcessId $ProcessId -StartTimeUtcTicks $StartTimeUtcTicks -ExecutablePath $ExecutablePath -ProtectedProcessId $ProtectedProcessId
        $state = Get-ProcessPriorityBackupState -BackupPath $BackupPath
        $identityKey = Get-ProcessPriorityIdentityKey -ProcessId $ProcessId -StartTimeUtcTicks $StartTimeUtcTicks -ExecutablePath $ExecutablePath
        $existing = @($state.Backups | Where-Object {
            (Get-ProcessPriorityIdentityKey -ProcessId ([int]$_.ProcessId) -StartTimeUtcTicks ([long]$_.StartTimeUtcTicks) -ExecutablePath ([string]$_.ExecutablePath)) -eq $identityKey
        } | Select-Object -First 1)
        if ($existing.Count -eq 0) {
            $backup = [pscustomobject]@{
                ProcessName = [string]$process.ProcessName
                ProcessId = $ProcessId
                StartTimeUtcTicks = $StartTimeUtcTicks
                ExecutablePath = [System.IO.Path]::GetFullPath($ExecutablePath)
                OriginalPriority = [string]$process.PriorityClass
                SavedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
            $state.Backups = @($state.Backups) + $backup
            Save-ProcessPriorityBackupState -State $state -BackupPath $BackupPath
            $originalPriority = [string]$backup.OriginalPriority
        }
        else {
            $originalPriority = [string]$existing[0].OriginalPriority
        }

        $priorityClass = [System.Enum]::Parse([System.Diagnostics.ProcessPriorityClass], $Priority, $false)
        $process.PriorityClass = $priorityClass
        return [pscustomobject]@{
            ProcessName = [string]$process.ProcessName
            ProcessId = $ProcessId
            CurrentPriority = [string]$process.PriorityClass
            OriginalPriority = $originalPriority
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        Exit-ProcessPriorityBackupLock -Mutex $lock
    }
}

function Restore-ManagedProcessPriority {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeUtcTicks,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [int]$ProtectedProcessId = 0,
        [string]$BackupPath = (Get-ProcessPriorityBackupPath)
    )

    $lock = Enter-ProcessPriorityBackupLock -BackupPath $BackupPath
    $process = $null
    try {
        $state = Get-ProcessPriorityBackupState -BackupPath $BackupPath
        $identityKey = Get-ProcessPriorityIdentityKey -ProcessId $ProcessId -StartTimeUtcTicks $StartTimeUtcTicks -ExecutablePath $ExecutablePath
        $match = @($state.Backups | Where-Object {
            (Get-ProcessPriorityIdentityKey -ProcessId ([int]$_.ProcessId) -StartTimeUtcTicks ([long]$_.StartTimeUtcTicks) -ExecutablePath ([string]$_.ExecutablePath)) -eq $identityKey
        } | Select-Object -First 1)
        if ($match.Count -eq 0) {
            throw '该进程没有匹配身份的优先级恢复记录。'
        }

        $process = Get-VerifiedPriorityProcess -ProcessId $ProcessId -StartTimeUtcTicks $StartTimeUtcTicks -ExecutablePath $ExecutablePath -ProtectedProcessId $ProtectedProcessId
        $originalPriority = [System.Enum]::Parse([System.Diagnostics.ProcessPriorityClass], [string]$match[0].OriginalPriority, $false)
        $process.PriorityClass = $originalPriority
        $state.Backups = @($state.Backups | Where-Object {
            (Get-ProcessPriorityIdentityKey -ProcessId ([int]$_.ProcessId) -StartTimeUtcTicks ([long]$_.StartTimeUtcTicks) -ExecutablePath ([string]$_.ExecutablePath)) -ne $identityKey
        })
        try {
            Save-ProcessPriorityBackupState -State $state -BackupPath $BackupPath
        }
        catch {
            $restoreException = New-Object System.InvalidOperationException("优先级已恢复为 $originalPriority，但恢复记录清理失败；释放文件占用后可重试：$($_.Exception.Message)")
            $restoreException.Data['PriorityRestored'] = $true
            throw $restoreException
        }
        return [pscustomobject]@{
            ProcessName = [string]$process.ProcessName
            ProcessId = $ProcessId
            CurrentPriority = [string]$process.PriorityClass
            OriginalPriority = [string]$originalPriority
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        Exit-ProcessPriorityBackupLock -Mutex $lock
    }
}

Export-ModuleMember -Function Get-ProcessPriorityBackupPath, Get-ProcessPrioritySnapshot, Set-ManagedProcessPriority, Restore-ManagedProcessPriority
