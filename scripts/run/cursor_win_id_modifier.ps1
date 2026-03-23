# Set output encoding to UTF-8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Color definitions (compatible with PowerShell 5.1 and 7.x)
$ESC = [char]27
$RED = "$ESC[31m"
$GREEN = "$ESC[32m"
$YELLOW = "$ESC[33m"
 = "$ESC[34m"
$NC = "$ESC[0m"

# Try to resize terminal window to 120x40 (cols x rows) on startup; silently ignore if not supported/failed to avoid affecting main script flow
function Try-ResizeTerminalWindow {
    param(
        [int]$Columns = 120,
        [int]$Rows = 40
    )

    # Method 1: Adjust via PowerShell Host RawUI (traditional console, ConEmu, etc. may support)
    try {
        $rawUi = $null
        if ($Host -and $Host.UI -and $Host.UI.RawUI) {
            $rawUi = $Host.UI.RawUI
        }

        if ($rawUi) {
            try {
                # BufferSize must be >= WindowSize, otherwise exception will be thrown
                $bufferSize = $rawUi.BufferSize
                $newBufferSize = New-Object System.Management.Automation.Host.Size (
                    ([Math]::Max($bufferSize.Width, $Columns)),
                    ([Math]::Max($bufferSize.Height, $Rows))
                )
                $rawUi.BufferSize = $newBufferSize
            } catch {
                # Silently ignore
            }

            try {
                $rawUi.WindowSize = New-Object System.Management.Automation.Host.Size ($Columns, $Rows)
            } catch {
                # Silently ignore
            }
        }
    } catch {
        # Silently ignore
    }

    # Method 2: Try again via ANSI escape sequences (Windows Terminal, etc. may support)
    try {
        if (-not [Console]::IsOutputRedirected) {
            $escChar = [char]27
            [Console]::Out.Write("$escChar[8;${Rows};${Columns}t")
        }
    } catch {
        # Silently ignore
    }
}

Try-ResizeTerminalWindow -Columns 120 -Rows 40

# Path resolution: Prefer using .NET to get system directories, avoid path anomalies from missing environment variables
function Get-FolderPathSafe {
    param(
        [Parameter(Mandatory = $true)][System.Environment+SpecialFolder]$SpecialFolder,
        [Parameter(Mandatory = $true)][string]$EnvVarName,
        [Parameter(Mandatory = $true)][string]$FallbackRelative,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $path = [Environment]::GetFolderPath($SpecialFolder)
    if ([string]::IsNullOrWhiteSpace($path)) {
        $envValue = [Environment]::GetEnvironmentVariable($EnvVarName)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            $path = $envValue
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $userProfile = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            $userProfile = [Environment]::GetEnvironmentVariable("USERPROFILE")
        }
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
            $path = Join-Path $userProfile $FallbackRelative
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host "$YELLOW⚠️  [Path]$NC $Label cannot be resolved, will try other methods"
    } else {
        Write-Host "ℹ️  [Path]$NC ${Label}: $path"
    }
    return $path
}

function Initialize-CursorPaths {
    Write-Host "ℹ️  [Path]$NC Starting to resolve Cursor-related paths..."
    $global:CursorAppDataRoot = Get-FolderPathSafe `
        -SpecialFolder ([System.Environment+SpecialFolder]::ApplicationData) `
        -EnvVarName "APPDATA" `
        -FallbackRelative "AppData\Roaming" `
        -Label "Roaming AppData"
    $global:CursorLocalAppDataRoot = Get-FolderPathSafe `
        -SpecialFolder ([System.Environment+SpecialFolder]::LocalApplicationData) `
        -EnvVarName "LOCALAPPDATA" `
        -FallbackRelative "AppData\Local" `
        -Label "Local AppData"
    $global:CursorUserProfileRoot = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($global:CursorUserProfileRoot)) {
        $global:CursorUserProfileRoot = [Environment]::GetEnvironmentVariable("USERPROFILE")
    }
    if (-not [string]::IsNullOrWhiteSpace($global:CursorUserProfileRoot)) {
        Write-Host "ℹ️  [Path]$NC User directory: $global:CursorUserProfileRoot"
    }
    $global:CursorAppDataDir = if ($global:CursorAppDataRoot) { Join-Path $global:CursorAppDataRoot "Cursor" } else { $null }
    $global:CursorLocalAppDataDir = if ($global:CursorLocalAppDataRoot) { Join-Path $global:CursorLocalAppDataRoot "Cursor" } else { $null }
    $global:CursorStorageDir = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir "User\globalStorage" } else { $null }
    $global:CursorStorageFile = if ($global:CursorStorageDir) { Join-Path $global:CursorStorageDir "storage.json" } else { $null }
    $global:CursorBackupDir = if ($global:CursorStorageDir) { Join-Path $global:CursorStorageDir "backups" } else { $null }

    if ($global:CursorStorageDir -and -not (Test-Path $global:CursorStorageDir)) {
        Write-Host "$YELLOW⚠️  [Path]$NC Global config directory does not exist: $global:CursorStorageDir"
    }
    if ($global:CursorStorageFile) {
        if (Test-Path $global:CursorStorageFile) {
            Write-Host "$GREEN✅ [Path]$NC Configuration file found: $global:CursorStorageFile"
        } else {
            Write-Host "$YELLOW⚠️  [Path]$NC Configuration file does not exist: $global:CursorStorageFile"
        }
    }
}

function Normalize-CursorInstallCandidate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $candidate = $Path.Trim().Trim('"')
    if (Test-Path $candidate -PathType Leaf) {
        $candidate = Split-Path -Parent $candidate
    }
    return $candidate
}

function Test-CursorInstallPath {
    param([string]$Path)
    $candidate = Normalize-CursorInstallCandidate -Path $Path
    if (-not $candidate) {
        return $false
    }
    $exePath = Join-Path $candidate "Cursor.exe"
    return (Test-Path $exePath)
}

function Get-CursorInstallPathFromRegistry {
    $results = @()
    $uninstallKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($key in $uninstallKeys) {
        try {
            $items = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                if (-not $item.DisplayName -or $item.DisplayName -notlike "*Cursor*") {
                    continue
                }
                $candidate = $null
                if ($item.InstallLocation) {
                    $candidate = $item.InstallLocation
                } elseif ($item.DisplayIcon) {
                    $candidate = $item.DisplayIcon.Split(',')[0].Trim('"')
                } elseif ($item.UninstallString) {
                    $candidate = $item.UninstallString.Split(' ')[0].Trim('"')
                }
                if ($candidate) {
                    $results += $candidate
                }
            }
        } catch {
            Write-Host "$YELLOW⚠️  [Path]$NC Failed to read registry: $key"
        }
    }
    return $results | Where-Object { $_ } | Select-Object -Unique
}

function Request-CursorInstallPathFromUser {
    Write-Host "$YELLOW💡 [Tip]$NC Auto-detection failed, you can manually select Cursor installation directory (containing Cursor.exe)"
    $selectedPath = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Please select Cursor installation directory (containing Cursor.exe)"
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selectedPath = $dialog.SelectedPath
        }
    } catch {
        Write-Host "$YELLOW⚠️  [Tip]$NC Cannot open selection dialog, will use command line input"
    }
    if (-not $selectedPath) {
        $manualInput = Read-Host "Please enter Cursor installation directory (containing Cursor.exe), or press Enter to cancel"
        if (-not [string]::IsNullOrWhiteSpace($manualInput)) {
            $selectedPath = $manualInput
        }
    }
    if ($selectedPath) {
        $normalized = Normalize-CursorInstallCandidate -Path $selectedPath
        if ($normalized -and (Test-CursorInstallPath -Path $normalized)) {
            Write-Host "$GREEN✅ [Found]$NC Manually specified installation path: $normalized"
            return $normalized
        }
        Write-Host "$RED❌ [Error]$NC Manual path invalid: $selectedPath"
    }
    return $null
}

function Resolve-CursorInstallPath {
    param([switch]$AllowPrompt)
    if ($global:CursorInstallPath -and (Test-CursorInstallPath -Path $global:CursorInstallPath)) {
        return $global:CursorInstallPath
    }

    Write-Host "🔎 [Path]$NC Detecting Cursor installation directory..."
    $candidates = @()
    if ($global:CursorLocalAppDataRoot) {
        $candidates += (Join-Path $global:CursorLocalAppDataRoot "Programs\Cursor")
    }
    $programFiles = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFiles)
    if ($programFiles) {
        $candidates += (Join-Path $programFiles "Cursor")
    }
    $programFilesX86 = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFilesX86)
    if ($programFilesX86) {
        $candidates += (Join-Path $programFilesX86 "Cursor")
    }

    $regCandidates = @(Get-CursorInstallPathFromRegistry)
    if ($regCandidates.Count -gt 0) {
        Write-Host "ℹ️  [Path]$NC Found candidate paths from registry: $($regCandidates -join '; ')"
        $candidates += $regCandidates
    }

    $fixedDrives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' }
    foreach ($drive in $fixedDrives) {
        $root = $drive.RootDirectory.FullName
        $candidates += (Join-Path $root "Program Files\Cursor")
        $candidates += (Join-Path $root "Program Files (x86)\Cursor")
        $candidates += (Join-Path $root "Cursor")
    }

    $candidates = $candidates | Where-Object { $_ } | Select-Object -Unique
    $totalCandidates = $candidates.Count
    for ($i = 0; $i -lt $totalCandidates; $i++) {
        $candidate = Normalize-CursorInstallCandidate -Path $candidates[$i]
        $attempt = $i + 1
        if (-not $candidate) {
            continue
        }
        Write-Host "⏳ [Path]$NC ($attempt/$totalCandidates) Trying installation path: $candidate"
        if (Test-CursorInstallPath -Path $candidate) {
            $global:CursorInstallPath = $candidate
            Write-Host "$GREEN✅ [Found]$NC Found Cursor installation path: $candidate"
            return $candidate
        }
    }

    if ($AllowPrompt) {
        $manualPath = Request-CursorInstallPathFromUser
        if ($manualPath) {
            $global:CursorInstallPath = $manualPath
            return $manualPath
        }
    }

    Write-Host "$RED❌ [Error]$NC Cursor application installation path not found"
    Write-Host "$YELLOW💡 [Tip]$NC Please ensure Cursor is properly installed or manually specify the path"
    return $null
}

# Configuration file paths (use global variables after initialization)
Initialize-CursorPaths
$STORAGE_FILE = $global:CursorStorageFile
$BACKUP_DIR = $global:CursorBackupDir

# PowerShell native method to generate random string
function Generate-RandomString {
    param([int]$Length)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $result = ""
    for ($i = 0; $i -lt $Length; $i++) {
        $result += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $result
}

# 🔍 Simple JavaScript brace matching (used to locate function boundaries within limited fragments, avoiding regex cross-segment misreplacement)
# Note: This is a lightweight parser, sufficient for handling minified function bodies in main.js (including try/catch, strings, comments).
function Find-JsMatchingBraceEnd {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$OpenBraceIndex,
        [int]$MaxScan = 20000
    )

    if ($OpenBraceIndex -lt 0 -or $OpenBraceIndex -ge $Text.Length) {
        return -1
    }

    $limit = [Math]::Min($Text.Length, $OpenBraceIndex + $MaxScan)

    $depth = 1
    $inSingle = $false
    $inDouble = $false
    $inTemplate = $false
    $inLineComment = $false
    $inBlockComment = $false
    $escape = $false

    for ($i = $OpenBraceIndex + 1; $i -lt $limit; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $limit) { $Text[$i + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($ch -eq "`n") { $inLineComment = $false }
            continue
        }
        if ($inBlockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $inBlockComment = $false; $i++; continue }
            continue
        }

        if ($inSingle) {
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\') { $escape = $true; continue }
            if ($ch -eq "'") { $inSingle = $false }
            continue
        }
        if ($inDouble) {
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\') { $escape = $true; continue }
            if ($ch -eq '"') { $inDouble = $false }
            continue
        }
        if ($inTemplate) {
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\') { $escape = $true; continue }
            if ($ch -eq '`') { $inTemplate = $false }
            continue
        }

        # Comment detection (only in non-string state)
        if ($ch -eq '/' -and $next -eq '/') { $inLineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $inBlockComment = $true; $i++; continue }

        # String/template string
        if ($ch -eq "'") { $inSingle = $true; continue }
        if ($ch -eq '"') { $inDouble = $true; continue }
        if ($ch -eq '`') { $inTemplate = $true; continue }

        # Brace depth
        if ($ch -eq '{') { $depth++; continue }
        if ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }

    return -1
}

# 🔧 Modify Cursor core JS files to bypass device identification (enhanced triple solution)
# Plan A: someValue placeholder replacement - stable anchor, does not depend on obfuscated function names
# Plan B: b6 fixed-point rewrite - machine code source function directly returns fixed value
# Plan C: Loader Stub + external Hook - main/shared process only loads external Hook file
function Modify-CursorJSFiles {
    Write-Host ""
    Write-Host "🔧 [Core Modification]$NC Starting to modify Cursor core JS files to bypass device identification..."
    Write-Host "💡 [Solution]$NC Using enhanced triple solution: placeholder replacement + b6 fixed-point rewrite + Loader Stub + external Hook"
    Write-Host ""

    # Windows Cursor application path (supports auto-detection + manual fallback)
    $cursorAppPath = Resolve-CursorInstallPath -AllowPrompt
    if (-not $cursorAppPath) {
        return $false
    }

    # Generate or reuse device identifiers (prefer values generated in config)
    $useConfigIds = $false
    if ($global:CursorIds -and $global:CursorIds.machineId -and $global:CursorIds.macMachineId -and $global:CursorIds.devDeviceId -and $global:CursorIds.sqmId) {
        $machineId = [string]$global:CursorIds.machineId
        $macMachineId = [string]$global:CursorIds.macMachineId
        $deviceId = [string]$global:CursorIds.devDeviceId
        $sqmId = [string]$global:CursorIds.sqmId
        # Machine GUID used to simulate registry/raw machine code reading
        $machineGuid = if ($global:CursorIds.machineGuid) { [string]$global:CursorIds.machineGuid } else { [System.Guid]::NewGuid().ToString().ToLower() }
        $sessionId = if ($global:CursorIds.sessionId) { [string]$global:CursorIds.sessionId } else { [System.Guid]::NewGuid().ToString().ToLower() }
        # Use UTC time to generate/normalize firstSessionDate, avoiding semantic errors where local time has Z; also compatible with ConvertFrom-Json potentially returning DateTime
        $firstSessionDateValue = if ($global:CursorIds.firstSessionDate) {
            $rawFirstSessionDate = $global:CursorIds.firstSessionDate
            if ($rawFirstSessionDate -is [DateTime]) {
                $rawFirstSessionDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            } elseif ($rawFirstSessionDate -is [DateTimeOffset]) {
                $rawFirstSessionDate.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            } else {
                [string]$rawFirstSessionDate
            }
        } else {
            (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        }
        $macAddress = if ($global:CursorIds.macAddress) { [string]$global:CursorIds.macAddress } else { "00:11:22:33:44:55" }
        $useConfigIds = $true
    } else {
        $randomBytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $rng.GetBytes($randomBytes)
        $machineId = [System.BitConverter]::ToString($randomBytes) -replace '-',''
        $rng.Dispose()
        $deviceId = [System.Guid]::NewGuid().ToString().ToLower()
        $randomBytes2 = New-Object byte[] 32
        $rng2 = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $rng2.GetBytes($randomBytes2)
        $macMachineId = [System.BitConverter]::ToString($randomBytes2) -replace '-',''
        $rng2.Dispose()
        $sqmId = "{" + [System.Guid]::NewGuid().ToString().ToUpper() + "}"
        # Machine GUID used to simulate registry/raw machine code reading
        $machineGuid = [System.Guid]::NewGuid().ToString().ToLower()
        $sessionId = [System.Guid]::NewGuid().ToString().ToLower()
        # Use UTC time to generate firstSessionDate, avoiding semantic errors where local time has Z
        $firstSessionDateValue = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $macAddress = "00:11:22:33:44:55"
    }

    if ($useConfigIds) {
        Write-Host "$GREEN🔑 [Prepare]$NC Using device identifiers from config"
    } else {
        Write-Host "$GREEN🔑 [Generate]$NC Generated new device identifiers"
    }
    Write-Host "   machineId: $($machineId.Substring(0,16))..."
    Write-Host "   machineGuid: $($machineGuid.Substring(0,16))..."
    Write-Host "   deviceId: $($deviceId.Substring(0,16))..."
    Write-Host "   macMachineId: $($macMachineId.Substring(0,16))..."
    Write-Host "   sqmId: $sqmId"

    # Save ID config to user directory (for Hook to read)
    # Delete old config and regenerate on each execution to ensure new device identifiers are obtained
    $idsConfigPath = "$env:USERPROFILE\.cursor_ids.json"
    if (Test-Path $idsConfigPath) {
        Remove-Item -Path $idsConfigPath -Force
        Write-Host "$YELLOW🗑️  [Cleanup]$NC Deleted old ID config file"
    }
    $idsConfig = @{
        machineId = $machineId
        machineGuid = $machineGuid
        macMachineId = $macMachineId
        devDeviceId = $deviceId
        sqmId = $sqmId
        macAddress = $macAddress
        sessionId = $sessionId
        firstSessionDate = $firstSessionDateValue
        createdAt = $firstSessionDateValue
    }
    $idsConfig | ConvertTo-Json | Set-Content -Path $idsConfigPath -Encoding UTF8
    Write-Host "$GREEN💾 [Save]$NC New ID config saved to: $idsConfigPath"

    # Deploy external Hook file (for Loader Stub to load, supports multiple domain fallback downloads)
    $hookTargetPath = "$env:USERPROFILE\.cursor_hook.js"
    # Compatibility: When executing via `irm ... | iex`, $PSScriptRoot may be empty, causing Join-Path to fail directly
    $hookSourceCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $hookSourceCandidates += (Join-Path $PSScriptRoot "..\hook\cursor_hook.js")
    } elseif ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        if (-not [string]::IsNullOrWhiteSpace($scriptDir)) {
            $hookSourceCandidates += (Join-Path $scriptDir "..\hook\cursor_hook.js")
        }
    }
    $cwdPath = $null
    try { $cwdPath = (Get-Location).Path } catch { $cwdPath = $null }
    if (-not [string]::IsNullOrWhiteSpace($cwdPath)) {
        $hookSourceCandidates += (Join-Path $cwdPath "scripts\hook\cursor_hook.js")
    }
    $hookSourcePath = $hookSourceCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $hookDownloadUrls = @(
        "https://wget.la/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://down.npee.cn/?https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://xget.xi-xu.me/gh/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://gh-proxy.com/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js",
        "https://gh.chjina.com/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js"
    )
    # Support overriding download nodes via environment variable (comma-separated)
    if ($env:CURSOR_HOOK_DOWNLOAD_URLS) {
        $hookDownloadUrls = $env:CURSOR_HOOK_DOWNLOAD_URLS -split '\s*,\s*' | Where-Object { $_ }
        Write-Host "ℹ️  [Hook]$NC Detected custom download node list, will prioritize"
    }
    if ($hookSourcePath) {
        try {
            Copy-Item -Path $hookSourcePath -Destination $hookTargetPath -Force
            Write-Host "$GREEN✅ [Hook]$NC External Hook deployed: $hookTargetPath"
        } catch {
            Write-Host "$YELLOW⚠️  [Hook]$NC Local Hook copy failed, trying online download..."
        }
    }
    if (-not (Test-Path $hookTargetPath)) {
        Write-Host "ℹ️  [Hook]$NC Downloading external Hook for device identifier interception..."
        $originalProgressPreference = $ProgressPreference
        $ProgressPreference = 'Continue'
        try {
            if ($hookDownloadUrls.Count -eq 0) {
                Write-Host "$YELLOW⚠️  [Hook]$NC Download node list is empty, skipping online download"
            } else {
                $totalUrls = $hookDownloadUrls.Count
                for ($i = 0; $i -lt $totalUrls; $i++) {
                    $url = $hookDownloadUrls[$i]
                    $attempt = $i + 1
                    Write-Host "⏳ [Hook]$NC ($attempt/$totalUrls) Current download node: $url"
                    try {
                        Invoke-WebRequest -Uri $url -OutFile $hookTargetPath -UseBasicParsing -ErrorAction Stop
                        Write-Host "$GREEN✅ [Hook]$NC External Hook downloaded online: $hookTargetPath"
                        break
                    } catch {
                        Write-Host "$YELLOW⚠️  [Hook]$NC External Hook download failed: $url"
                        if (Test-Path $hookTargetPath) {
                            Remove-Item -Path $hookTargetPath -Force
                        }
                    }
                }
            }
        } finally {
            $ProgressPreference = $originalProgressPreference
        }
        if (-not (Test-Path $hookTargetPath)) {
            Write-Host "$YELLOW⚠️  [Hook]$NC External Hook all downloads failed"
        }
    }

    # Target JS file list (Windows paths, sorted by priority)
    $jsFiles = @(
        "$cursorAppPath\resources\app\out\main.js",
        # Shared process is used to aggregate telemetry, needs synchronous injection
        "$cursorAppPath\resources\app\out\vs\code\electron-utility\sharedProcess\sharedProcessMain.js"
    )

    $modifiedCount = 0

    # Close Cursor process
    Write-Host "🔄 [Close]$NC Closing Cursor process for file modification..."
    Stop-AllCursorProcesses -MaxRetries 3 -WaitSeconds 3 | Out-Null

    # Create backup directory
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = "$cursorAppPath\resources\app\out\backups"

    Write-Host "💾 [Backup]$NC Creating Cursor JS file backup..."
    try {
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

        # Check if original backup exists
        $originalBackup = "$backupPath\main.js.original"

        foreach ($file in $jsFiles) {
            if (-not (Test-Path $file)) {
                Write-Host "$YELLOW⚠️  [Warning]$NC File does not exist: $(Split-Path $file -Leaf)"
                continue
            }

            $fileName = Split-Path $file -Leaf
            $fileOriginalBackup = "$backupPath\$fileName.original"

            # If original backup does not exist, create it first
            if (-not (Test-Path $fileOriginalBackup)) {
                # Check if current file has already been modified
                $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
                if ($content -and $content -match "__cursor_patched__") {
                    Write-Host "$YELLOW⚠️  [Warning]$NC File has been modified but no original backup exists, will use current version as base"
                }
                Copy-Item $file $fileOriginalBackup -Force
                Write-Host "$GREEN✅ [Backup]$NC Original backup created successfully: $fileName"
            } else {
                # Restore from original backup to ensure clean injection each time
                Write-Host "🔄 [Restore]$NC Restoring from original backup: $fileName"
                Copy-Item $fileOriginalBackup $file -Force
            }
        }

        # Create timestamp backup (record state before each modification)
        foreach ($file in $jsFiles) {
            if (Test-Path $file) {
                $fileName = Split-Path $file -Leaf
                Copy-Item $file "$backupPath\$fileName.backup_$timestamp" -Force
            }
        }
        Write-Host "$GREEN✅ [Backup]$NC Timestamp backup created successfully: $backupPath"
    } catch {
        Write-Host "$RED❌ [Error]$NC Failed to create backup: $($_.Exception.Message)"
        return $false
    }

    # Modify JS files (re-inject each time since restored from original backup)
    Write-Host "🔧 [Modify]$NC Starting to modify JS files (using device identifiers)..."

    foreach ($file in $jsFiles) {
        if (-not (Test-Path $file)) {
            Write-Host "$YELLOW⚠️  [Skip]$NC File does not exist: $(Split-Path $file -Leaf)"
            continue
        }

        Write-Host "📝 [Process]$NC Processing: $(Split-Path $file -Leaf)"

        try {
            $content = Get-Content $file -Raw -Encoding UTF8
            $replaced = $false
            $replacedB6 = $false

            # ========== Method A: someValue placeholder replacement (stable anchor) ==========
            # These strings are fixed placeholders that won't be modified by the obfuscator, stable across versions
            # Important notes:
            # In current Cursor's main.js, placeholders usually appear as string literals, e.g.:
            #   this.machineId="someValue.machineId"
            # If we directly replace someValue.machineId with "\"<real_value>\"", it will form ""<real_value>"" causing JS syntax error (Invalid token).
            # Therefore, here we prioritize replacing complete string literals (including outer quotes) and use JSON string literals to ensure escape safety.

            # 🔧 Added: firstSessionDate (reset first session date)
            if (-not $firstSessionDateValue) {
                # Use UTC time to generate firstSessionDate, avoiding semantic errors where local time has Z
                $firstSessionDateValue = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            }

            $placeholders = @(
                @{ Name = 'someValue.machineId';         Value = [string]$machineId },
                @{ Name = 'someValue.macMachineId';      Value = [string]$macMachineId },
                @{ Name = 'someValue.devDeviceId';       Value = [string]$deviceId },
                @{ Name = 'someValue.sqmId';             Value = [string]$sqmId },
                @{ Name = 'someValue.sessionId';         Value = [string]$sessionId },
                @{ Name = 'someValue.firstSessionDate';  Value = [string]$firstSessionDateValue }
            )

            foreach ($ph in $placeholders) {
                $name = $ph.Name
                $jsonValue = ($ph.Value | ConvertTo-Json -Compress)  # Generate JSON string literal with double quotes

                $changed = $false

                # Prioritize replacing quoted placeholder literals to avoid ""abc"" breaking syntax
                $doubleLiteral = '"' + $name + '"'
                if ($content.Contains($doubleLiteral)) {
                    $content = $content.Replace($doubleLiteral, $jsonValue)
                    $changed = $true
                }
                $singleLiteral = "'" + $name + "'"
                if ($content.Contains($singleLiteral)) {
                    $content = $content.Replace($singleLiteral, $jsonValue)
                    $changed = $true
                }

                # Fallback: if placeholder appears as non-string literal, replace with JSON string literal (includes quotes)
                if (-not $changed -and $content.Contains($name)) {
                    $content = $content.Replace($name, $jsonValue)
                    $changed = $true
                }

                if ($changed) {
                    Write-Host "   $GREEN✓$NC [Plan A] Replace $name"
                    $replaced = $true
                }
            }

            # ========== Method B: b6 fixed-point rewrite (machine code source function, main.js only) ==========
            # Note: b6(t) is the core generation function for machineId, t=true returns original value, t=false returns hash
            if ((Split-Path $file -Leaf) -eq "main.js") {
                # ✅ 1+3 fusion: limit to out-build/vs/base/node/id.js module for feature matching + brace pairing to locate function boundaries
                # Purpose: improve cross-version coverage while avoiding regex cross-module mis-swallowing causing main.js syntax corruption.
                try {
                    $moduleMarker = "out-build/vs/base/node/id.js"
                    $markerIndex = $content.IndexOf($moduleMarker)
                    if ($markerIndex -lt 0) {
                        throw "id.js module marker not found"
                    }

                    $windowLen = [Math]::Min($content.Length - $markerIndex, 200000)
                    $windowText = $content.Substring($markerIndex, $windowLen)

                    $hashRegex = [regex]::new('createHash\(["'']sha256["'']\)')
                    $hashMatches = $hashRegex.Matches($windowText)
                    Write-Host "   ℹ️  $NC [Plan B Diagnostics] id.js offset=$markerIndex | sha256 createHash hits=$($hashMatches.Count)"
                    $patched = $false
                    $diagLines = @()
                    # Compatibility: In PowerShell expandable strings, "$var:" is parsed as scope/drive prefix, use "${var}" to clarify variable boundaries
                    $candidateNo = 0

                    foreach ($hm in $hashMatches) {
                        $candidateNo++
                        $hashPos = $hm.Index
                        $funcStart = $windowText.LastIndexOf("async function", $hashPos)
                        if ($funcStart -lt 0) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate#${candidateNo}: async function start not found" }
                            continue
                        }

                        $openBrace = $windowText.IndexOf("{", $funcStart)
                        if ($openBrace -lt 0) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate#${candidateNo}: Function opening brace not found" }
                            continue
                        }

                        $endBrace = Find-JsMatchingBraceEnd -Text $windowText -OpenBraceIndex $openBrace -MaxScan 20000
                        if ($endBrace -lt 0) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate#${candidateNo}: Brace pairing failed (not closed within scan limit)" }
                            continue
                        }

                        $funcText = $windowText.Substring($funcStart, $endBrace - $funcStart + 1)
                        if ($funcText.Length -gt 8000) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate#${candidateNo}: Function body too long len=$($funcText.Length), skipped" }
                            continue
                        }

                        $sig = [regex]::Match($funcText, '^async function (\w+)\((\w+)\)')
                        if (-not $sig.Success) {
                            if ($candidateNo -le 3) { $diagLines += "Candidate#${candidateNo}: Function signature not parsed (async function name(param))" }
                            continue
                        }
                        $fn = $sig.Groups[1].Value
                        $param = $sig.Groups[2].Value

                        # Feature validation: sha256 + hex digest + return param ? raw : hash
                        $hasDigest = ($funcText -match '\.digest\(["'']hex["'']\)')
                        $hasReturn = ($funcText -match ('return\s+' + [regex]::Escape($param) + '\?\w+:\w+\}'))
                        if ($candidateNo -le 3) {
                            $diagLines += "Candidate#${candidateNo}: $fn($param) len=$($funcText.Length) digest=$hasDigest return=$hasReturn"
                        }
                        if (-not $hasDigest) { continue }
                        if (-not $hasReturn) { continue }

                        $replacement = "async function $fn($param){return $param?'$machineGuid':'$machineId';}"
                        $absStart = $markerIndex + $funcStart
                        $absEnd = $markerIndex + $endBrace
                        $content = $content.Substring(0, $absStart) + $replacement + $content.Substring($absEnd + 1)

                        Write-Host "   ℹ️  $NC [Plan B Diagnostics] Hit candidate#${candidateNo}: $fn($param) len=$($funcText.Length)"
                        Write-Host "   $GREEN✓$NC [Plan B] Rewrote $fn($param) machine code source function (fusion feature matching)"
                        $replacedB6 = $true
                        $patched = $true
                        break
                    }

                    if (-not $patched) {
                        Write-Host "   $YELLOW⚠️  $NC [Plan B] Machine code source function features not located, skipped"
                        foreach ($d in ($diagLines | Select-Object -First 3)) {
                            Write-Host "      ℹ️  $NC [Plan B Diagnostics] $d"
                        }
                    }
                } catch {
                    Write-Host "   $YELLOW⚠️  $NC [Plan B] Location failed, skipped: $($_.Exception.Message)"
                }
            }

            # ========== Method C: Loader Stub Injection ==========
            # Note: Main/shared process only injects loader, specific Hook logic is maintained by external cursor_hook.js

            $injectCode = @"
// ========== Cursor Hook Loader Start ==========
;(async function(){/*__cursor_patched__*/
'use strict';
if (globalThis.__cursor_hook_loaded__) return;
globalThis.__cursor_hook_loaded__ = true;

try {
    // Compatibility ESM/CJS: avoid using import.meta (ESM only), uniformly use dynamic import to load Hook
    var fsMod = await import('fs');
    var pathMod = await import('path');
    var osMod = await import('os');
    var urlMod = await import('url');

    var fs = fsMod && (fsMod.default || fsMod);
    var path = pathMod && (pathMod.default || pathMod);
    var os = osMod && (osMod.default || osMod);
    var url = urlMod && (urlMod.default || urlMod);

    if (fs && path && os && url && typeof url.pathToFileURL === 'function') {
        var hookPath = path.join(os.homedir(), '.cursor_hook.js');
        if (typeof fs.existsSync === 'function' && fs.existsSync(hookPath)) {
            await import(url.pathToFileURL(hookPath).href);
        }
    }
} catch (e) {
    // Fail silently to avoid affecting startup
}
})();
// ========== Cursor Hook Loader End ==========

"@

            # Find copyright notice end position and inject after it (inject only once to avoid multiple insertions breaking syntax)
            if ($content -match "__cursor_patched__") {
                Write-Host "   $YELLOW⚠️  $NC [Plan C] Existing injection marker detected, skipping duplicate injection"
            } elseif ($content -match '(\*/\s*\n)') {
                $replacement = '$1' + $injectCode
                $content = [regex]::Replace($content, '(\*/\s*\n)', $replacement, 1)
                Write-Host "   $GREEN✓$NC [Plan C] Loader Stub injected (after copyright notice, first time only)"
            } else {
                # If copyright notice not found, inject at file beginning
                $content = $injectCode + $content
                Write-Host "   $GREEN✓$NC [Plan C] Loader Stub injected (file beginning)"
            }

            # Injection consistency check: avoid duplicate injection causing syntax corruption
            $patchedCount = ([regex]::Matches($content, "__cursor_patched__")).Count
            if ($patchedCount -gt 1) {
                throw "Duplicate injection marker detected: $patchedCount"
            }

            # Write modified content
            Set-Content -Path $file -Value $content -Encoding UTF8 -NoNewline

            # Summarize the combination of plans actually effective in this injection
            $summaryParts = @()
            if ($replaced) { $summaryParts += "someValue replacement" }
            if ($replacedB6) { $summaryParts += "b6 fixed-point rewrite" }
            $summaryParts += "Hook loader"
            $summaryText = ($summaryParts -join " + ")
            Write-Host "$GREEN✅ [Success]$NC Enhanced plan modification successful ($summaryText)"
            $modifiedCount++

        } catch {
            Write-Host "$RED❌ [Error]$NC Failed to modify file: $($_.Exception.Message)"
            # Try to restore from backup
            $fileName = Split-Path $file -Leaf
            $backupFile = "$backupPath\$fileName.original"
            if (Test-Path $backupFile) {
                Copy-Item $backupFile $file -Force
                Write-Host "$YELLOW🔄 [Restore]$NC File restored from backup"
            }
        }
    }

    if ($modifiedCount -gt 0) {
        Write-Host ""
        Write-Host "$GREEN🎉 [Complete]$NC Successfully modified $modifiedCount JS files"
        Write-Host "💾 [Backup]$NC Original file backup location: $backupPath"
        Write-Host "💡 [Note]$NC Using enhanced triple solution:"
        Write-Host "   • Plan A: someValue placeholder replacement (stable anchor, cross-version compatible)"
        Write-Host "   • Plan B: b6 fixed-point rewrite (machine code source function)"
        Write-Host "   • Plan C: Loader Stub + external Hook (cursor_hook.js)"
        Write-Host "📁 [Config]$NC ID config file: $idsConfigPath"
        return $true
    } else {
        Write-Host "$RED❌ [Failed]$NC No files were successfully modified"
        return $false
    }
}


# 🚀 New Cursor trial reset folder deletion feature
function Remove-CursorTrialFolders {
    Write-Host ""
    Write-Host "$GREEN🎯 [Core Feature]$NC Executing Cursor trial reset folder deletion..."
    Write-Host "📋 [Note]$NC This feature will delete specified Cursor-related folders to reset trial status"
    Write-Host ""

    # Define folder paths to delete
    $foldersToDelete = @()

    # Windows Administrator user paths
    $adminPaths = @(
        "C:\Users\Administrator\.cursor",
        "C:\Users\Administrator\AppData\Roaming\Cursor"
    )

    # Current user paths (using resolved user directory and AppData)
    $currentUserPaths = @()
    $userProfileRoot = if ($global:CursorUserProfileRoot) { $global:CursorUserProfileRoot } else { [Environment]::GetEnvironmentVariable("USERPROFILE") }
    if ($userProfileRoot) {
        $currentUserPaths += (Join-Path $userProfileRoot ".cursor")
    }
    if ($global:CursorAppDataDir) {
        $currentUserPaths += $global:CursorAppDataDir
    }

    # Merge all paths
    $foldersToDelete += $adminPaths
    $foldersToDelete += $currentUserPaths

    Write-Host "📂 [Check]$NC Will check the following folders:"
    foreach ($folder in $foldersToDelete) {
        Write-Host "   📁 $folder"
    }
    Write-Host ""

    $deletedCount = 0
    $skippedCount = 0
    $errorCount = 0

    # Delete specified folders
    foreach ($folder in $foldersToDelete) {
        Write-Host "🔍 [Check]$NC Checking folder: $folder"

        if (Test-Path $folder) {
            try {
                Write-Host "$YELLOW⚠️  [Warning]$NC Folder found, deleting..."
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Write-Host "$GREEN✅ [Success]$NC Deleted folder: $folder"
                $deletedCount++
            }
            catch {
                Write-Host "$RED❌ [Error]$NC Failed to delete folder: $folder"
                Write-Host "$RED💥 [Details]$NC Error message: $($_.Exception.Message)"
                $errorCount++
            }
        } else {
            Write-Host "$YELLOW⏭️  [Skip]$NC Folder does not exist: $folder"
            $skippedCount++
        }
        Write-Host ""
    }

    # Display operation statistics
    Write-Host "$GREEN📊 [Stats]$NC Operation completion statistics:"
    Write-Host "   ✅ Successfully deleted: $deletedCount folders"
    Write-Host "   ⏭️  Skipped: $skippedCount folders"
    Write-Host "   ❌ Failed to delete: $errorCount folders"
    Write-Host ""

    if ($deletedCount -gt 0) {
        Write-Host "$GREEN🎉 [Complete]$NC Cursor trial reset folder deletion complete!"

        # 🔧 Pre-create necessary directory structure to avoid permission issues
        Write-Host "🔧 [Fix]$NC Pre-creating necessary directory structure to avoid permission issues..."

        $cursorAppData = $global:CursorAppDataDir
        $cursorLocalAppData = $global:CursorLocalAppDataDir
        $cursorUserProfile = if ($userProfileRoot) { Join-Path $userProfileRoot ".cursor" } else { "$env:USERPROFILE\.cursor" }

        # Create main directories
        try {
            if ($cursorAppData -and -not (Test-Path $cursorAppData)) {
                New-Item -ItemType Directory -Path $cursorAppData -Force | Out-Null
            }
            if ($cursorUserProfile -and -not (Test-Path $cursorUserProfile)) {
                New-Item -ItemType Directory -Path $cursorUserProfile -Force | Out-Null
            }
            Write-Host "$GREEN✅ [Complete]$NC Directory structure pre-creation complete"
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Issue occurred while pre-creating directories: $($_.Exception.Message)"
        }
    } else {
        Write-Host "$YELLOW🤔 [Tip]$NC No folders found to delete, may have already been cleaned"
    }
    Write-Host ""
}

# 🔄 Restart Cursor and wait for config file generation
function Restart-CursorAndWait {
    Write-Host ""
    Write-Host "$GREEN🔄 [Restart]$NC Restarting Cursor to regenerate config file..."

    if (-not $global:CursorProcessInfo) {
        Write-Host "$RED❌ [Error]$NC Cursor process info not found, cannot restart"
        return $false
    }

    $cursorPath = $global:CursorProcessInfo.Path

    # Fix: Ensure path is string type
    if ($cursorPath -is [array]) {
        $cursorPath = $cursorPath[0]
    }

    # Verify path is not empty
    if ([string]::IsNullOrEmpty($cursorPath)) {
        Write-Host "$RED❌ [Error]$NC Cursor path is empty"
        return $false
    }

    Write-Host "📍 [Path]$NC Using path: $cursorPath"

    if (-not (Test-Path $cursorPath)) {
        Write-Host "$RED❌ [Error]$NC Cursor executable does not exist: $cursorPath"

        # Try to re-resolve installation path
        $installPath = Resolve-CursorInstallPath -AllowPrompt
        $foundPath = if ($installPath) { Join-Path $installPath "Cursor.exe" } else { $null }
        if ($foundPath -and (Test-Path $foundPath)) {
            Write-Host "$GREEN💡 [Found]$NC Using fallback path: $foundPath"
        } else {
            $foundPath = $null
        }

        if (-not $foundPath) {
            Write-Host "$RED❌ [Error]$NC Unable to find valid Cursor executable"
            return $false
        }

        $cursorPath = $foundPath
    }

    try {
        Write-Host "$GREEN🚀 [Start]$NC Starting Cursor..."
        $process = Start-Process -FilePath $cursorPath -PassThru -WindowStyle Hidden

        Write-Host "$YELLOW⏳ [Wait]$NC Waiting 20 seconds for Cursor to fully start and generate config file..."
        Start-Sleep -Seconds 20

        # Check if config file is generated
        $configPath = $STORAGE_FILE
        if (-not $configPath) {
            Write-Host "$RED❌ [Error]$NC Unable to resolve config file path"
            return $false
        }
        $maxWait = 45
        $waited = 0

        while (-not (Test-Path $configPath) -and $waited -lt $maxWait) {
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting for config file generation... ($waited/$maxWait seconds)"
            Start-Sleep -Seconds 1
            $waited++
        }

        if (Test-Path $configPath) {
            Write-Host "$GREEN✅ [Success]$NC Config file generated: $configPath"

            # Additional wait to ensure file is fully written
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting 5 seconds to ensure config file is fully written..."
            Start-Sleep -Seconds 5
        } else {
            Write-Host "$YELLOW⚠️  [Warning]$NC Config file not generated within expected time"
            Write-Host "💡 [Tip]$NC May need to manually start Cursor once to generate config file"
        }

        # Force close Cursor
        Write-Host "$YELLOW🔄 [Close]$NC Closing Cursor for config modification..."
        if ($process -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit(5000)
        }

        # Ensure all Cursor processes are closed
        Get-Process -Name "Cursor" -ErrorAction SilentlyContinue | Stop-Process -Force
        Get-Process -Name "cursor" -ErrorAction SilentlyContinue | Stop-Process -Force

        Write-Host "$GREEN✅ [Complete]$NC Cursor restart process complete"
        return $true

    } catch {
        Write-Host "$RED❌ [Error]$NC Failed to restart Cursor: $($_.Exception.Message)"
        Write-Host "💡 [Debug]$NC Error details: $($_.Exception.GetType().FullName)"
        return $false
    }
}

# 🔒 Force close all Cursor processes (enhanced version)
function Stop-AllCursorProcesses {
    param(
        [int]$MaxRetries = 3,
        [int]$WaitSeconds = 5
    )

    Write-Host "🔒 [Process Check]$NC Checking and closing all Cursor-related processes..."

    # Define all possible Cursor process names
    $cursorProcessNames = @(
        "Cursor",
        "cursor",
        "Cursor Helper",
        "Cursor Helper (GPU)",
        "Cursor Helper (Plugin)",
        "Cursor Helper (Renderer)",
        "CursorUpdater"
    )

    for ($retry = 1; $retry -le $MaxRetries; $retry++) {
        Write-Host "🔍 [Check]$NC Process check $retry/$MaxRetries..."

        $foundProcesses = @()
        foreach ($processName in $cursorProcessNames) {
            $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($processes) {
                $foundProcesses += $processes
                Write-Host "$YELLOW⚠️  [Found]$NC Process: $processName (PID: $($processes.Id -join ', '))"
            }
        }

        if ($foundProcesses.Count -eq 0) {
            Write-Host "$GREEN✅ [Success]$NC All Cursor processes closed"
            return $true
        }

        Write-Host "$YELLOW🔄 [Close]$NC Closing $($foundProcesses.Count) Cursor processes..."

        # First try graceful close
        foreach ($process in $foundProcesses) {
            try {
                $process.CloseMainWindow() | Out-Null
                Write-Host "  • Graceful close: $($process.ProcessName) (PID: $($process.Id))$NC"
            } catch {
                Write-Host "$YELLOW  • Graceful close failed: $($process.ProcessName)$NC"
            }
        }

        Start-Sleep -Seconds 3

        # Force terminate still running processes
        foreach ($processName in $cursorProcessNames) {
            $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($processes) {
                foreach ($process in $processes) {
                    try {
                        Stop-Process -Id $process.Id -Force
                        Write-Host "$RED  • Force terminate: $($process.ProcessName) (PID: $($process.Id))$NC"
                    } catch {
                        Write-Host "$RED  • Force terminate failed: $($process.ProcessName)$NC"
                    }
                }
            }
        }

        if ($retry -lt $MaxRetries) {
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting $WaitSeconds seconds before rechecking..."
            Start-Sleep -Seconds $WaitSeconds
        }
    }

    Write-Host "$RED❌ [Failed]$NC Cursor processes still running after $MaxRetries attempts"
    return $false
}

# 🔐 Check file permissions and lock status
function Test-FileAccessibility {
    param(
        [string]$FilePath
    )

    Write-Host "🔐 [Permission Check]$NC Checking file access permissions: $(Split-Path $FilePath -Leaf)"

    if (-not (Test-Path $FilePath)) {
        Write-Host "$RED❌ [Error]$NC File does not exist"
        return $false
    }

    # Check if file is locked
    try {
        $fileStream = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
        $fileStream.Close()
        Write-Host "$GREEN✅ [Permission]$NC File is readable/writable, no lock"
        return $true
    } catch [System.IO.IOException] {
        Write-Host "$RED❌ [Locked]$NC File locked by another process: $($_.Exception.Message)"
        return $false
    } catch [System.UnauthorizedAccessException] {
        Write-Host "$YELLOW⚠️  [Permission]$NC File permissions restricted, attempting to modify..."

        # Try to modify file permissions
        try {
            $file = Get-Item $FilePath
            if ($file.IsReadOnly) {
                $file.IsReadOnly = $false
                Write-Host "$GREEN✅ [Fix]$NC Read-only attribute removed"
            }

            # Test again
            $fileStream = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
            $fileStream.Close()
            Write-Host "$GREEN✅ [Permission]$NC Permission fix successful"
            return $true
        } catch {
            Write-Host "$RED❌ [Permission]$NC Unable to fix permissions: $($_.Exception.Message)"
            return $false
        }
    } catch {
        Write-Host "$RED❌ [Error]$NC Unknown error: $($_.Exception.Message)"
        return $false
    }
}

# 🧹 Cursor initialization cleanup function (ported from old version)
function Invoke-CursorInitialization {
    Write-Host ""
    Write-Host "$GREEN🧹 [Initialize]$NC Executing Cursor initialization cleanup..."
    $BASE_PATH = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir "User" } else { $null }
    if (-not $BASE_PATH) {
        Write-Host "$RED❌ [Error]$NC Unable to resolve Cursor user directory, initialization cleanup terminated"
        return
    }

    $filesToDelete = @(
        (Join-Path -Path $BASE_PATH -ChildPath "globalStorage\state.vscdb"),
        (Join-Path -Path $BASE_PATH -ChildPath "globalStorage\state.vscdb.backup")
    )

    $folderToCleanContents = Join-Path -Path $BASE_PATH -ChildPath "History"
    $folderToDeleteCompletely = Join-Path -Path $BASE_PATH -ChildPath "workspaceStorage"

    Write-Host "🔍 [Debug]$NC Base path: $BASE_PATH"

    # Delete specified files
    foreach ($file in $filesToDelete) {
        Write-Host "🔍 [Check]$NC Checking file: $file"
        if (Test-Path $file) {
            try {
                Remove-Item -Path $file -Force -ErrorAction Stop
                Write-Host "$GREEN✅ [Success]$NC Deleted file: $file"
            }
            catch {
                $errMsg = $_.Exception.Message
                Write-Host "$RED❌ [Error]$NC Failed to delete file $file`: $errMsg"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Skip]$NC File does not exist, skipping deletion: $file"
        }
    }

    # Clear specified folder contents
    Write-Host "🔍 [Check]$NC Checking folder to clear: $folderToCleanContents"
    if (Test-Path $folderToCleanContents) {
        try {
            Get-ChildItem -Path $folderToCleanContents -Recurse | Remove-Item -Force -Recurse -ErrorAction Stop
            Write-Host "$GREEN✅ [Success]$NC Cleared folder contents: $folderToCleanContents"
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "$RED❌ [Error]$NC Failed to clear folder $folderToCleanContents`: $errMsg"
        }
    } else {
        Write-Host "$YELLOW⚠️  [Skip]$NC Folder does not exist, skipping clear: $folderToCleanContents"
    }

    # Completely delete specified folder
    Write-Host "🔍 [Check]$NC Checking folder to delete: $folderToDeleteCompletely"
    if (Test-Path $folderToDeleteCompletely) {
        try {
            Remove-Item -Path $folderToDeleteCompletely -Recurse -Force -ErrorAction Stop
            Write-Host "$GREEN✅ [Success]$NC Deleted folder: $folderToDeleteCompletely"
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "$RED❌ [Error]$NC Failed to delete folder $folderToDeleteCompletely`: $errMsg"
        }
    } else {
        Write-Host "$YELLOW⚠️  [Skip]$NC Folder does not exist, skipping deletion: $folderToDeleteCompletely"
    }

    Write-Host "$GREEN✅ [Complete]$NC Cursor initialization cleanup complete"
    Write-Host ""
}

# 🔧 Modify system registry MachineGuid (ported from old version)
function Update-MachineGuid {
    try {
        Write-Host "🔧 [Registry]$NC Modifying system registry MachineGuid..."

        # Check if registry path exists, create if not
        $registryPath = "HKLM:\SOFTWARE\Microsoft\Cryptography"
        if (-not (Test-Path $registryPath)) {
            Write-Host "$YELLOW⚠️  [Warning]$NC Registry path does not exist: $registryPath, creating..."
            New-Item -Path $registryPath -Force | Out-Null
            Write-Host "$GREEN✅ [Info]$NC Registry path created successfully"
        }

        # Get current MachineGuid, use empty string as default if not exists
        $originalGuid = ""
        try {
            $currentGuid = Get-ItemProperty -Path $registryPath -Name MachineGuid -ErrorAction SilentlyContinue
            if ($currentGuid) {
                $originalGuid = $currentGuid.MachineGuid
                Write-Host "$GREEN✅ [Info]$NC Current registry value:"
                Write-Host "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography"
                Write-Host "    MachineGuid    REG_SZ    $originalGuid"
            } else {
                Write-Host "$YELLOW⚠️  [Warning]$NC MachineGuid value does not exist, will create new value"
            }
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Failed to read registry: $($_.Exception.Message)"
            Write-Host "$YELLOW⚠️  [Warning]$NC Will attempt to create new MachineGuid value"
        }

        # Create backup file (only when original value exists)
        $backupFile = $null
        if ($originalGuid) {
            $backupFile = "$BACKUP_DIR\MachineGuid_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
            Write-Host "💾 [Backup]$NC Backing up registry..."
            $backupResult = Start-Process "reg.exe" -ArgumentList "export", "`"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography`"", "`"$backupFile`"" -NoNewWindow -Wait -PassThru

            if ($backupResult.ExitCode -eq 0) {
                Write-Host "$GREEN✅ [Backup]$NC Registry item backed up to: $backupFile"
            } else {
                Write-Host "$YELLOW⚠️  [Warning]$NC Backup creation failed, continuing..."
                $backupFile = $null
            }
        }

        # Generate new GUID
        $newGuid = [System.Guid]::NewGuid().ToString()
        Write-Host "🔄 [Generate]$NC New MachineGuid: $newGuid"

        # Update or create registry value
        Set-ItemProperty -Path $registryPath -Name MachineGuid -Value $newGuid -Force -ErrorAction Stop

        # Verify update
        $verifyGuid = (Get-ItemProperty -Path $registryPath -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($verifyGuid -ne $newGuid) {
            throw "Registry verification failed: Updated value ($verifyGuid) does not match expected value ($newGuid)"
        }

        Write-Host "$GREEN✅ [Success]$NC Registry update successful:"
        Write-Host "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography"
        Write-Host "    MachineGuid    REG_SZ    $newGuid"
        return $true
    }
    catch {
        Write-Host "$RED❌ [Error]$NC Registry operation failed: $($_.Exception.Message)"

        # Try to restore backup (if exists)
        if ($backupFile -and (Test-Path $backupFile)) {
            Write-Host "$YELLOW🔄 [Restore]$NC Restoring from backup..."
            $restoreResult = Start-Process "reg.exe" -ArgumentList "import", "`"$backupFile`"" -NoNewWindow -Wait -PassThru

            if ($restoreResult.ExitCode -eq 0) {
                Write-Host "$GREEN✅ [Restore Success]$NC Original registry value restored"
            } else {
                Write-Host "$RED❌ [Error]$NC Restore failed, please manually import backup file: $backupFile"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Warning]$NC Backup file not found or backup creation failed, cannot auto-restore"
        }

        return $false
    }
}

# 🚫 Disable Cursor auto update (Windows)
function Disable-CursorAutoUpdate {
    Write-Host ""
    Write-Host "🚫 [Disable Update]$NC Attempting to disable Cursor auto update..."

    # Detect Cursor installation path (supports auto-detection + manual fallback)
    $cursorAppPath = Resolve-CursorInstallPath -AllowPrompt
    if (-not $cursorAppPath) {
        Write-Host "$YELLOW⚠️  [Warning]$NC Cursor installation path not found, skipping update disable"
        return $false
    }

    # Update config files (JSON/YAML)
    # Compatibility fix: PowerShell doesn't support using (if ...) as expression in arrays, will report "if is not a cmdlet"
    $updateFiles = @()
    $updateFiles += "$cursorAppPath\resources\app-update.yml"
    $updateFiles += "$cursorAppPath\resources\app\update-config.json"
    if ($global:CursorAppDataDir) {
        $updateFiles += (Join-Path $global:CursorAppDataDir "update-config.json")
        $updateFiles += (Join-Path $global:CursorAppDataDir "settings.json")
    }
    $updateFiles = $updateFiles | Where-Object { $_ }

    foreach ($file in $updateFiles) {
        if (-not (Test-Path $file)) { continue }

        try {
            Copy-Item $file "$file.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')" -Force
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Backup failed: $file"
        }

        if ($file -like "*.yml") {
            Set-Content -Path $file -Value "# update disabled by script $(Get-Date)" -Encoding UTF8
            Write-Host "$GREEN✅ [Complete]$NC Processed update config: $file"
            continue
        }

        if ($file -like "*update-config.json") {
            $config = @{ autoCheck = $false; autoDownload = $false }
            $config | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding UTF8
            Write-Host "$GREEN✅ [Complete]$NC Processed update config: $file"
            continue
        }

        if ($file -like "*settings.json") {
            try {
                $settings = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $settings = @{}
            }
            if ($settings -is [hashtable]) {
                $settings["update.mode"] = "none"
            } else {
                $settings | Add-Member -MemberType NoteProperty -Name "update.mode" -Value "none" -Force
            }
            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
            Write-Host "$GREEN✅ [Complete]$NC Processed update config: $file"
            continue
        }
    }

    # Try to disable updater executable
    $updaterCandidates = @()
    $updaterCandidates += "$cursorAppPath\Update.exe"
    if ($global:CursorLocalAppDataDir) {
        $updaterCandidates += (Join-Path $global:CursorLocalAppDataDir "Update.exe")
    }
    $updaterCandidates += "$cursorAppPath\CursorUpdater.exe"
    $updaterCandidates = $updaterCandidates | Where-Object { $_ }

    foreach ($updater in $updaterCandidates) {
        if (-not (Test-Path $updater)) { continue }
        $backup = "$updater.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        try {
            Move-Item -Path $updater -Destination $backup -Force
            Write-Host "$GREEN✅ [Complete]$NC Disabled updater: $updater"
        } catch {
            Write-Host "$YELLOW⚠️  [Warning]$NC Updater disable failed: $updater"
        }
    }

    return $true
}

# Check config files and environment
function Test-CursorEnvironment {
    param(
        [string]$Mode = "FULL"
    )

    Write-Host ""
    Write-Host "🔍 [Environment Check]$NC Checking Cursor environment..."

    $configPath = $STORAGE_FILE
    $cursorAppData = $global:CursorAppDataDir
    $issues = @()

    # Check config file
    if (-not $configPath) {
        $issues += "Unable to resolve config file path"
    } elseif (-not (Test-Path $configPath)) {
        $issues += "Config file does not exist: $configPath"
    } else {
        try {
            $content = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
            $config = $content | ConvertFrom-Json -ErrorAction Stop
            Write-Host "$GREEN✅ [Check]$NC Config file format correct"
        } catch {
            $issues += "Config file format error: $($_.Exception.Message)"
        }
    }

    # Check Cursor directory structure
    if (-not $cursorAppData -or -not (Test-Path $cursorAppData)) {
        $issues += "Cursor app data directory does not exist: $cursorAppData"
    }

    # Check Cursor installation
    $cursorPaths = @()
    $installPath = Resolve-CursorInstallPath
    if ($installPath) {
        $cursorPaths = @(Join-Path $installPath "Cursor.exe")
    }

    $cursorFound = $false
    foreach ($path in $cursorPaths) {
        if (Test-Path $path) {
            Write-Host "$GREEN✅ [Check]$NC Found Cursor installation: $path"
            $cursorFound = $true
            break
        }
    }

    if (-not $cursorFound) {
        $issues += "Cursor installation not found, please confirm Cursor is properly installed"
    }

    # Return check results
    if ($issues.Count -eq 0) {
        Write-Host "$GREEN✅ [Environment Check]$NC All checks passed"
        return @{ Success = $true; Issues = @() }
    } else {
        Write-Host "$RED❌ [Environment Check]$NC Found $($issues.Count) issues:"
        foreach ($issue in $issues) {
            Write-Host "$RED  • ${issue}$NC"
        }
        return @{ Success = $false; Issues = $issues }
    }
}

# 🛠️ Modify machine code config (enhanced version)
function Modify-MachineCodeConfig {
    param(
        [string]$Mode = "FULL"
    )

    Write-Host ""
    Write-Host "$GREEN🛠️  [Config]$NC Modifying machine code config..."

    $configPath = $STORAGE_FILE
    if (-not $configPath) {
        Write-Host "$RED❌ [Error]$NC Unable to resolve config file path"
        return $false
    }

    # Enhanced config file check
    if (-not (Test-Path $configPath)) {
        Write-Host "$RED❌ [Error]$NC Config file does not exist: $configPath"
        Write-Host ""
        Write-Host "$YELLOW💡 [Solution]$NC Please try the following steps:"
        Write-Host "  1.  Manually launch the Cursor application$NC"
        Write-Host "  2.  Wait for Cursor to fully load (about 30 seconds)$NC"
        Write-Host "  3.  Close the Cursor application$NC"
        Write-Host "  4.  Rerun this script$NC"
        Write-Host ""
        Write-Host "$YELLOW⚠️  [Alternative]$NC If the problem persists:"
        Write-Host "  • Select the script's 'Reset Environment + Modify Machine Code' option$NC"
        Write-Host "  • This option will auto-generate the config file$NC"
        Write-Host ""

        # Provide user choice
        $userChoice = Read-Host "Try to launch Cursor now to generate config file? (y/n)"
        if ($userChoice -match "^(y|yes)$") {
            Write-Host "🚀 [Attempt]$NC Attempting to launch Cursor..."
            return Start-CursorToGenerateConfig
        }

        return $false
    }

    # Ensure processes are fully closed even in modify-only mode
    if ($Mode -eq "MODIFY_ONLY") {
        Write-Host "🔒 [Security Check]$NC Even in modify-only mode, need to ensure Cursor processes are fully closed"
        if (-not (Stop-AllCursorProcesses -MaxRetries 3 -WaitSeconds 3)) {
            Write-Host "$RED❌ [Error]$NC Unable to close all Cursor processes, modification may fail"
            $userChoice = Read-Host "Force continue? (y/n)"
            if ($userChoice -notmatch "^(y|yes)$") {
                return $false
            }
        }
    }

    # Check file permissions and lock status
    if (-not (Test-FileAccessibility -FilePath $configPath)) {
        Write-Host "$RED❌ [Error]$NC Unable to access config file, may be locked or insufficient permissions"
        return $false
    }

    # Verify config file format and display structure
    try {
        Write-Host "🔍 [Verify]$NC Checking config file format..."
        $originalContent = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
        $config = $originalContent | ConvertFrom-Json -ErrorAction Stop
        Write-Host "$GREEN✅ [Verify]$NC Config file format correct"

        # Display relevant properties in current config file
        Write-Host "📋 [Current Config]$NC Checking existing telemetry properties:"
        $telemetryProperties = @('telemetry.machineId', 'telemetry.macMachineId', 'telemetry.devDeviceId', 'telemetry.sqmId')
        foreach ($prop in $telemetryProperties) {
            if ($config.PSObject.Properties[$prop]) {
                $value = $config.$prop
                $displayValue = if ($value.Length -gt 20) { "$($value.Substring(0,20))..." } else { $value }
                Write-Host "$GREEN  ✓ ${prop}$NC = $displayValue"
            } else {
                Write-Host "$YELLOW  - ${prop}$NC (does not exist, will create)"
            }
        }
        Write-Host ""
    } catch {
        Write-Host "$RED❌ [Error]$NC Config file format error: $($_.Exception.Message)"
        Write-Host "$YELLOW💡 [Suggestion]$NC Config file may be corrupted, suggest selecting 'Reset Environment + Modify Machine Code' option"
        return $false
    }

    # Implement atomic file operations and retry mechanism
    $maxRetries = 3
    $retryCount = 0

    while ($retryCount -lt $maxRetries) {
        $retryCount++
        Write-Host ""
        Write-Host "🔄 [Attempt]$NC Attempt $retryCount/$maxRetries to modify..."

        try {
            # Display operation progress
            Write-Host "⏳ [Progress]$NC 1/6 - Generating new device identifiers..."

            # Generate new IDs
            $MAC_MACHINE_ID = [System.Guid]::NewGuid().ToString()
            $UUID = [System.Guid]::NewGuid().ToString()
            $prefixBytes = [System.Text.Encoding]::UTF8.GetBytes("auth0|user_")
            $prefixHex = -join ($prefixBytes | ForEach-Object { '{0:x2}' -f $_ })
            $randomBytes = New-Object byte[] 32
            $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
            $rng.GetBytes($randomBytes)
            $randomPart = [System.BitConverter]::ToString($randomBytes) -replace '-',''
            $rng.Dispose()
            $MACHINE_ID = "${prefixHex}${randomPart}"
            $SQM_ID = "{$([System.Guid]::NewGuid().ToString().ToUpper())}"
            # 🔧 New: serviceMachineId (for storage.serviceMachineId)
            $SERVICE_MACHINE_ID = [System.Guid]::NewGuid().ToString()
            # 🔧 New: firstSessionDate (reset first session date, use UTC time to avoid semantic errors with local time having Z)
            $FIRST_SESSION_DATE = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            $SESSION_ID = [System.Guid]::NewGuid().ToString()

            # Shared IDs (for consistency between config and JS injection)
            $global:CursorIds = @{
                machineId        = $MACHINE_ID
                macMachineId     = $MAC_MACHINE_ID
                devDeviceId      = $UUID
                sqmId            = $SQM_ID
                firstSessionDate = $FIRST_SESSION_DATE
                sessionId        = $SESSION_ID
                macAddress       = "00:11:22:33:44:55"
            }

            Write-Host "$GREEN✅ [Progress]$NC 1/7 - Device identifier generation complete"

            Write-Host "⏳ [Progress]$NC 2/7 - Creating backup directory..."

            # Backup original values (enhanced version)
            $backupDir = $BACKUP_DIR
            if (-not $backupDir) {
                throw "Unable to resolve backup directory path"
            }
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
            }

            $backupName = "storage.json.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')_retry$retryCount"
            $backupPath = "$backupDir\$backupName"

            Write-Host "⏳ [Progress]$NC 3/7 - Backing up original config..."
            Copy-Item $configPath $backupPath -ErrorAction Stop

            # Verify backup success
            if (Test-Path $backupPath) {
                $backupSize = (Get-Item $backupPath).Length
                $originalSize = (Get-Item $configPath).Length
                if ($backupSize -eq $originalSize) {
                    Write-Host "$GREEN✅ [Progress]$NC 3/7 - Config backup successful: $backupName"
                } else {
                    Write-Host "$YELLOW⚠️  [Warning]$NC Backup file size mismatch, but continuing"
                }
            } else {
                throw "Backup file creation failed"
            }

            Write-Host "⏳ [Progress]$NC 4/7 - Reading original config to memory..."

            # Atomic operation: read original content to memory
            $originalContent = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
            $config = $originalContent | ConvertFrom-Json -ErrorAction Stop

            Write-Host "⏳ [Progress]$NC 5/7 - Updating config in memory..."

            # Update config values (safe way, ensure properties exist)
            # 🔧 Fix: Add storage.serviceMachineId and telemetry.firstSessionDate
            $propertiesToUpdate = @{
                'telemetry.machineId' = $MACHINE_ID
                'telemetry.macMachineId' = $MAC_MACHINE_ID
                'telemetry.devDeviceId' = $UUID
                'telemetry.sqmId' = $SQM_ID
                'storage.serviceMachineId' = $SERVICE_MACHINE_ID
                'telemetry.firstSessionDate' = $FIRST_SESSION_DATE
            }

            foreach ($property in $propertiesToUpdate.GetEnumerator()) {
                $key = $property.Key
                $value = $property.Value

                # Use Add-Member or direct assignment safely
                if ($config.PSObject.Properties[$key]) {
                    # Property exists, update directly
                    $config.$key = $value
                    Write-Host "  ✓ Update property: ${key}$NC"
                } else {
                    # Property does not exist, add new property
                    $config | Add-Member -MemberType NoteProperty -Name $key -Value $value -Force
                    Write-Host "  + Add property: ${key}$NC"
                }
            }
            
            Write-Host "⏳ [Progress]$NC 6/7 - Atomically writing new config file..."
            
            # Atomic operation: delete original file, write new file
            $tempPath = "$configPath.tmp"
            $updatedJson = $config | ConvertTo-Json -Depth 10
            
            # Write to temp file
            [System.IO.File]::WriteAllText($tempPath, $updatedJson, [System.Text.Encoding]::UTF8)
            
            # Verify temp file
            $tempContent = Get-Content $tempPath -Raw -Encoding UTF8 -ErrorAction Stop
            $tempConfig = $tempContent | ConvertFrom-Json -ErrorAction Stop
            
            # 🔧 Critical fix: PowerShell's ConvertFrom-Json automatically parses ISO-8601 date strings as DateTime
            # To avoid false positives from "expected value (string) vs actual value (DateTime)", normalize values before comparison
            $toComparableString = {
                param([object]$v)
                if ($null -eq $v) { return $null }
                if ($v -is [DateTime]) { return $v.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
                if ($v -is [DateTimeOffset]) { return $v.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
                return [string]$v
            }
            
            # Verify all properties were written correctly
            $tempVerificationPassed = $true
            foreach ($property in $propertiesToUpdate.GetEnumerator()) {
                $key = $property.Key
                $expectedValue = $property.Value
                $actualValue = $tempConfig.$key
            
                $expectedComparable = & $toComparableString $expectedValue
                $actualComparable = & $toComparableString $actualValue
            
                if ($actualComparable -ne $expectedComparable) {
                    $tempVerificationPassed = $false
                    Write-Host "$RED  ✗ Temp file verification failed: ${key}$NC"
                    $expectedType = if ($null -eq $expectedValue) { '<null>' } else { $expectedValue.GetType().FullName }
                    $actualType = if ($null -eq $actualValue) { '<null>' } else { $actualValue.GetType().FullName }
                    Write-Host "$YELLOW    [Debug] Type: Expected=${expectedType}; Actual=${actualType}$NC"
                    Write-Host "$YELLOW    [Debug] Value (normalized): Expected=${expectedComparable}; Actual=${actualComparable}$NC"
                    break
                }
            }
            
            if (-not $tempVerificationPassed) {
                Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
                throw "Temp file verification failed"
            }
            
            # Atomic replacement: delete original file, rename temp file
            Remove-Item $configPath -Force
            Move-Item $tempPath $configPath
            
            # Set file as read-only (optional)
            $file = Get-Item $configPath
            $file.IsReadOnly = $false  # Keep writable for future modifications
            
            # Final verification of modification results
            Write-Host "⏳ [Progress]$NC 7/7 - Verifying new config file..."
            
            $verifyContent = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
            $verifyConfig = $verifyContent | ConvertFrom-Json -ErrorAction Stop
            
            $verificationPassed = $true
            $verificationResults = @()
            
            # Safely verify each property
            foreach ($property in $propertiesToUpdate.GetEnumerator()) {
                $key = $property.Key
                $expectedValue = $property.Value
                $actualValue = $verifyConfig.$key
            
                $expectedComparable = & $toComparableString $expectedValue
                $actualComparable = & $toComparableString $actualValue
            
                if ($actualComparable -eq $expectedComparable) {
                    $verificationResults += "✓ ${key}: Verification passed"
                } else {
                    $expectedType = if ($null -eq $expectedValue) { '<null>' } else { $expectedValue.GetType().FullName }
                    $actualType = if ($null -eq $actualValue) { '<null>' } else { $actualValue.GetType().FullName }
                    $verificationResults += "✗ ${key}: Verification failed (Expected type: ${expectedType}, Actual type: ${actualType}; Expected: ${expectedComparable}, Actual: ${actualComparable})"
                    $verificationPassed = $false
                }
            }

            # Display verification results
            Write-Host "📋 [Verification Details]$NC"
            foreach ($result in $verificationResults) {
                Write-Host "   $result"
            }

            if ($verificationPassed) {
                Write-Host "$GREEN✅ [Success]$NC Attempt $retryCount modification successful!"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC Machine code config modification complete!"
                Write-Host "📋 [Details]$NC Updated the following identifiers:"
                Write-Host "   🔹 machineId: $MACHINE_ID"
                Write-Host "   🔹 macMachineId: $MAC_MACHINE_ID"
                Write-Host "   🔹 devDeviceId: $UUID"
                Write-Host "   🔹 sqmId: $SQM_ID"
                Write-Host "   🔹 serviceMachineId: $SERVICE_MACHINE_ID"
                Write-Host "   🔹 firstSessionDate: $FIRST_SESSION_DATE"
                Write-Host ""
                Write-Host "$GREEN💾 [Backup]$NC Original config backed up to: $backupName"

                # 🔧 New: Modify machineid file
                Write-Host "🔧 [machineid]$NC Modifying machineid file..."
                $machineIdFilePath = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir "machineid" } else { $null }
                if (-not $machineIdFilePath) {
                    Write-Host "$YELLOW⚠️  [machineid]$NC Unable to resolve machineid file path, skipping modification"
                } else {
                    try {
                        if (Test-Path $machineIdFilePath) {
                            # Backup original machineid file
                            $machineIdBackup = "$backupDir\machineid.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                            Copy-Item $machineIdFilePath $machineIdBackup -Force
                            Write-Host "$GREEN💾 [Backup]$NC machineid file backed up: $machineIdBackup"
                        }
                        # Write new serviceMachineId to machineid file
                        [System.IO.File]::WriteAllText($machineIdFilePath, $SERVICE_MACHINE_ID, [System.Text.Encoding]::UTF8)
                        Write-Host "$GREEN✅ [machineid]$NC machineid file modified successfully: $SERVICE_MACHINE_ID"

                        # Set machineid file as read-only
                        $machineIdFile = Get-Item $machineIdFilePath
                        $machineIdFile.IsReadOnly = $true
                        Write-Host "$GREEN🔒 [Protect]$NC machineid file set to read-only"
                    } catch {
                        Write-Host "$YELLOW⚠️  [machineid]$NC machineid file modification failed: $($_.Exception.Message)"
                        Write-Host "💡 [Tip]$NC Can manually modify file: $machineIdFilePath"
                    }
                }

                # 🔧 New: Modify .updaterId file (updater device identifier)
                Write-Host "🔧 [updaterId]$NC Modifying .updaterId file..."
                $updaterIdFilePath = if ($global:CursorAppDataDir) { Join-Path $global:CursorAppDataDir ".updaterId" } else { $null }
                if (-not $updaterIdFilePath) {
                    Write-Host "$YELLOW⚠️  [updaterId]$NC Unable to resolve .updaterId file path, skipping modification"
                } else {
                    try {
                        if (Test-Path $updaterIdFilePath) {
                            # Backup original .updaterId file
                            $updaterIdBackup = "$backupDir\.updaterId.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                            Copy-Item $updaterIdFilePath $updaterIdBackup -Force
                            Write-Host "$GREEN💾 [Backup]$NC .updaterId file backed up: $updaterIdBackup"
                        }
                        # Generate new updaterId (UUID format)
                        $newUpdaterId = [System.Guid]::NewGuid().ToString()
                        [System.IO.File]::WriteAllText($updaterIdFilePath, $newUpdaterId, [System.Text.Encoding]::UTF8)
                        Write-Host "$GREEN✅ [updaterId]$NC .updaterId file modified successfully: $newUpdaterId"

                        # Set .updaterId file as read-only
                        $updaterIdFile = Get-Item $updaterIdFilePath
                        $updaterIdFile.IsReadOnly = $true
                        Write-Host "$GREEN🔒 [Protect]$NC .updaterId file set to read-only"
                    } catch {
                        Write-Host "$YELLOW⚠️  [updaterId]$NC .updaterId file modification failed: $($_.Exception.Message)"
                        Write-Host "💡 [Tip]$NC Can manually modify file: $updaterIdFilePath"
                    }
                }

                # 🔒 Add config file protection mechanism
                Write-Host "🔒 [Protect]$NC Setting config file protection..."
                try {
                    $configFile = Get-Item $configPath
                    $configFile.IsReadOnly = $true
                    Write-Host "$GREEN✅ [Protect]$NC Config file set to read-only to prevent Cursor from overwriting modifications"
                    Write-Host "💡 [Tip]$NC File path: $configPath"
                } catch {
                    Write-Host "$YELLOW⚠️  [Protect]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                    Write-Host "💡 [Suggestion]$NC Can manually right-click file → Properties → check 'Read-only'"
                }
                Write-Host " 🔒 [Security]$NC Recommend restarting Cursor to ensure config takes effect"
                return $true
            } else {
                Write-Host "$RED❌ [Failed]$NC Attempt $retryCount verification failed"
                if ($retryCount -lt $maxRetries) {
                    Write-Host "🔄 [Restore]$NC Restoring backup, preparing to retry..."
                    Copy-Item $backupPath $configPath -Force
                    Start-Sleep -Seconds 2
                    continue  # Continue to next retry
                } else {
                    Write-Host "$RED❌ [Final Failure]$NC All retries failed, restoring original config"
                    Copy-Item $backupPath $configPath -Force
                    return $false
                }
            }

        } catch {
            Write-Host "$RED❌ [Exception]$NC Attempt $retryCount encountered exception: $($_.Exception.Message)"
            Write-Host "💡 [Debug Info]$NC Error type: $($_.Exception.GetType().FullName)"

            # Clean up temp files
            if (Test-Path "$configPath.tmp") {
                Remove-Item "$configPath.tmp" -Force -ErrorAction SilentlyContinue
            }

            if ($retryCount -lt $maxRetries) {
                Write-Host "🔄 [Restore]$NC Restoring backup, preparing to retry..."
                if (Test-Path $backupPath) {
                    Copy-Item $backupPath $configPath -Force
                }
                Start-Sleep -Seconds 3
                continue  # Continue to next retry
            } else {
                Write-Host "$RED❌ [Final Failure]$NC All retries failed"
                # Try to restore backup
                if (Test-Path $backupPath) {
                    Write-Host "🔄 [Restore]$NC Restoring backup config..."
                    try {
                        Copy-Item $backupPath $configPath -Force
                        Write-Host "$GREEN✅ [Restore]$NC Original config restored"
                    } catch {
                        Write-Host "$RED❌ [Error]$NC Restore backup failed: $($_.Exception.Message)"
                    }
                }
                return $false
            }
        }
    }

    # If we reach here, all retries have failed
    Write-Host "$RED❌ [Final Failure]$NC Unable to complete modification after $maxRetries attempts"
    return $false

}

#  Launch Cursor to generate config file
function Start-CursorToGenerateConfig {
    Write-Host "🚀 [Launch]$NC Attempting to launch Cursor to generate config file..."

    # Find Cursor executable (supports auto-detection + manual fallback)
    $installPath = Resolve-CursorInstallPath -AllowPrompt
    $cursorPath = if ($installPath) { Join-Path $installPath "Cursor.exe" } else { $null }

    if (-not $cursorPath) {
        Write-Host "$RED❌ [Error]$NC Cursor installation not found, please confirm Cursor is properly installed"
        return $false
    }

    try {
        Write-Host "📍 [Path]$NC Using Cursor path: $cursorPath"

        # Launch Cursor
        $process = Start-Process -FilePath $cursorPath -PassThru -WindowStyle Normal
        Write-Host "$GREEN🚀 [Launch]$NC Cursor launched, PID: $($process.Id)"

        Write-Host "$YELLOW⏳ [Wait]$NC Please wait for Cursor to fully load (about 30 seconds)..."
        Write-Host "💡 [Tip]$NC You can manually close Cursor after it fully loads"

        # Wait for config file generation
        $configPath = $STORAGE_FILE
        if (-not $configPath) {
            Write-Host "$RED❌ [Error]$NC Unable to resolve config file path"
            return $false
        }
        $maxWait = 60
        $waited = 0

        while (-not (Test-Path $configPath) -and $waited -lt $maxWait) {
            Start-Sleep -Seconds 2
            $waited += 2
            if ($waited % 10 -eq 0) {
                Write-Host "$YELLOW⏳ [Wait]$NC Waiting for config file generation... ($waited/$maxWait sec)"
            }
        }

        if (Test-Path $configPath) {
            Write-Host "$GREEN✅ [Success]$NC Config file generated!"
            Write-Host "💡 [Tip]$NC You can now close Cursor and rerun the script"
            return $true
        } else {
            Write-Host "$YELLOW⚠️  [Timeout]$NC Config file was not generated within expected time"
            Write-Host "💡 [Suggestion]$NC Please manually operate Cursor (e.g., create a new file) to trigger config generation"
            return $false
        }

    } catch {
        Write-Host "$RED❌ [Error]$NC Failed to launch Cursor: $($_.Exception.Message)"
        return $false
    }
}

# Check administrator privileges
function Test-Administrator {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($user)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host "$RED[Error]$NC Please run this script as administrator"
    Write-Host "Right-click the script and select 'Run as administrator'"
    Read-Host "Press Enter to exit"
    exit 1
}

# Display Logo
Clear-Host
Write-Host @"

    ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ 
   ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
   ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
   ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
   ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
    ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝

"@
Write-Host "================================$NC"
Write-Host "$GREEN🚀   Cursor Trial Reset Tool          $NC"
Write-Host "$YELLOW💡  This tool is free and open source$NC"
Write-Host "================================$NC"

# 🎯 User selection menu
Write-Host ""
Write-Host "$GREEN🎯 [Select Mode]$NC Please select the operation you want to perform:"
Write-Host ""
Write-Host "1.  Modify machine code only$NC"
Write-Host "$YELLOW      • Execute machine code modification function$NC"
Write-Host "$YELLOW      • Execute injection of crack JS code into core files$NC"
Write-Host "$YELLOW      • Skip folder deletion/environment reset steps$NC"
Write-Host "$YELLOW      • Preserve existing Cursor config and data$NC"
Write-Host ""
Write-Host "2.  Reset environment + Modify machine code$NC"
Write-Host "$RED      • Perform complete environment reset (delete Cursor folders)$NC"
Write-Host "$RED      • ⚠️  Config will be lost, please backup$NC"
Write-Host "$YELLOW      • Follow machine code modification$NC"
Write-Host "$YELLOW      • Execute injection of crack JS code into core files$NC"
Write-Host "$YELLOW      • This is equivalent to current full script behavior$NC"
Write-Host ""

# Get user selection
do {
    $userChoice = Read-Host "Please enter your choice (1 or 2)"
    if ($userChoice -eq "1") {
        Write-Host "$GREEN✅ [Selection]$NC You selected: Modify machine code only"
        $executeMode = "MODIFY_ONLY"
        break
    } elseif ($userChoice -eq "2") {
        Write-Host "$GREEN✅ [Selection]$NC You selected: Reset environment + Modify machine code"
        Write-Host "$RED⚠️  [Important Warning]$NC This operation will delete all Cursor config files!"
        $confirmReset = Read-Host "Confirm to perform complete reset? (enter yes to confirm, any other key to cancel)"
        if ($confirmReset -eq "yes") {
            $executeMode = "RESET_AND_MODIFY"
            break
        } else {
            Write-Host "$YELLOW👋 [Cancel]$NC User cancelled reset operation"
            continue
        }
    } else {
        Write-Host "$RED❌ [Error]$NC Invalid selection, please enter 1 or 2"
    }
} while ($true)

Write-Host ""

# 📋 Display execution flow description based on selection
if ($executeMode -eq "MODIFY_ONLY") {
    Write-Host "$GREEN📋 [Execution Flow]$NC Modify machine code only mode will execute the following steps:"
    Write-Host "1.  Detect Cursor config file$NC"
    Write-Host "2.  Backup existing config file$NC"
    Write-Host "3.  Modify machine code config$NC"
    Write-Host "4.  Display operation completion info$NC"
    Write-Host ""
    Write-Host "$YELLOW⚠️  [Notes]$NC"
    Write-Host "$YELLOW  • Will not delete any folders or reset environment$NC"
    Write-Host "$YELLOW  • Preserve all existing config and data$NC"
    Write-Host "$YELLOW  • Original config file will be automatically backed up$NC"
} else {
    Write-Host "$GREEN📋 [Execution Flow]$NC Reset environment + Modify machine code mode will execute the following steps:"
    Write-Host "  1.  Detect and close Cursor process$NC"
    Write-Host "  2.  Save Cursor program path info$NC"
    Write-Host "  3.  Delete specified Cursor trial-related folders$NC"
    Write-Host "      📁 C:\Users\Administrator\.cursor$NC"
    Write-Host "      📁 C:\Users\Administrator\AppData\Roaming\Cursor$NC"
    Write-Host "      📁 C:\Users\%USERNAME%\.cursor$NC"
    Write-Host "      📁 C:\Users\%USERNAME%\AppData\Roaming\Cursor$NC"
    Write-Host "  3.5. Pre-create necessary directory structure to avoid permission issues$NC"
    Write-Host "  4.  Restart Cursor to let it generate new config file$NC"
    Write-Host "  5.  Wait for config file generation to complete (max 45 seconds)$NC"
    Write-Host "  6.  Close Cursor process$NC"
    Write-Host "  7.  Modify newly generated machine code config file$NC"
    Write-Host "  8.  Display operation completion statistics$NC"
    Write-Host ""
    Write-Host "$YELLOW⚠️  [Notes]$NC"
    Write-Host "$YELLOW  • Please do not manually operate Cursor during script execution$NC"
    Write-Host "$YELLOW  • Recommend closing all Cursor windows before execution$NC"
    Write-Host "$YELLOW  • Need to restart Cursor after execution completes$NC"
    Write-Host "$YELLOW  • Original config file will be automatically backed up to backups folder$NC"
}
Write-Host ""

# 🤔 User confirmation
Write-Host "$GREEN🤔 [Confirm]$NC Please confirm you understand the above execution flow"
$confirmation = Read-Host "Continue execution? (enter y or yes to continue, any other key to exit)"
if ($confirmation -notmatch "^(y|yes)$") {
    Write-Host "$YELLOW👋 [Exit]$NC User cancelled execution, script exiting"
    Read-Host "Press Enter to exit"
    exit 0
}
Write-Host "$GREEN✅ [Confirm]$NC User confirmed to continue execution"
Write-Host ""

# Get and display Cursor version
function Get-CursorVersion {
    try {
        # Primary detection path (based on install path resolution)
        $installPath = Resolve-CursorInstallPath
        $packagePath = if ($installPath) { Join-Path $installPath "resources\app\package.json" } else { $null }
        if ($packagePath -and (Test-Path $packagePath)) {
            $packageJson = Get-Content $packagePath -Raw | ConvertFrom-Json
            if ($packageJson.version) {
                Write-Host "$GREEN[Info]$NC Currently installed Cursor version: v$($packageJson.version)"
                return $packageJson.version
            }
        }

        # Backup path detection (compatible with old directory structure)
        $altPath = if ($global:CursorLocalAppDataRoot) { Join-Path $global:CursorLocalAppDataRoot "cursor\resources\app\package.json" } else { $null }
        if ($altPath -and (Test-Path $altPath)) {
            $packageJson = Get-Content $altPath -Raw | ConvertFrom-Json
            if ($packageJson.version) {
                Write-Host "$GREEN[Info]$NC Currently installed Cursor version: v$($packageJson.version)"
                return $packageJson.version
            }
        }

        Write-Host "$YELLOW[Warning]$NC Unable to detect Cursor version"
        Write-Host "$YELLOW[Tip]$NC Please ensure Cursor is properly installed"
        return $null
    }
    catch {
        Write-Host "$RED[Error]$NC Failed to get Cursor version: $_"
        return $null
    }
}

# Get and display version info
$cursorVersion = Get-CursorVersion
Write-Host ""

Write-Host "$YELLOW💡 [Important Notice]$NC Latest 1.0.x version is now supported"

Write-Host ""

# 🔍 Check and close Cursor process
Write-Host "$GREEN🔍 [Check]$NC Checking Cursor process..."

function Get-ProcessDetails {
    param($processName)
    Write-Host "🔍 [Debug]$NC Getting $processName process details:"
    Get-WmiObject Win32_Process -Filter "name='$processName'" |
        Select-Object ProcessId, ExecutablePath, CommandLine |
        Format-List
}

# Define max retry count and wait time
$MAX_RETRIES = 5
$WAIT_TIME = 1

# 🔄 Handle process close and save process info
function Close-CursorProcessAndSaveInfo {
    param($processName)

    $global:CursorProcessInfo = $null

    $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if ($processes) {
        Write-Host "$YELLOW⚠️  [Warning]$NC Found $processName is running"

        # 💾 Save process info for later restart - Fix: ensure getting single process path
        $firstProcess = if ($processes -is [array]) { $processes[0] } else { $processes }
        $processPath = $firstProcess.Path

        # Ensure path is string not array
        if ($processPath -is [array]) {
            $processPath = $processPath[0]
        }

        $global:CursorProcessInfo = @{
            ProcessName = $firstProcess.ProcessName
            Path = $processPath
            StartTime = $firstProcess.StartTime
        }
        Write-Host "$GREEN💾 [Save]$NC Saved process info: $($global:CursorProcessInfo.Path)"

        Get-ProcessDetails $processName

        Write-Host "$YELLOW🔄 [Action]$NC Attempting to close $processName..."
        Stop-Process -Name $processName -Force

        $retryCount = 0
        while ($retryCount -lt $MAX_RETRIES) {
            $process = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if (-not $process) { break }

            $retryCount++
            if ($retryCount -ge $MAX_RETRIES) {
                Write-Host "$RED❌ [Error]$NC Unable to close $processName after $MAX_RETRIES attempts"
                Get-ProcessDetails $processName
                Write-Host "$RED💥 [Error]$NC Please manually close the process and retry"
                Read-Host "Press Enter to exit"
                exit 1
            }
            Write-Host "$YELLOW⏳ [Wait]$NC Waiting for process to close, attempt $retryCount/$MAX_RETRIES..."
            Start-Sleep -Seconds $WAIT_TIME
        }
        Write-Host "$GREEN✅ [Success]$NC $processName successfully closed"
    } else {
        Write-Host "💡 [Tip]$NC No $processName process found running"
        # Try to find Cursor installation path
        $installPath = Resolve-CursorInstallPath
        $candidatePath = if ($installPath) { Join-Path $installPath "Cursor.exe" } else { $null }
        if ($candidatePath -and (Test-Path $candidatePath)) {
            $global:CursorProcessInfo = @{
                ProcessName = "Cursor"
                Path = $candidatePath
                StartTime = $null
            }
            Write-Host "$GREEN💾 [Found]$NC Found Cursor installation path: $candidatePath"
        }

        if (-not $global:CursorProcessInfo) {
            Write-Host "$YELLOW⚠️  [Warning]$NC Cursor installation path not found, will use default path"
            $defaultInstallPath = if ($global:CursorLocalAppDataRoot) { Join-Path $global:CursorLocalAppDataRoot "Programs\cursor\Cursor.exe" } else { "$env:LOCALAPPDATA\Programs\cursor\Cursor.exe" }
            $global:CursorProcessInfo = @{
                ProcessName = "Cursor"
                Path = $defaultInstallPath
                StartTime = $null
            }
        }
    }
}

# Ensure backup directory exists
if (-not $BACKUP_DIR) {
    Write-Host "$YELLOW⚠️  [Warning]$NC Unable to resolve backup directory path, skipping creation"
} elseif (-not (Test-Path $BACKUP_DIR)) {
    try {
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
        Write-Host "$GREEN✅ [Backup Dir]$NC Backup directory created successfully: $BACKUP_DIR"
    } catch {
        Write-Host "$YELLOW⚠️  [Warning]$NC Backup directory creation failed: $($_.Exception.Message)"
    }
}

# Execute corresponding function based on user selection
if ($executeMode -eq "MODIFY_ONLY") {
    Write-Host "$GREEN🚀 [Start]$NC Starting modify machine code only function..."

    # First perform environment check
    $envCheck = Test-CursorEnvironment -Mode "MODIFY_ONLY"
    if (-not $envCheck.Success) {
        Write-Host ""
        Write-Host "$RED❌ [Environment Check Failed]$NC Cannot continue execution, found the following issues:"
        foreach ($issue in $envCheck.Issues) {
            Write-Host "$RED  • ${issue}$NC"
        }
        Write-Host ""
        Write-Host "$YELLOW💡 [Suggestion]$NC Please select one of the following actions:"
        Write-Host "  1.  Select 'Reset Environment + Modify Machine Code' option (recommended)$NC"
        Write-Host "  2.  Manually launch Cursor once, then rerun the script$NC"
        Write-Host "  3.  Check if Cursor is properly installed$NC"
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }

    # Execute machine code modification
    $configSuccess = Modify-MachineCodeConfig -Mode "MODIFY_ONLY"

    if ($configSuccess) {
        Write-Host ""
        Write-Host "$GREEN🎉 [Config File]$NC Machine code config file modification complete!"

        # Add registry modification
        Write-Host "🔧 [Registry]$NC Modifying system registry..."
        $registrySuccess = Update-MachineGuid

        # 🔧 New: JavaScript injection function (device identification bypass enhancement)
        Write-Host ""
        Write-Host "🔧 [Device ID Bypass]$NC Executing JavaScript injection function..."
        Write-Host "💡 [Note]$NC This function will directly modify Cursor core JS files to achieve deeper device identification bypass"
        $jsSuccess = Modify-CursorJSFiles

        if ($registrySuccess) {
            Write-Host "$GREEN✅ [Registry]$NC System registry modification successful"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection function executed successfully"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC All machine code modifications complete (enhanced version)!"
                Write-Host "📋 [Details]$NC Completed the following modifications:"
                Write-Host "$GREEN  ✓ Cursor config file (storage.json)$NC"
                Write-Host "$GREEN  ✓ System registry (MachineGuid)$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel injection (device ID bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection function failed, but other functions successful"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC All machine code modifications complete!"
                Write-Host "📋 [Details]$NC Completed the following modifications:"
                Write-Host "$GREEN  ✓ Cursor config file (storage.json)$NC"
                Write-Host "$GREEN  ✓ System registry (MachineGuid)$NC"
                Write-Host "$YELLOW  ⚠ JavaScript kernel injection (partially failed)$NC"
            }

            # 🔒 Add config file protection mechanism
            Write-Host "🔒 [Protect]$NC Setting config file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Unable to resolve config file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protect]$NC Config file set to read-only to prevent Cursor from overwriting modifications"
                Write-Host "💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protect]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "💡 [Suggestion]$NC Can manually right-click file → Properties → check 'Read-only'"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Registry]$NC Registry modification failed, but config file modification successful"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection function executed successfully"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Config file and JavaScript injection complete, registry modification failed"
                Write-Host "💡 [Suggestion]$NC May need administrator privileges to modify registry"
                Write-Host "📋 [Details]$NC Completed the following modifications:"
                Write-Host "$GREEN  ✓ Cursor config file (storage.json)$NC"
                Write-Host "$YELLOW  ⚠ System registry (MachineGuid) - Failed$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel injection (device ID bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection function failed"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Config file modification complete, registry and JavaScript injection failed"
                Write-Host "💡 [Suggestion]$NC May need administrator privileges to modify registry"
            }

            # 🔒 Even if registry modification fails, still protect config file
            Write-Host "🔒 [Protect]$NC Setting config file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Unable to resolve config file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protect]$NC Config file set to read-only to prevent Cursor from overwriting modifications"
                Write-Host "💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protect]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "💡 [Suggestion]$NC Can manually right-click file → Properties → check 'Read-only'"
            }
        }

        Write-Host ""
        Write-Host "🚫 [Disable Update]$NC Disabling Cursor auto update..."
        if (Disable-CursorAutoUpdate) {
            Write-Host "$GREEN✅ [Disable Update]$NC Auto update processed"
        } else {
            Write-Host "$YELLOW⚠️  [Disable Update]$NC Unable to confirm update disable, may need manual handling"
        }

        Write-Host "💡 [Tip]$NC You can now launch Cursor with the new machine code config"
    } else {
        Write-Host ""
        Write-Host "$RED❌ [Failed]$NC Machine code modification failed!"
        Write-Host "$YELLOW💡 [Suggestion]$NC Please try 'Reset Environment + Modify Machine Code' option"
    }
} else {
    # Complete reset environment + modify machine code workflow
    Write-Host "$GREEN🚀 [Start]$NC Starting reset environment + modify machine code function..."

    # 🚀 Close all Cursor processes and save info
    Close-CursorProcessAndSaveInfo "Cursor"
    if (-not $global:CursorProcessInfo) {
        Close-CursorProcessAndSaveInfo "cursor"
    }

    # 🚨 Important warning
    Write-Host ""
    Write-Host "$RED🚨 [Important Warning]$NC ============================================"
    Write-Host "$YELLOW⚠️  [Risk Control Reminder]$NC Cursor risk control mechanism is very strict!"
    Write-Host "$YELLOW⚠️  [Must Delete]$NC Must completely delete specified folders, no residual settings allowed"
    Write-Host "$YELLOW⚠️  [Prevent Trial Loss]$NC Only thorough cleanup can effectively prevent losing trial Pro status"
    Write-Host "$RED🚨 [Important Warning]$NC ============================================"
    Write-Host ""

    # 🎯 Execute Cursor prevent trial loss Pro delete folders function
    Write-Host "$GREEN🚀 [Start]$NC Starting core function execution..."
    Remove-CursorTrialFolders



    # 🔄 Restart Cursor to regenerate config file
    Restart-CursorAndWait

    # 🛠️ Modify machine code config
    $configSuccess = Modify-MachineCodeConfig
    
    # 🧹 Execute Cursor initialization cleanup
    Invoke-CursorInitialization

    if ($configSuccess) {
        Write-Host ""
        Write-Host "$GREEN🎉 [Config File]$NC Machine code config file modification complete!"

        # Add registry modification
        Write-Host "🔧 [Registry]$NC Modifying system registry..."
        $registrySuccess = Update-MachineGuid

        # 🔧 New: JavaScript injection function (device identification bypass enhancement)
        Write-Host ""
        Write-Host "🔧 [Device ID Bypass]$NC Executing JavaScript injection function..."
        Write-Host "💡 [Note]$NC This function will directly modify Cursor core JS files to achieve deeper device identification bypass"
        $jsSuccess = Modify-CursorJSFiles

        if ($registrySuccess) {
            Write-Host "$GREEN✅ [Registry]$NC System registry modification successful"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection function executed successfully"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC All operations complete (enhanced version)!"
                Write-Host "📋 [Details]$NC Completed the following operations:"
                Write-Host "$GREEN  ✓ Delete Cursor trial-related folders$NC"
                Write-Host "$GREEN  ✓ Cursor initialization cleanup$NC"
                Write-Host "$GREEN  ✓ Regenerate config file$NC"
                Write-Host "$GREEN  ✓ Modify machine code config$NC"
                Write-Host "$GREEN  ✓ Modify system registry$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel injection (device ID bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection function failed, but other functions successful"
                Write-Host ""
                Write-Host "$GREEN🎉 [Complete]$NC All operations complete!"
                Write-Host "📋 [Details]$NC Completed the following operations:"
                Write-Host "$GREEN  ✓ Delete Cursor trial-related folders$NC"
                Write-Host "$GREEN  ✓ Cursor initialization cleanup$NC"
                Write-Host "$GREEN  ✓ Regenerate config file$NC"
                Write-Host "$GREEN  ✓ Modify machine code config$NC"
                Write-Host "$GREEN  ✓ Modify system registry$NC"
                Write-Host "$YELLOW  ⚠ JavaScript kernel injection (partially failed)$NC"
            }

            # 🔒 Add config file protection mechanism
            Write-Host "🔒 [Protect]$NC Setting config file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Unable to resolve config file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protect]$NC Config file set to read-only to prevent Cursor from overwriting modifications"
                Write-Host "💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protect]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "💡 [Suggestion]$NC Can manually right-click file → Properties → check 'Read-only'"
            }
        } else {
            Write-Host "$YELLOW⚠️  [Registry]$NC Registry modification failed, but other operations successful"

            if ($jsSuccess) {
                Write-Host "$GREEN✅ [JS Injection]$NC JavaScript injection function executed successfully"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Most operations complete, registry modification failed"
                Write-Host "💡 [Suggestion]$NC May need administrator privileges to modify registry"
                Write-Host "📋 [Details]$NC Completed the following operations:"
                Write-Host "$GREEN  ✓ Delete Cursor trial-related folders$NC"
                Write-Host "$GREEN  ✓ Cursor initialization cleanup$NC"
                Write-Host "$GREEN  ✓ Regenerate config file$NC"
                Write-Host "$GREEN  ✓ Modify machine code config$NC"
                Write-Host "$YELLOW  ⚠ Modify system registry - Failed$NC"
                Write-Host "$GREEN  ✓ JavaScript kernel injection (device ID bypass)$NC"
            } else {
                Write-Host "$YELLOW⚠️  [JS Injection]$NC JavaScript injection function failed"
                Write-Host ""
                Write-Host "$YELLOW🎉 [Partially Complete]$NC Most operations complete, registry and JavaScript injection failed"
                Write-Host "💡 [Suggestion]$NC May need administrator privileges to modify registry"
            }

            # 🔒 Even if registry modification fails, still protect config file
            Write-Host "🔒 [Protect]$NC Setting config file protection..."
            try {
                $configPath = $STORAGE_FILE
                if (-not $configPath) {
                    throw "Unable to resolve config file path"
                }
                $configFile = Get-Item $configPath
                $configFile.IsReadOnly = $true
                Write-Host "$GREEN✅ [Protect]$NC Config file set to read-only to prevent Cursor from overwriting modifications"
                Write-Host "💡 [Tip]$NC File path: $configPath"
            } catch {
                Write-Host "$YELLOW⚠️  [Protect]$NC Failed to set read-only attribute: $($_.Exception.Message)"
                Write-Host "💡 [Suggestion]$NC Can manually right-click file → Properties → check 'Read-only'"
            }
        }

        Write-Host ""
        Write-Host "🚫 [Disable Update]$NC Disabling Cursor auto update..."
        if (Disable-CursorAutoUpdate) {
            Write-Host "$GREEN✅ [Disable Update]$NC Auto update processed"
        } else {
            Write-Host "$YELLOW⚠️  [Disable Update]$NC Unable to confirm update disable, may need manual handling"
        }
    } else {
        Write-Host ""
        Write-Host "$RED❌ [Failed]$NC Machine code config modification failed!"
        Write-Host "$YELLOW💡 [Suggestion]$NC Please check error messages and retry"
    }
}


Write-Host ""
Write-Host "$GREEN================================$NC"
Write-Host "$GREEN🎉 [Script Complete]$NC Thank you for using the Cursor Trial Reset Tool!"
Write-Host "$YELLOW💡  This tool is free and open source$NC"
Write-Host "$GREEN================================$NC"
Write-Host ""
Read-Host "Press Enter to exit"
exit 0
