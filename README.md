# 🚀 Cursor Free Trial Reset Tool

<div align="center">

[![Release](https://img.shields.io/github/v/release/Naster17/go-cursor-help-en?style=flat-square&logo=github&color=blue)](https://github.com/Naster17/go-cursor-help-en/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square&logo=bookstack)](https://github.com/Naster17/go-cursor-help-en/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/Naster17/go-cursor-help-en?style=flat-square&logo=github)](https://github.com/Naster17/go-cursor-help-en/stargazers)

[🌟 English](README.md) | [🌏 中文](README_CN.md) | [🌏 日本語](README_JP.md)

<img src="/img/cursor.png" alt="Cursor Logo" width="120"/>

</div>

---

## 📋 Overview

A cross-platform tool to reset Cursor IDE trial period by modifying device identifiers. Supports Windows, macOS, and Linux.

> ⚠️ **IMPORTANT NOTICE**
> 
> This tool currently supports:
> - ✅ Windows: Latest 2.x.x versions (Supported)
> - ✅ Mac/Linux: Latest 2.x.x versions (Supported, feedback welcome)
>
> Please check your Cursor version before using this tool.

---

## 🚀 Quick Start

### One-Click Solution

<details open>
<summary><b>Global Users</b></summary>

**macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_mac_id_modifier.sh -o ./cursor_mac_id_modifier.sh && sudo bash ./cursor_mac_id_modifier.sh && rm ./cursor_mac_id_modifier.sh
```

**Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_linux_id_modifier.sh | sudo bash 
```

> **Note for Linux users:** The script attempts to find your Cursor installation by checking common paths (`/usr/bin`, `/usr/local/bin`, `$HOME/.local/bin`, `/opt/cursor`, `/snap/bin`), using the `which cursor` command, and searching within `/usr`, `/opt`, and `$HOME/.local`. If Cursor is installed elsewhere or not found via these methods, the script may fail. Ensure Cursor is accessible via one of these standard locations or methods.

**Windows**

```powershell
irm https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_win_id_modifier.ps1 | iex
```

**Tip (Windows):** If you suspect a cached old script (mirror/proxy cache), append a timestamp query parameter to bypass cache:

```powershell
irm "https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_win_id_modifier.ps1?$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

</details>

<details open>
<summary><b>China Users (Recommended)</b></summary>

**macOS**

```bash
curl -fsSL https://wget.la/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_mac_id_modifier.sh -o ./cursor_mac_id_modifier.sh && sudo bash ./cursor_mac_id_modifier.sh && rm ./cursor_mac_id_modifier.sh
```

**Linux**

```bash
curl -fsSL https://wget.la/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_linux_id_modifier.sh | sudo bash
```

**Windows**

```powershell
irm https://wget.la/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_win_id_modifier.ps1 | iex
```

**Tip (Windows):** If the mirror caches old content, append `?$(Get-Date -Format yyyyMMddHHmmss)` to the URL:

```powershell
irm "https://wget.la/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_win_id_modifier.ps1?$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

</details>

<div align="center">
<img src="img/run_success.png" alt="Run Success" width="600"/>
</div>

---

## 🖥️ Platform Guides

### Windows

<details>
<summary><b>How to Open Administrator Terminal</b></summary>

#### Method 1: Using Win + X Shortcut
```
1. Press Win + X key combination
2. Select one of these options from the menu:
   - "Windows PowerShell (Administrator)"
   - "Windows Terminal (Administrator)"
   - "Terminal (Administrator)"
   (Options may vary depending on Windows version)
```

#### Method 2: Using Win + R Run Command
```
1. Press Win + R key combination
2. Type powershell or pwsh in the Run dialog
3. Press Ctrl + Shift + Enter to run as administrator
   or type in the opened window: Start-Process pwsh -Verb RunAs
4. Enter the reset script in the administrator terminal:

irm https://wget.la/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/run/cursor_win_id_modifier.ps1 | iex
```

#### Method 3: Using Search
>![Search PowerShell](img/pwsh_1.png)
>
>Type pwsh in the search box, right-click and select "Run as administrator"
>![Run as Administrator](img/pwsh_2.png)

</details>

<details>
<summary><b>PowerShell Installation Guide</b></summary>

If PowerShell is not installed on your system:

**Method 1: Install via Winget (Recommended)**
```powershell
winget install --id Microsoft.PowerShell --source winget
```

**Method 2: Manual Installation**
1. Download the installer for your system:
   - [PowerShell-7.4.6-win-x64.msi](https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi) (64-bit)
   - [PowerShell-7.4.6-win-x86.msi](https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x86.msi) (32-bit)
   - [PowerShell-7.4.6-win-arm64.msi](https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-arm64.msi) (ARM64)

2. Run the installer and follow the prompts

> 💡 [Microsoft Official Installation Guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)

</details>

**Windows Features:**
- 🔍 Automatically detects and uses PowerShell 7 if available
- 🛡️ Requests administrator privileges via UAC prompt
- 📝 Falls back to Windows PowerShell if PS7 isn't found
- 💡 Provides manual instructions if elevation fails

---

## 📦 Manual Installation

Download the appropriate file for your system from [releases](https://github.com/Naster17/go-cursor-help-en/releases/latest)

<details>
<summary>Windows Packages</summary>

- 64-bit: `cursor-id-modifier_windows_x64.exe`
- 32-bit: `cursor-id-modifier_windows_x86.exe`
</details>

<details>
<summary>macOS Packages</summary>

- Intel: `cursor-id-modifier_darwin_x64_intel`
- M1/M2: `cursor-id-modifier_darwin_arm64_apple_silicon`
</details>

<details>
<summary>Linux Packages</summary>

- 64-bit: `cursor-id-modifier_linux_x64`
- 32-bit: `cursor-id-modifier_linux_x86`
- ARM64: `cursor-id-modifier_linux_arm64`
</details>

---

## 🔧 Technical Details

<details>
<summary><b>Configuration Files</b></summary>

The program modifies Cursor's `storage.json` config file located at:

- Windows: `%APPDATA%\Cursor\User\globalStorage\storage.json`
- macOS: `~/Library/Application Support/Cursor/User/globalStorage/storage.json`
- Linux: `~/.config/Cursor/User/globalStorage/storage.json`
</details>

<details>
<summary><b>Modified Fields</b></summary>

The tool generates new unique identifiers for:

- `telemetry.machineId`
- `telemetry.macMachineId`
- `telemetry.devDeviceId`
- `telemetry.sqmId`
</details>

<details>
<summary><b>Manual Auto-Update Disable</b></summary>

Windows users can manually disable the auto-update feature:

1. Close all Cursor processes
2. Delete directory: `C:\Users\username\AppData\Local\cursor-updater`
3. Create a file with the same name: `cursor-updater` (without extension)

macOS/Linux users can try to locate similar `cursor-updater` directory in their system and perform the same operation.

</details>

<details>
<summary><b>Safety Features</b></summary>

- ✅ Safe process termination
- ✅ Atomic file operations
- ✅ Error handling and recovery
</details>

<details>
<summary><b>Registry Modification Notice (Windows)</b></summary>

> ⚠️ **Important: This tool modifies the Windows Registry**

**Modified Registry:**
- Path: `Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography`
- Key: `MachineGuid`

**Potential Impact:**
Modifying this registry key may affect:
- Windows system's unique device identification
- Device recognition and authorization status of certain software
- System features based on hardware identification

**Safety Measures:**
1. Automatic Backup
   - Original value is automatically backed up before modification
   - Backup location: `%APPDATA%\Cursor\User\globalStorage\backups`
   - Backup file format: `MachineGuid.backup_YYYYMMDD_HHMMSS`

2. Manual Recovery Steps
   - Open Registry Editor (regedit)
   - Navigate to: `Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography`
   - Right-click on `MachineGuid`
   - Select "Modify"
   - Paste the value from backup file

**Important Notes:**
- Verify backup file existence before modification
- Use backup file to restore original value if needed
- Administrator privileges required for registry modification
</details>

---

## 💬 Feedback & Support

We value your feedback! If you've tried the tool, please share your experience:

- 🐛 **Bug Reports**: Found any issues? Let us know!
- 💡 **Feature Suggestions**: Have ideas for improvements?
- ⭐ **Success Stories**: Share how the tool helped you!

Feel free to [open an issue](https://github.com/Naster17/go-cursor-help-en/issues) or contribute to the project!

---

## ⭐ Project Stats

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=Naster17/go-cursor-help-en&type=Date)](https://star-history.com/#Naster17/go-cursor-help-en&Date)

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/ddaa9df9a94b0029ec3fad399e1c1c4e75755477.svg "Repobeats analytics image")

</div>

---

## 📄 License

[MIT License](LICENSE) - Copyright (c) 2024

</details>
