# ===========================================================================
# SCWebManager 一键安装脚本（Windows）
#
#   irm https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/install.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# 参数（可单独或组合使用；不传参数时保持原有交互安装体验）：
#   -f        静默安装：不询问任何问题，使用默认值，最后只输出一条结果
#   -json     最终只输出一行标准 JSON（ok/version/installDir/panelUrl/osOk/error）
#   -1 <答案> 预填第 1 个问题的答案（安装目录）
#   -2 <答案> 预填第 2 个问题的答案（版本号：latest 或具体版本）
#   -3 <答案> 预填第 3 个问题的答案（系统版本过低时是否强制安装：y/n）
#   -h        显示帮助
#
# 没有 PowerShell 的机器可手动安装：
#   1) 打开 https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/versions.json
#   2) 按本机架构找到目标版本的 "windows_amd64" 或 "windows_arm64" 下载直链，保存 zip
#   3) 解压到任意目录（例如 %LOCALAPPDATA%\SCWebManager），保留已有 data 目录
#   4) 先运行 scweb-daemon.exe -dir <安装目录>\data，再运行 scweb-panel.exe
#   5) 浏览器访问 http://127.0.0.1:18233
# ===========================================================================

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------------------------- 参数解析 ----------------------------
#   -f      静默安装：不询问任何问题，全部使用默认值，最后只输出一条结果
#   -json   最终输出标准 JSON（字段：ok/version/installDir/panelUrl/osOk/error），
#           可被程序解析（同时抑制人类可读输出）
#   -1 <答案> -2 <答案> ...  按顺序预填交互问题的答案（可与 -f/-json 组合）
#   问题顺序：1=安装目录，2=版本号（latest 或具体版本），3=系统版本过低时是否强制安装(y/n)
$script:OptSilent = $false
$script:OptJson = $false
$script:OptHelp = $false
$script:Prefill = @()
try {
    for ($script:ArgI = 0; $script:ArgI -lt $args.Count; $script:ArgI++) {
        $a = [string]$args[$script:ArgI]
        if ($a -match '^-(\d+)$') {
            $idx = [int]$Matches[1]
            if ($idx -ge 1 -and ($script:ArgI + 1) -lt $args.Count) {
                while ($script:Prefill.Count -lt $idx) { $script:Prefill += "" }
                $script:Prefill[$idx - 1] = [string]$args[$script:ArgI + 1]
                $script:ArgI++
            }
        } elseif ($a -ieq '-f' -or $a -ieq '-silent') {
            $script:OptSilent = $true
        } elseif ($a -ieq '-json') {
            $script:OptJson = $true
        } elseif ($a -ieq '-h' -or $a -ieq '-help' -or $a -ieq '--help' -or $a -ieq '/?') {
            $script:OptHelp = $true
        }
    }
} catch { }
Remove-Variable -Name ArgI -ErrorAction SilentlyContinue

# 读取第 idx 个交互问题的预填答案（无则返回空串）
function Get-Prefill([int]$idx) {
    $k = $idx - 1
    if ($k -ge 0 -and $k -lt $script:Prefill.Count) { return ([string]$script:Prefill[$k]).Trim() }
    return ""
}

# 最终 JSON 结果（-json 模式）
function Write-JsonResult([bool]$okFlag, [string]$err) {
    $obj = [ordered]@{
        ok         = $okFlag
        version    = [string]$script:ResultVersion
        installDir = [string]$script:InstallDir
        panelUrl   = [string]$script:PanelUrl
        osOk       = (-not $script:OsLow)
        error      = [string]$err
    }
    try {
        [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
    } catch {
        [Console]::Out.WriteLine('{"ok":false,"error":"json output failed"}')
    }
}

$script:Root = ""
try { if ($PSScriptRoot) { $script:Root = $PSScriptRoot } } catch { }

$script:VersionsUrl = "https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/versions.json"
$script:DefaultPort = 18233
$script:MinDiskMB = 300
# 当前机器对应的安装包架构后缀（amd64 / arm64），由 Get-ArchKind 探测；
# 版本清单里优先取 "windows_<arch>"，amd64 机器还可回退到旧的 "windows" 字段。
$script:ArchKind = ""

$script:InstallDir = ""
$script:PanelUrl = ""
$script:PanelProc = $null
$script:DaemonProc = $null
$script:RuntimePid = 0
# 安装过程中产生的临时文件路径：成功启动或安装器退出前才清理，失败时保留现场
$script:TmpPaths = @()

# 静默/JSON 模式下抑制所有人类可读输出，只在最后输出一条结果
$script:Mute = ($script:OptSilent -or $script:OptJson)
# 系统版本过低（不是硬性失败，可 -3 y 强制安装）
$script:OsLow = $false
$script:OsLowMsg = ""
# 最终结果（-json / -f 输出用）
$script:ResultVersion = ""
$script:FailMsg = ""

# ---------------------------- 输出工具 ----------------------------

function Write-Banner {
    if ($script:Mute) { return }
    $art = @'
+------------------------------------------------------------------+
|                                                                  |
|   _  _ ___ ___ _      ___      ___      __      _                |
|  | || |_ _|_ _| |    / __|_ __/ __|_ __/ /_  __| | __ _  _ _      |
|  | || || || || |__  \__ \ '_ \__ \ '_ \/ _ \/ _` |/ _` || '_|    |
|  |_||_||_||_||____| |___/ .__/___/ .__/\___/\__,_|\__,_||_|      |
|                         |_|     |_|                             |
|                                                                  |
|          S C W E B  M A N A G E R   /   Installer                |
+------------------------------------------------------------------+
'@
    Write-Host $art -ForegroundColor Cyan
    Write-Host "  安装脚本 / Installer" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step($text) {
    if ($script:Mute) { return }
    Write-Host ""
    Write-Host "* $text" -ForegroundColor Cyan
}

function Write-Ok($text) {
    if ($script:Mute) { return }
    Write-Host "  ✔ $text" -ForegroundColor Green
}

function Write-Bad($text) {
    if ($script:Mute) { return }
    Write-Host "  ✘ $text" -ForegroundColor Red
}

function Write-Note($text) {
    if ($script:Mute) { return }
    Write-Host "  ! $text" -ForegroundColor Yellow
}

function Write-Sep {
    if ($script:Mute) { return }
    Write-Host ("=" * 64) -ForegroundColor Green
}

# 普通行输出（静默/JSON 模式下静默）
function Write-Line($text, $color) {
    if ($script:Mute) { return }
    if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
}

# 读取交互输入：stdin 被重定向（管道/无控制台）时用 Console.In，
# 到达 EOF 返回 $null。所有调用方必须把 $null 当作「中止/取消」，
# 绝不能把空输入当成默认值继续循环（否则无控制台时菜单会无限循环刷日志）。
function Read-Answer([string]$prompt) {
    try {
        if ([Console]::IsInputRedirected) {
            if ($prompt -and -not $script:Mute) { Write-Host $prompt -NoNewline }
            $line = [Console]::In.ReadLine()
            if ($null -eq $line) { return $null }
            return [string]$line
        }
        $a = Read-Host $prompt
        if ($null -eq $a) { return $null }
        return [string]$a
    } catch {
        return $null
    }
}

# 没有 PowerShell 的机器如何手动安装（失败时提示）
function Write-ManualHint {
    if ($script:Mute) { return }
    Write-Host ""
    Write-Host "  手动安装（无需 PowerShell）：" -ForegroundColor Yellow
    Write-Host "    1) 打开 $script:VersionsUrl ，按本机架构找到目标版本的 windows_amd64 或 windows_arm64 下载直链"
    Write-Host "    2) 下载 zip 后解压到目标目录（保留已有的 data 目录，避免丢配置）"
    Write-Host "    3) 先运行 scweb-daemon.exe -dir <安装目录>\data，再运行 scweb-panel.exe"
    Write-Host "    4) 浏览器访问 http://127.0.0.1:18233"
}

# -------------------- 安装标识记录（Windows 注册表） --------------------
# 仅用于标识「这台机器装过 SCWebManager、初始装的是哪个版本」，供安装器识别；
# 面板自身的更新不会改写这里，因此这里的版本永远是最初安装的版本。

$script:RegRoot = "HKCU:\Software\SCWebManager"

# 目录 -> 固定 id（同一目录多次安装会落到同一个记录）
function Get-InstallId([string]$dir) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($dir.ToLowerInvariant())
    $hex = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', ''
    $sha.Dispose()
    return $hex.Substring(0, 12)
}

# 读取本机已有的安装记录
function Get-InstallRecords {
    $out = @()
    try {
        $key = Join-Path $script:RegRoot "Installs"
        if (Test-Path $key) {
            Get-ChildItem -Path $key -ErrorAction Stop | ForEach-Object {
                $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.Dir) {
                    $v = [string]$p.Version
                    if ([string]::IsNullOrWhiteSpace($v)) { $v = [string]$p.InitialVersion }
                    $out += [pscustomobject]@{
                        Dir         = [string]$p.Dir
                        Version     = $v
                        InstalledAt = [string]$p.InstalledAt
                    }
                }
            }
        }
    } catch { }
    # 旧版可能残留多条记录，按安装时间倒序，后续只用第一条。
    return ($out | Sort-Object InstalledAt -Descending)
}

# 选择目录前提示已有安装（一台机器只允许一套，安装到别的目录会被拒绝）
function Write-InstallRecordHint {
    if ($script:Mute) { return }
    $list = @(Get-InstallRecords)
    if ($list.Count -eq 0) { return }
    $it = $list[0]
    $ver = $it.Version
    if ([string]::IsNullOrWhiteSpace($ver)) { $ver = "未知" }
    Write-Note "本机已安装 SCWebManager：$($it.Dir)（初始版本 $ver）"
    Write-Note "一台机器只允许一套；如需升级请使用该目录，或先卸载再重装。"
}

# 目录比较（Windows 路径大小写不敏感，忽略结尾反斜杠）
function Test-SameDir([string]$a, [string]$b) {
    if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $false }
    return ($a.TrimEnd([char]92) -ieq $b.TrimEnd([char]92))
}

# 安装成功后写入记录（同一目录重复安装时保留最初的版本号）
function Write-InstallRecord([string]$dir, [string]$version) {
    try {
        if (-not (Test-Path $script:RegRoot)) {
            New-Item -Path $script:RegRoot -Force | Out-Null
        }
        # 只保留本次目录这一条记录，清掉旧版多实例残留。
        $installs = Join-Path $script:RegRoot "Installs"
        $mine = Get-InstallId $dir
        if (Test-Path $installs) {
            Get-ChildItem -Path $installs -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -ne $mine } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        $key = Join-Path $script:RegRoot ("Installs\" + $mine)
        $exists = Test-Path $key
        if (-not $exists) {
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name "Dir" -Value $dir
            Set-ItemProperty -Path $key -Name "Version" -Value $version
            Set-ItemProperty -Path $key -Name "InitialVersion" -Value $version
            Set-ItemProperty -Path $key -Name "InstalledAt" -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            Set-ItemProperty -Path $key -Name "Arch" -Value ("windows-" + (Get-ArchKind))
        } else {
            Set-ItemProperty -Path $key -Name "Dir" -Value $dir
            Set-ItemProperty -Path $key -Name "Version" -Value $version
        }
    } catch {
        Write-Note "写入安装记录失败（不影响使用）：$($_.Exception.Message)"
    }
}

# -------------------- 维护程序（scweb-manage） --------------------
# 全机只安装一份：固定放在 %LOCALAPPDATA%\SCWebManager\scweb-manage.exe，
# 并在桌面与开始菜单注册快捷方式；注册信息写在 HKCU\Software\SCWebManager\Maintenance
# （Path / Version / InstalledAt）。面板本体可以在多个目录各装一份，但维护程序只有一份。

$script:MaintainDir = Join-Path $env:LOCALAPPDATA "SCWebManager"
$script:MaintainExe = Join-Path $script:MaintainDir "scweb-manage.exe"

function Get-MaintainerVersion {
    try {
        $k = Join-Path $script:RegRoot "Maintenance"
        if (Test-Path $k) {
            $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
            if ($p -and $p.Version) { return [string]$p.Version }
        }
    } catch { }
    return ""
}

# 在桌面与开始菜单创建快捷方式（重复执行会覆盖同名快捷方式）
function Register-MaintainerShortcut {
    try {
        if (-not (Test-Path -LiteralPath $script:MaintainExe)) { return }
        $ws = New-Object -ComObject WScript.Shell
        $desktop = ""
        try { $desktop = [Environment]::GetFolderPath("Desktop") } catch { }
        $programs = ""
        try { $programs = [Environment]::GetFolderPath("Programs") } catch { }

        $targets = @()
        if (-not [string]::IsNullOrWhiteSpace($desktop)) {
            $targets += (Join-Path $desktop "SCWebManager 维护工具.lnk")
        }
        if (-not [string]::IsNullOrWhiteSpace($programs)) {
            $smDir = Join-Path $programs "SCWebManager"
            try { New-Item -ItemType Directory -Force -Path $smDir | Out-Null } catch { }
            $targets += (Join-Path $smDir "SCWebManager 维护工具.lnk")
        }
        foreach ($lnk in $targets) {
            try {
                $sc = $ws.CreateShortcut($lnk)
                $sc.TargetPath = $script:MaintainExe
                $sc.WorkingDirectory = $script:MaintainDir
                $sc.Description = "SCWebManager 面板维护工具（启动/修复/更新/卸载/别名）"
                $sc.Save()
            } catch { }
        }
    } catch { }
}

# 安装/更新维护程序（失败只提示，不影响面板安装）
function Install-Maintainer($entry) {
    try {
        $archKind = Get-ArchKind
        if ([string]::IsNullOrWhiteSpace($archKind)) { return }
        $ver = [string]$entry.version
        $url = Get-EntryField $entry ("manage_windows_" + $archKind)
        $sha = Get-EntryField $entry ("manage_windows_" + $archKind + "_sha256")

        # 已存在且版本一致：只补建快捷方式，不重复下载
        if ((Test-Path -LiteralPath $script:MaintainExe) -and ((Get-MaintainerVersion) -eq $ver)) {
            Register-MaintainerShortcut
            return
        }
        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-Note "该版本未提供维护程序，跳过安装（不影响面板使用）。"
            return
        }

        Write-Step "安装维护程序"
        New-Item -ItemType Directory -Force -Path $script:MaintainDir | Out-Null
        $tmp = Join-Path $env:TEMP ("scweb-manage-" + [guid]::NewGuid().ToString("N") + ".exe")
        $script:TmpPaths += $tmp
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        } catch {
            Write-Note "维护程序下载失败（不影响面板使用）：$($_.Exception.Message)"
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($sha)) {
            try {
                $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
                if ($got -ne $sha.Trim().ToLower()) {
                    Write-Note "维护程序校验失败（SHA256 不一致），已跳过。"
                    return
                }
            } catch { }
        }
        Copy-Item -LiteralPath $tmp -Destination $script:MaintainExe -Force
        try { Unblock-File -LiteralPath $script:MaintainExe -ErrorAction SilentlyContinue } catch { }

        if (-not (Test-Path $script:RegRoot)) { New-Item -Path $script:RegRoot -Force | Out-Null }
        $mk = Join-Path $script:RegRoot "Maintenance"
        New-Item -Path $mk -Force | Out-Null
        Set-ItemProperty -Path $mk -Name "Path" -Value $script:MaintainExe
        Set-ItemProperty -Path $mk -Name "Version" -Value $ver
        Set-ItemProperty -Path $mk -Name "InstalledAt" -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")

        Register-MaintainerShortcut
        Write-Ok "维护程序已安装：$script:MaintainExe（桌面与开始菜单已创建快捷方式）"
    } catch {
        Write-Note "维护程序安装出错（不影响面板使用）：$($_.Exception.Message)"
    }
}

# -h 帮助
function Write-Usage {
    Write-Host ""
    Write-Host "SCWebManager 安装脚本" -ForegroundColor Cyan
    Write-Host "  powershell -ExecutionPolicy Bypass -File install.ps1 [-f] [-json] [-1 目录] [-2 版本]"
    Write-Host ""
    Write-Host "  -f        静默安装：不询问，全部用默认值，最后只输出一条结果"
    Write-Host "  -json     最终只输出一行标准 JSON（ok/version/installDir/panelUrl/osOk/error）"
    Write-Host "  -1 <答案> 预填第 1 个问题：安装目录"
    Write-Host "  -2 <答案> 预填第 2 个问题：版本号（latest 或具体版本）"
    Write-Host "  -3 <答案> 兼容保留（Windows 版要求 Windows 10 / Server 2016 及以上，不再询问是否强制安装）"
    Write-Host "  -h        显示本帮助"
    Write-Host ""
}

# ---------------------------- 环境检查 ----------------------------

# 探测安装包架构后缀：amd64（x64）/ arm64；无法识别返回空串。
# 32 位 PowerShell 在 64 位系统上 PROCESSOR_ARCHITECTURE 为 x86，需用 ARCHITEW6432 修正。
function Get-ArchKind {
    if ($script:ArchKind) { return $script:ArchKind }
    $v = ""
    try {
        $v = "$env:PROCESSOR_ARCHITECTURE"
        if ($env:PROCESSOR_ARCHITEW6432) { $v = "$env:PROCESSOR_ARCHITEW6432" }
    } catch { }
    switch ($v.ToUpper()) {
        "AMD64" { $script:ArchKind = "amd64" }
        "ARM64" { $script:ArchKind = "arm64" }
        default { $script:ArchKind = "" }
    }
    return $script:ArchKind
}

# 读取版本条目里的字段（不存在时返回空串）
function Get-EntryField($entry, $name) {
    if (-not $entry) { return "" }
    try {
        $p = $entry.PSObject.Properties[$name]
        if ($p) { return [string]$p.Value }
    } catch { }
    return ""
}

function Test-Environment {
    Write-Step "运行环境检查"
    $ok = $true

    # Windows 版本门槛：面板二进制基于 Go 1.27，最低只支持 Windows 10 / Windows Server 2016。
    # 低于该版本的系统无法运行面板，因此直接判定环境不通过（不再提供强制安装选项）。
    $script:OsLow = $false
    $script:OsLowMsg = ""
    try {
        $osMajor = 0
        $osMinor = 0
        $osCaption = ""
        try {
            $wos = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $osCaption = ([string]$wos.Caption).Trim()
            $vparts = @(([string]$wos.Version) -split '\.')
            if ($vparts.Count -ge 1) { $osMajor = [int]$vparts[0] }
            if ($vparts.Count -ge 2) { $osMinor = [int]$vparts[1] }
        } catch {
            # 没有 CIM 时退回 .NET 版本号
            $v = [Environment]::OSVersion.Version
            $osMajor = $v.Major
            $osMinor = $v.Minor
        }

        $verTxt = "$osMajor.$osMinor"
        $osDesc = ""
        if ($osCaption) { $osDesc = "（$osCaption）" }
        if ($osMajor -ge 10) {
            Write-Ok "Windows 版本 $verTxt$osDesc"
        } else {
            Write-Bad "操作系统版本过低（当前 $verTxt$osDesc；要求 Windows 10 或 Windows Server 2016 及以上），面板无法在该系统上运行"
            $ok = $false
        }
    } catch {
        Write-Bad "无法识别操作系统版本：$($_.Exception.Message)"
        $ok = $false
    }

    # CPU 架构（32 位 PowerShell 在 64 位系统上会报告 x86，需用 ARCHITEW6432 修正）
    try {
        $arch = "$env:PROCESSOR_ARCHITECTURE"
        if ($env:PROCESSOR_ARCHITEW6432) { $arch = "$env:PROCESSOR_ARCHITEW6432" }
        if ($arch -eq "AMD64" -or $arch -eq "ARM64") {
            $script:ArchKind = Get-ArchKind
            Write-Ok "CPU 架构 $arch（安装包架构 $script:ArchKind）"
        } else {
            Write-Bad "CPU 架构 $arch 不受支持（仅提供 x64 / arm64 构建）"
            $ok = $false
        }
    } catch {
        Write-Bad "无法识别 CPU 架构"
        $ok = $false
    }

    # PowerShell 版本
    try {
        $psv = $PSVersionTable.PSVersion
        if ($psv.Major -gt 5 -or ($psv.Major -eq 5 -and $psv.Minor -ge 1)) {
            Write-Ok "PowerShell 版本 $psv"
        } else {
            Write-Bad "PowerShell 版本 $psv 过低（要求 5.1 以上）"
            $ok = $false
        }
    } catch {
        Write-Bad "无法识别 PowerShell 版本"
        $ok = $false
    }

    # TLS 1.2
    try {
        $tp = [Net.ServicePointManager]::SecurityProtocol
        if (-not ($tp -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol = $tp -bor [Net.SecurityProtocolType]::Tls12
        }
        Write-Ok "TLS 1.2 已启用"
    } catch {
        Write-Bad "无法启用 TLS 1.2（下载可能失败）：$($_.Exception.Message)"
    }

    # 可用磁盘
    try {
        $freeMb = 0
        $probe = "$env:LOCALAPPDATA"
        if (-not $probe) { $probe = $env:USERPROFILE }
        $rootPath = [System.IO.Path]::GetPathRoot($probe)
        $di = New-Object System.IO.DriveInfo($rootPath)
        $freeMb = [math]::Round($di.AvailableFreeSpace / 1MB)
        if ($freeMb -ge $script:MinDiskMB) {
            Write-Ok "可用磁盘 $freeMb MB（要求 $($script:MinDiskMB) MB）"
        } else {
            Write-Bad "可用磁盘 $freeMb MB，不足 $($script:MinDiskMB) MB"
            $ok = $false
        }
    } catch {
        Write-Bad "无法读取磁盘剩余空间：$($_.Exception.Message)"
        $ok = $false
    }

    # 管理员
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            Write-Ok "当前以管理员身份运行"
        } else {
            Write-Note "当前非管理员权限；安装到用户目录（LOCALAPPDATA）无需管理员"
        }
    } catch {
        Write-Note "无法判断管理员权限"
    }

    return $ok
}

# -------------------------- 安装目录选择 --------------------------

# 规范化用户输入的目录：去空白、去引号、展开环境变量、去尾部反斜杠
function Format-InstallDir([string]$p) {
    $p = "$p".Trim()
    $p = $p.Trim([char]'"', [char]39)
    $p = [Environment]::ExpandEnvironmentVariables($p)
    return $p.TrimEnd([char]92)
}

# 目录是否可用：必须是根路径；已存在时必须是目录；不存在时其父目录必须存在
function Test-InstallDirPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    try {
        if (-not [System.IO.Path]::IsPathRooted($p)) { return $false }
        if (Test-Path -LiteralPath $p) {
            return (Test-Path -LiteralPath $p -PathType Container)
        }
        $parent = Split-Path -Parent $p
        if ([string]::IsNullOrWhiteSpace($parent)) { return $false }
        return (Test-Path -LiteralPath $parent -PathType Container)
    } catch {
        return $false
    }
}

function Select-InstallDir {
    $default = Join-Path $env:LOCALAPPDATA "SCWebManager"
    Write-Step "选择安装目录"

    # 预填（-1 <目录>）优先；静默模式下没有预填则自动选择「真正在运行的那套」：
    #   1) 优先正在运行的面板所在目录（保证覆盖的就是当前在用的程序文件）；
    #   2) 其次使用安装记录里的目录；
    #   3) 都没有才用默认目录。
    # 旧逻辑无条件用默认目录，若正在运行的是另一目录（例如手动解压/开发构建），
    # 会把新版装到别处，用户刷新浏览器看到的仍是旧面板。
    $pre = Get-Prefill 1
    if ([string]::IsNullOrWhiteSpace($pre) -and $script:OptSilent) {
        $runningDir = Get-RunningPanelDir
        if (-not [string]::IsNullOrWhiteSpace($runningDir)) {
            Write-Line "  检测到正在运行的面板：$runningDir（静默模式直接覆盖该目录）"
            return (Format-InstallDir $runningDir)
        }
        $records = @(Get-InstallRecords)
        if ($records.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$records[0].Dir) -and
            (Test-Path -LiteralPath ([string]$records[0].Dir) -PathType Container)) {
            Write-Line "  检测到已安装记录：$($records[0].Dir)（静默模式覆盖该目录）"
            return (Format-InstallDir ([string]$records[0].Dir))
        }
        $pre = $default
    }

    if (-not [string]::IsNullOrWhiteSpace($pre)) {
        $chosen = Format-InstallDir $pre
        Write-Line "  使用指定目录：$chosen"
        return $chosen
    }

    Write-InstallRecordHint

    $chosen = ""
    while ([string]::IsNullOrWhiteSpace($chosen)) {
        Write-Line ""
        Write-Line "  请在下列方式中选择安装目录："
        Write-Line "   1) 使用默认目录（$default）"
        Write-Line "   2) 手动输入目录"
        Write-Line "   3) 打开文件管理器选择目录"
        $a = Read-Answer "  请输入 1 / 2 / 3（直接回车 = 1）"
        if ($null -eq $a) {
            $script:FailMsg = "输入已结束（EOF），安装中止"
            return ""
        }
        $a = $a.Trim()
        switch ($a) {
            { $_ -eq "" -or $_ -eq "1" } {
                $chosen = $default
                Write-Line "  使用默认目录：$chosen" Green
            }
            "2" {
                $p = Read-Answer "  请输入安装目录的完整路径"
                if ($null -eq $p) {
                    $script:FailMsg = "输入已结束（EOF），安装中止"
                    return ""
                }
                $p = Format-InstallDir $p
                if (Test-InstallDirPath $p) {
                    $chosen = $p
                    Write-Line "  使用目录：$chosen" Green
                } else {
                    Write-Bad "路径无效：$p"
                    Write-Note "请重新选择（输入必须是以盘符开头的完整路径，且父目录存在）"
                }
            }
            "3" {
                $picked = Show-FolderPicker $default
                if ([string]::IsNullOrWhiteSpace($picked)) {
                    Write-Note "已取消文件管理器选择，请重新选择"
                } elseif (Test-InstallDirPath $picked) {
                    $chosen = Format-InstallDir $picked
                    Write-Line "  使用目录：$chosen" Green
                } else {
                    Write-Bad "所选路径不可用：$picked"
                }
            }
            default {
                Write-Bad "输入无效：$a"
                Write-Note "请输入 1、2 或 3，直接回车使用默认目录"
            }
        }
    }
    $chosen = $chosen.TrimEnd([char]92)
    return $chosen
}

# -------------------- 已安装 / 正在运行检测 --------------------

# 返回本机正在运行的面板的安装目录（从进程可执行文件路径推断），没有则返回空
function Get-RunningPanelDir {
    try {
        $proc = Get-Process -Name scweb-panel -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $path = $null
            try { $path = $proc.Path } catch { }
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                return (Split-Path -Parent $path)
            }
        }
    } catch { }
    return ""
}

# 该目录下的面板或守护进程是否正在运行（先看 runtime.json，再按可执行文件路径匹配）
function Test-InstallRunning([string]$dir) {
    $prefix = $dir.TrimEnd([char]92) + '\'
    # 面板运行时写的是 <安装目录>\data\runtime.json；旧版只查 <安装目录>\runtime.json，
    # 导致覆盖安装时检测不到运行中的进程，复制阶段才因文件占用失败。
    foreach ($rt in @((Join-Path $dir "data\runtime.json"), (Join-Path $dir "runtime.json"))) {
        if (-not (Test-Path -LiteralPath $rt)) { continue }
        try {
            $j = Get-Content -LiteralPath $rt -Raw -ErrorAction Stop | ConvertFrom-Json
            $rtPid = [int]$j.pid
            if ($rtPid -gt 0) {
                $proc = Get-Process -Id $rtPid -ErrorAction SilentlyContinue
                # 被强杀后 Get-Process -Id 仍可能短暂返回已退出对象（HasExited=true），
                # 必须确认进程名且未退出，否则会误判「仍在运行」而拒绝安装。
                if ($proc) {
                    try {
                        if (-not $proc.HasExited -and $proc.ProcessName -eq 'scweb-panel') { return $true }
                    } catch { }
                }
            }
        } catch { }
    }
    $found = $false
    try {
        Get-Process -Name scweb-panel, scweb-daemon -ErrorAction SilentlyContinue | ForEach-Object {
            $p = $null
            try { $p = $_.Path } catch { }
            if ($p) {
                if ($p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $found = $true }
            } else {
                # 某些环境下 Path 属性不可读（权限/进程来源不同），此时无法按路径判断，
                # 按「本机只允许一套」原则视为运行中，交给 Stop-PanelProcesses 结束。
                $found = $true
            }
        }
    } catch { }
    return $found
}

# 从安装记录里取该目录已安装的版本（取不到返回空）
function Get-ExistingVersion([string]$dir) {
    foreach ($it in @(Get-InstallRecords)) {
        if ([string]::IsNullOrWhiteSpace($it.Dir)) { continue }
        if ($it.Dir.TrimEnd([char]92) -ieq $dir.TrimEnd([char]92)) {
            if (-not [string]::IsNullOrWhiteSpace($it.Version)) { return [string]$it.Version }
        }
    }
    return ""
}

# 选定目录后处理两种情况：
#   1) 该目录的面板正在运行：必须终止后才能重新安装；
#   2) 该目录已有面板但未运行：确认覆盖安装（保留配置/数据）。
# 一台机器只允许一套，安装到记录之外的目录会被直接拒绝。
# 返回最终安装目录；返回 $null 表示用户取消。
function Resolve-InstallTarget([string]$dir) {
    while ($true) {
        # 一台机器只允许一套：记录里的目录与本次目标不同、且目标目录不是已有安装时，
        # 直接拒绝第二套安装（对已有目录执行覆盖安装仍然允许）。
        $records = @(Get-InstallRecords)
        if ($records.Count -gt 0 -and -not (Test-SameDir $records[0].Dir $dir)) {
            $recordExists = Test-Path -LiteralPath $records[0].Dir -PathType Container
            $targetIsInstall = Test-Path -LiteralPath (Join-Path $dir "scweb-panel.exe")
            if ($recordExists -and -not $targetIsInstall) {
                Write-Bad "本机已安装在 $($records[0].Dir)，一台机器只允许一套，请对那套执行升级或先卸载。"
                return $null
            }
            if (-not $recordExists) {
                # 记录目录已被删除：按全新安装继续，安装成功后记录会被覆盖。
                Write-Note "旧安装记录的目录已不存在（$($records[0].Dir)），按全新安装继续。"
            }
        }
        if (Test-InstallRunning $dir) {
            Write-Bad "检测到该目录下的 SCWebManager 正在运行：$dir"
            Write-Note "面板正在运行，必须先终止进程才能进行重新安装。"
            if ($script:Mute) {
                [void](Stop-PanelProcesses $dir)
                Write-Note "静默模式：已终止正在运行的进程"
            } else {
                Write-Line "   1) 终止正在运行的进程并继续安装"
                Write-Line "   0) 取消并退出安装器"
                $a = Read-Answer "  请输入 1 / 0（直接回车 = 0）"
                if ($null -eq $a) {
                    Write-Note "输入已结束（EOF），已取消安装。"
                    return $null
                }
                $a = $a.Trim()
                if ($a -eq "" -or $a -eq "0") {
                    Write-Note "已取消：请先通过维护工具或任务管理器停止面板后再安装。"
                    return $null
                }
                if ($a -ne "1") {
                    Write-Bad "输入无效：$a"
                    continue
                }
                $n = Stop-PanelProcesses $dir
                Write-Ok "已终止 $n 个进程"
                Start-Sleep -Milliseconds 600
                if (Test-InstallRunning $dir) {
                    Write-Bad "进程仍未退出，请稍后重试或手动结束进程后再安装。"
                    return $null
                }
            }
            # 用户已明确选择终止后重新安装，直接沿用该目录（覆盖安装）
            return $dir
        }

        $panelExe = Join-Path $dir "scweb-panel.exe"
        if (-not (Test-Path -LiteralPath $panelExe)) { return $dir }

        $ver = Get-ExistingVersion $dir
        if ([string]::IsNullOrWhiteSpace($ver)) { $ver = "未知" }
        Write-Bad "该目录下已存在 SCWebManager（版本 $ver）：$dir"
        if ($script:Mute) {
            Write-Note "静默模式：按覆盖安装继续（保留配置与数据）"
            return $dir
        }
        Write-Line "   1) 覆盖安装（修复当前实例：替换程序文件，保留配置与数据）"
        Write-Line "   0) 取消并退出安装器"
        $a = Read-Answer "  请输入 1 / 0（直接回车 = 1）"
        if ($null -eq $a) {
            Write-Note "输入已结束（EOF），已取消安装。"
            return $null
        }
        $a = $a.Trim()
        switch ($a) {
            { $_ -eq "" -or $_ -eq "1" } {
                Write-Line "  继续使用该目录（覆盖安装）" Green
                return $dir
            }
            "0" {
                Write-Note "已取消安装。"
                return $null
            }
            default {
                Write-Bad "输入无效：$a"
                Write-Note "请输入 1 或 0，直接回车执行覆盖安装"
            }
        }
    }
}

# 打开 Windows 文件管理器目录选择框；不可用或取消时返回空串
function Show-FolderPicker([string]$initial) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "请选择 SCWebManager 的安装目录"
        $dlg.SelectedPath = $initial
        $dlg.ShowNewFolderButton = $true
        $r = $dlg.ShowDialog()
        if ($r -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) {
            return $dlg.SelectedPath
        }
    } catch {
        Write-Note "当前环境无法打开文件管理器选择框（$($_.Exception.Message)）"
    }
    return ""
}


# ---------------------------- 版本列表 ----------------------------

function Get-VersionConfig {
    Write-Step "获取版本列表"

    $locals = @()
    if ($script:Root) { $locals += (Join-Path $script:Root "versions.json") }
    try { $locals += (Join-Path (Get-Location).Path "versions.json") } catch { }

    foreach ($p in $locals) {
        if (Test-Path -LiteralPath $p) {
            try {
                $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
                $cfg = $raw | ConvertFrom-Json
                if ($cfg -and $cfg.versions) {
                    Write-Ok "使用本地版本列表：$p"
                    return $cfg
                }
            } catch { }
        }
    }

    try {
        # 加时间戳绕过 Gitee raw 的 CDN 缓存，确保每次安装/升级都拿到最新版本清单与哈希
        $ts = [DateTime]::UtcNow.Ticks
        $resp = Invoke-WebRequest -Uri ($script:VersionsUrl + "?t=" + $ts) -UseBasicParsing -TimeoutSec 30
        $cfg = $resp.Content | ConvertFrom-Json
        if ($cfg -and $cfg.versions) {
            Write-Ok "已从仓库获取版本列表"
            return $cfg
        }
        Write-Bad "版本列表格式不正确"
    } catch {
        Write-Bad "无法获取版本列表：$($_.Exception.Message)"
    }
    return $null
}

function Get-SortedVersions($versions) {
    $list = @($versions)
    return ($list | Sort-Object -Property @{
            Expression = {
                $s = [string]$_.version
                $parts = @($s -split "[^0-9]+" | Where-Object { $_ -ne "" })
                $pad = @("0000", "0000", "0000", "0000")
                for ($i = 0; $i -lt [Math]::Min($parts.Count, 4); $i++) {
                    try { $pad[$i] = ([long]$parts[$i]).ToString("0000") } catch { }
                }
                return ($pad -join ".")
            }
        } -Descending)
}

function Confirm-Yes([string]$prompt) {
    if ([string]::IsNullOrWhiteSpace($prompt)) { $prompt = "是否立即开始安装？(y/n)" }
    while ($true) {
        $a = Read-Answer $prompt
        if ($null -eq $a) { return $false }
        switch ($a.Trim().ToLower()) {
            "y" { return $true }
            "n" { return $false }
        }
        Write-Host "  请输入 y 或 n" -ForegroundColor Yellow
    }
}

function Confirm-DefaultYes($prompt) {
    $a = Read-Answer $prompt
    if ($null -eq $a) { return $false }
    if ([string]::IsNullOrWhiteSpace($a)) { return $true }
    if ($a.Trim().ToLower() -eq "n") { return $false }
    return $true
}

function Select-Version($cfg) {
    $list = @(Get-SortedVersions $cfg.versions)

    $latest = [string]$cfg.latest
    if ([string]::IsNullOrWhiteSpace($latest) -and $list.Count -gt 0) { $latest = [string]$list[0].version }
    if ([string]::IsNullOrWhiteSpace($latest)) {
        $script:FailMsg = "版本列表为空"
        return $null
    }

    # 预填（-2 latest / -2 <版本号>）；静默模式没有预填则默认 latest
    $pre = Get-Prefill 2
    if ([string]::IsNullOrWhiteSpace($pre) -and $script:OptSilent) { $pre = "latest" }
    if (-not [string]::IsNullOrWhiteSpace($pre)) {
        if ($pre -ieq "latest" -or $pre -eq "1") {
            $entry = $list | Where-Object { [string]$_.version -eq $latest } | Select-Object -First 1
            if (-not $entry) {
                $script:FailMsg = "版本列表中找不到最新版本 $latest"
                return $null
            }
            Write-Line "  最新版本：$latest" Green
            Write-ReleaseChannel $latest
            return $entry
        }
        $entry = $list | Where-Object { [string]$_.version -eq $pre } | Select-Object -First 1
        if ($entry) { Write-ReleaseChannel ([string]$entry.version); return $entry }
        $script:FailMsg = "版本 $pre 不在版本列表中"
        return $null
    }

    Write-Step "选择安装版本"
    while ($true) {
        Write-Host "  1) 安装最新版本"
        Write-Host "  0) 手动输入版本号"
        Write-Host "  2) 列出全部版本"
        $c = Read-Answer "请选择 [1/0/2]"
        if ($null -eq $c) {
            $script:FailMsg = "输入已结束（EOF），安装中止"
            return $null
        }
        $c = $c.Trim()

        if ($c -eq "1") {
            $entry = $list | Where-Object { [string]$_.version -eq $latest } | Select-Object -First 1
            if (-not $entry) {
                Write-Bad "版本列表中找不到最新版本 $latest"
                continue
            }
            Write-Host "  最新版本：$latest" -ForegroundColor Green
            Write-ReleaseChannel $latest
            if (Confirm-Yes) { return $entry }
            continue
        } elseif ($c -eq "0") {
            while ($true) {
                $v = Read-Answer "请输入版本号（输入 0 返回菜单）"
                if ($null -eq $v) {
                    $script:FailMsg = "输入已结束（EOF），安装中止"
                    return $null
                }
                $v = $v.Trim()
                if ($v -eq "0") { break }
                $entry = $list | Where-Object { [string]$_.version -eq $v } | Select-Object -First 1
                if ($entry) { Write-ReleaseChannel $v; return $entry }
                Write-Bad "版本 $v 不在列表中，请重新输入"
            }
            continue
        } elseif ($c -eq "2") {
            Write-Host "  可用版本（新 → 旧）：" -ForegroundColor Cyan
            foreach ($e in $list) {
                $tag = ""
                if ([string]$e.version -eq $latest) { $tag = "   <- 最新" }
                Write-Host ("    " + [string]$e.version + $tag)
            }
            continue
        } else {
            Write-Host "  输入无效，请输入 1、0 或 2" -ForegroundColor Yellow
        }
    }
}

# 发行版渠道：Gitee 发布时可勾选「预览版（pre-release）」，这里查仓库的
# release 详情接口确认该版本是不是预览版。查不到（离线/接口限流/版本不存在）
# 就按正式版处理，静默跳过，不影响安装。
function Test-Prerelease([string]$ver) {
    if ([string]::IsNullOrWhiteSpace($ver)) { return $false }
    $api = "https://gitee.com/api/v5/repos/JIILStudio/jiilsc-web-manger/releases/tags/$ver"
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $api -TimeoutSec 10 -ErrorAction Stop
        if ($resp.StatusCode -ne 200) { return $false }
        return [bool]($resp.Content | ConvertFrom-Json).prerelease
    } catch { return $false }
}

# 预览版提示（正式版不输出任何内容）
function Write-ReleaseChannel([string]$ver) {
    if (-not (Test-Prerelease $ver)) { return }
    Write-Line ""
    Write-Line "  ! 当前版本 $ver 为预览版（pre-release）" Yellow
    Write-Line "    预览版用于提前体验新功能，可能不稳定、功能缺失或出现数据异常。" Yellow
    Write-Line "    生产环境建议改用正式版：发布页中未标记「预览」的版本。" Yellow
    Write-Line ""
}

# ---------------------------- 下载安装 ----------------------------

function Install-FailResult($reason) { return [pscustomobject]@{ Ok = $false; Reason = $reason } }
function Install-OkResult { return [pscustomobject]@{ Ok = $true; Reason = "" } }

# 清理安装过程中产生的临时文件（只在安装成功或安装器退出前调用，
# 这样失败后仍能保留现场，便于排查或手动复用已下载的安装包）
function Clear-TmpPaths {
    foreach ($p in @($script:TmpPaths)) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    $script:TmpPaths = @()
}

# 安装一次（不含重试逻辑）：返回 @{ Ok = 布尔; Reason = 失败原因 }
function Invoke-InstallAttempt($entry, $dir) {
    Write-Step "下载并安装面板 $([string]$entry.version)"

    # 按本机架构选包：优先 windows_<arch> / windows_<arch>_sha256，
    # amd64 机器可回退到旧的 windows / windows_sha256 / sha256。
    $archKind = Get-ArchKind
    $url = ""
    $sha = ""
    if ($archKind) {
        $url = Get-EntryField $entry ("windows_" + $archKind)
        $sha = Get-EntryField $entry ("windows_" + $archKind + "_sha256")
    }
    if ([string]::IsNullOrWhiteSpace($url) -and $archKind -eq "amd64") {
        $url = Get-EntryField $entry "windows"
        $sha = Get-EntryField $entry "windows_sha256"
    }
    if ([string]::IsNullOrWhiteSpace($sha)) { $sha = Get-EntryField $entry "sha256" }

    if ([string]::IsNullOrWhiteSpace($url)) {
        if ($archKind) { return (Install-FailResult "该版本没有提供 Windows $archKind 安装包") }
        return (Install-FailResult "该版本没有提供 Windows 安装包")
    }

    $name = $url
    if ($name.Contains("?")) { $name = $name.Substring(0, $name.IndexOf("?")) }
    $name = $name.Substring($name.LastIndexOf("/") + 1)
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "scweb-$([string]$entry.version).zip" }
    $tmpFile = Join-Path $env:TEMP $name
    $stage = Join-Path $env:TEMP ("scweb-stage-" + [guid]::NewGuid().ToString("N"))
    $script:TmpPaths += $tmpFile
    $script:TmpPaths += $stage

    try {
        Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        Write-Line "  下载：$url"
        Invoke-WebRequest -Uri $url -OutFile $tmpFile -UseBasicParsing -TimeoutSec 180
    } catch {
        return (Install-FailResult "网络下载失败：$($_.Exception.Message)")
    }

    if (-not (Test-Path -LiteralPath $tmpFile)) {
        return (Install-FailResult "下载后未生成文件 $tmpFile（磁盘空间不足或本机安全策略拦截）")
    }
    Write-Ok "下载完成：$tmpFile"

    if (-not [string]::IsNullOrWhiteSpace($sha)) {
        try {
            $hash = (Get-FileHash -LiteralPath $tmpFile -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $sha.Trim().ToLower()) {
                return (Install-FailResult "下载文件不完整（SHA256 不一致，期望 $sha 实际 $hash），请重试")
            }
            Write-Ok "SHA256 校验通过"
        } catch {
            return (Install-FailResult "SHA256 校验出错：$($_.Exception.Message)")
        }
    }

    try {
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        Expand-Archive -LiteralPath $tmpFile -DestinationPath $stage -Force
    } catch {
        return (Install-FailResult "安装包解压失败（文件可能损坏或被拦截）：$($_.Exception.Message)")
    }

    # 覆盖安装前必须确保目标目录没有运行中的面板/守护进程，否则文件被占用，
    # Copy-Item 会失败（旧版忽略了该错误并继续打印「已安装」，实际文件没替换）。
    if (Test-InstallRunning $dir) {
        [void](Stop-PanelProcesses $dir)
        $stopped = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Milliseconds 200
            if (-not (Test-InstallRunning $dir)) { $stopped = $true; break }
        }
        if (-not $stopped) {
            [void](Stop-PanelProcesses $dir)
            Start-Sleep -Milliseconds 1000
        }
        if (Test-InstallRunning $dir) {
            return (Install-FailResult "安装目录下的 SCWebManager 仍在运行，请先停止后再安装")
        }
        Write-Note "已停止正在运行的 SCWebManager 进程，继续覆盖安装"
    }

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    try {
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
        $items = @(Get-ChildItem -LiteralPath $stage -Force)
        if ($items.Count -eq 0) {
            return (Install-FailResult "安装包内容为空")
        }
        foreach ($item in $items) {
            $dst = Join-Path $dir $item.Name
            if ($item.PSIsContainer) {
                if ($item.Name -ieq "data" -and (Test-Path -LiteralPath $dst)) {
                    Write-Note "保留已有用户数据目录：$dst"
                    continue
                }
                Copy-Item -LiteralPath $item.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
            } else {
                # 目标同名路径若已是目录，Copy-Item 会把文件复制进该目录并「假成功」，
                # 必须明确失败，避免安装器随后把目录当成可执行文件。
                if ((Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst -Force).PSIsContainer) {
                    throw "目标路径是目录，无法写入文件：$dst"
                }
                Copy-Item -LiteralPath $item.FullName -Destination $dst -Force -ErrorAction Stop
            }
        }
    } catch {
        return (Install-FailResult "写入安装目录失败（权限不足或文件被占用）：$($_.Exception.Message)")
    } finally {
        $ErrorActionPreference = $oldEap
    }

    try {
        Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    } catch { }

    # 关键自检：三个二进制必须都在。写入后消失基本只有一个原因——
    # 本机安全软件对未签名程序的启发式拦截。
    $missing = @()
    foreach ($n in @("scweb-panel.exe", "scweb-daemon.exe", "scweb-updater.exe")) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $n) -PathType Leaf)) { $missing += $n }
    }
    if ($missing.Count -gt 0) {
        return (Install-FailResult ("写入后被删除：$($missing -join '、')。这通常是本机安全软件对未签名程序的拦截，请先把 $dir 加入信任目录，然后重试安装"))
    }

    # 替换校验：逐个比对解压包与安装目录中文件的 SHA256。
    # 文件被占用/安全软件拦截时 Copy-Item 可能「看起来成功」但内容没变，
    # 旧版只打印「已安装」，用户刷新后仍是旧面板。这里必须逐字节确认已替换。
    $stageFiles = @(Get-ChildItem -LiteralPath $stage -File -Force -ErrorAction SilentlyContinue)
    foreach ($sf in $stageFiles) {
        $dst = Join-Path $dir $sf.Name
        $want = (Get-FileHash -LiteralPath $sf.FullName -Algorithm SHA256).Hash
        $got = ""
        try { $got = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash } catch { }
        if ($want -ne $got) {
            return (Install-FailResult "程序文件未替换成功：$($sf.Name)（目标目录文件被占用或被安全软件拦截，请停止面板/加信任后重试）")
        }
    }

    # 覆盖安装后强制重新登录：面板会把登录会话持久化到 data\sessions.json，
    # 不清除的话即使程序已替换，刷新浏览器仍然沿用旧会话，无法据此确认是否真的换了新程序。
    $sessions = Join-Path $dir "data\sessions.json"
    if (Test-Path -LiteralPath $sessions) {
        Remove-Item -LiteralPath $sessions -Force -ErrorAction SilentlyContinue
        Write-Note "已清除旧登录会话：覆盖安装完成后需要重新登录"
    }

    Write-Ok "已安装到 $dir"
    return (Install-OkResult)
}

# 安装（带重试）：失败时打印原因并询问是否重试（静默/JSON 模式直接返回失败）
function Install-Version($entry, $dir) {
    $attempt = 0
    while ($true) {
        $attempt++
        if ($attempt -gt 1) { Write-Note "重新尝试安装（第 $attempt 次）" }
        $r = Invoke-InstallAttempt $entry $dir
        if ($r.Ok) { return $true }
        Write-Bad "安装失败：$($r.Reason)"
        # 静默/JSON 模式不打印人类可读输出，但最终 JSON 必须带回真实失败原因，
        # 否则调用方只能看到笼统的「下载或写入失败」，无法定位/自动重试。
        if ($script:Mute) {
            $script:FailMsg = [string]$r.Reason
            return $false
        }
        if (-not (Confirm-Yes "是否重试安装？(y/n)")) {
            Write-Note "已放弃本次安装；可稍后手动下载安装包解压到 $dir"
            return $false
        }
    }
}


# ---------------------------- 进程控制 ----------------------------

function Stop-PanelProcesses($dir) {
    $count = 0

    # 优先按 runtime.json 里已验证存活的 pid 结束
    if ($script:RuntimePid -gt 0) {
        try {
            $proc = Get-Process -Id $script:RuntimePid -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $script:RuntimePid -Force -ErrorAction SilentlyContinue
                $count++
            }
        } catch { }
        $script:RuntimePid = 0
    }

    foreach ($p in @($script:PanelProc, $script:DaemonProc)) {
        if ($p) {
            try {
                if (-not $p.HasExited) {
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                    $count++
                }
            } catch { }
        }
    }
    $script:PanelProc = $null
    $script:DaemonProc = $null

    try {
        $prefix = $dir.TrimEnd('\') + '\'
        Get-Process -Name scweb-panel, scweb-daemon -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $null
            try { $path = $_.Path } catch { }
            # 路径可读时只结束本安装目录下的进程；路径不可读时（常见于提权/跨会话启动），
            # 按本机单套安装原则直接结束同名进程，避免残留进程占用 exe 导致复制失败。
            if (-not $path -or $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                $count++
            }
        }
    } catch { }
    return $count
}

# 读取并校验 data\runtime.json：
# 面板被强杀时 defer 不执行，文件会残留旧端口，因此必须同时满足
#   1) startedAt（RFC3339）距今不超过 5 分钟
#   2) pid 对应进程仍存活（且不是本安装器自己）
function Read-ValidRuntime($runtime) {
    if (-not (Test-Path -LiteralPath $runtime)) { return $null }

    try {
        $rt = (Get-Content -LiteralPath $runtime -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch { return $null }
    if (-not $rt -or -not $rt.port -or -not $rt.pid) { return $null }

    $rtPid = 0
    try { $rtPid = [int]$rt.pid } catch { return $null }
    if ($rtPid -le 0 -or $rtPid -eq $PID) { return $null }

    $alive = $false
    try {
        $alive = [bool](Get-Process -Id $rtPid -ErrorAction Stop)
    } catch { $alive = $false }
    if (-not $alive) { return $null }

    if ([string]::IsNullOrWhiteSpace([string]$rt.startedAt)) { return $null }
    try {
        $started = [DateTimeOffset]::Parse([string]$rt.startedAt, [Globalization.CultureInfo]::InvariantCulture)
        $age = ([DateTimeOffset]::UtcNow - $started.ToUniversalTime()).TotalSeconds
        if ($age -lt -30 -or $age -gt 300) { return $null }
    } catch { return $null }

    return $rt
}

function Get-FallbackPort($dir) {
    foreach ($cf in @((Join-Path $dir "data\config.json"), (Join-Path $dir "config.json"), (Join-Path $dir "run\config.json"))) {
        if (-not (Test-Path -LiteralPath $cf)) { continue }
        try {
            $raw = Get-Content -LiteralPath $cf -Raw -Encoding UTF8
            $cfg = $raw | ConvertFrom-Json
            if ($cfg.panel -and $cfg.panel.httpPort) { return [int]$cfg.panel.httpPort }
        } catch { }
    }
    return $script:DefaultPort
}

function Start-Panel($dir) {
    Write-Step "启动面板"

    $daemonExe = Join-Path $dir "scweb-daemon.exe"
    $panelExe = Join-Path $dir "scweb-panel.exe"
    if (-not (Test-Path -LiteralPath $daemonExe)) {
        Write-Bad "未找到 $daemonExe（文件在安装后消失，通常是本机安全软件拦截，请将该目录加入信任后重装）"
        return $false
    }
    if (-not (Test-Path -LiteralPath $panelExe)) {
        Write-Bad "未找到 $panelExe（文件在安装后消失，通常是本机安全软件拦截，请将该目录加入信任后重装）"
        return $false
    }

    $runtime = Join-Path $dir "data\runtime.json"
    Remove-Item -LiteralPath $runtime -Force -ErrorAction SilentlyContinue
    [void](Stop-PanelProcesses $dir)
    Start-Sleep -Milliseconds 600

    try {
        # -dir 必须是数据目录 <安装目录>\data：面板固定在该目录读写 config.json，
        # 传安装目录会让 daemon 另建一份配置（secret 不同），表现为「面板在线、守护进程离线」。
        $dataDir = Join-Path $dir "data"
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        $script:DaemonProc = Start-Process -FilePath $daemonExe `
            -ArgumentList @("-dir", ('"' + $dataDir + '"')) `
            -WorkingDirectory $dir -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $dir "daemon.log") `
            -RedirectStandardError (Join-Path $dir "daemon.err.log")
    } catch {
        Write-Bad "守护进程启动失败：$($_.Exception.Message)"
        return $false
    }
    Write-Ok "守护进程已启动（pid $($script:DaemonProc.Id)）"
    Start-Sleep -Seconds 2

    try {
        $script:PanelProc = Start-Process -FilePath $panelExe `
            -WorkingDirectory $dir -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $dir "panel.log") `
            -RedirectStandardError (Join-Path $dir "panel.err.log")
    } catch {
        Write-Bad "面板启动失败：$($_.Exception.Message)"
        return $false
    }
    Write-Ok "面板进程已启动（pid $($script:PanelProc.Id)）"

    $port = 0
    $bindHost = "127.0.0.1"
    for ($i = 0; $i -lt 40; $i++) {
        if ($script:PanelProc -and $script:PanelProc.HasExited) { break }
        $rt = Read-ValidRuntime $runtime
        if ($rt) {
            $port = [int]$rt.port
            if ($rt.bindHost) { $bindHost = [string]$rt.bindHost }
            try { $script:RuntimePid = [int]$rt.pid } catch { $script:RuntimePid = 0 }
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if ($port -le 0) {
        $port = Get-FallbackPort $dir
        Write-Note "runtime.json 无效或为上次运行残留（pid 不在运行 / startedAt 超时），回退使用配置端口 $port"
    } else {
        Write-Ok "已从 runtime.json 读取端口 $port（pid $($script:RuntimePid)）"
    }

    if ($bindHost -eq "0.0.0.0" -or $bindHost -eq "::" -or [string]::IsNullOrWhiteSpace($bindHost)) {
        $bindHost = "127.0.0.1"
    }
    if ($bindHost -eq "127.0.0.1" -or $bindHost -eq "localhost") {
        $script:PanelUrl = "http://127.0.0.1:$port"
    } else {
        $script:PanelUrl = "http://${bindHost}:$port"
    }

    try {
        if ($script:PanelProc.HasExited) {
            Write-Bad "面板进程提前退出，日志如下："
            if (-not $script:Mute) {
                Get-Content (Join-Path $dir "panel.err.log") -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
                $startupErr = Join-Path $dir "data\startup-error.log"
                if (Test-Path -LiteralPath $startupErr) {
                    Write-Note "启动错误记录（data\startup-error.log）："
                    Get-Content $startupErr -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
                }
            }
            return $false
        }
    } catch { }

    return $true
}

# 启动面板（带失败后的处理菜单）：返回 $true 表示最终启动成功。
# 失败时不直接退出安装器，用户可以修好问题后重试、或直接重装这个版本。
function Start-PanelWithRetry($dir, $entry) {
    while ($true) {
        if (Start-Panel $dir) { return $true }
        if ($script:Mute) { return $false }

        Write-Line ""
        Write-Line "  面板未启动成功。请选择下一步："
        Write-Line "   1) 重新尝试启动（例如已把安装目录加入本机安全软件的信任列表之后）"
        Write-Line "   2) 重新下载并安装该版本（文件缺失时用这个）"
        Write-Line "   3) 打开安装目录（查看日志 / 手动启动）"
        Write-Line "   0) 放弃并退出安装器"
        $c = Read-Answer "  请输入 1 / 2 / 3 / 0"
        if ($null -eq $c) {
            $script:FailMsg = "输入已结束（EOF），安装中止"
            return $false
        }
        switch ($c.Trim()) {
            "1" { continue }
            "2" {
                if (Install-Version $entry $dir) { continue } else { return $false }
            }
            "3" {
                try { Start-Process -FilePath "explorer.exe" -ArgumentList @($dir) | Out-Null } catch { }
            }
            "0" {
                $script:FailMsg = "面板启动失败，已放弃安装"
                return $false
            }
            default { Write-Bad "输入无效，请输入 1 / 2 / 3 / 0" }
        }
    }
}

# ---------------------------- 完成提示 ----------------------------

function Show-Success($dir) {
    if ($script:Mute) { return }
    Write-Host ""
    Write-Sep
    Write-Host "  安装完成" -ForegroundColor Green
    Write-Sep
    Write-Host "  面板地址：$script:PanelUrl" -ForegroundColor Cyan
    Write-Host "  安装目录：$dir"
    Write-Host "  运行日志：$dir\panel.log / daemon.log"
    if (Test-Path -LiteralPath $script:MaintainExe) {
        Write-Host "  维护工具：$script:MaintainExe（桌面 / 开始菜单快捷方式）" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  ⚠ 面板尚未配置超级用户，任何能访问该地址的人都可以创建超级用户，" -ForegroundColor Yellow
    Write-Host "    请立即访问并设置密码。" -ForegroundColor Yellow
    Write-Sep
}

# ---------------------------- 驻留菜单 ----------------------------

function Show-Menu($entry, $dir) {
    while ($true) {
        Write-Host ""
        Write-Host "==================== 安装器菜单 ====================" -ForegroundColor Cyan
        Write-Host "  0) 退出安装器"
        Write-Host "  1) 立即终止面板"
        Write-Host "  2) 重新拉取面板（同版本重装并启动）"
        $c = Read-Answer "请选择 [0/1/2]"
        if ($null -eq $c) {
            Write-Host ""
            Write-Host "输入已结束（EOF），退出安装器。" -ForegroundColor Yellow
            return
        }
        $c = $c.Trim()

        if ($c -eq "0") {
            if (Confirm-DefaultYes "是否在退出前打开浏览器并自动打开面板地址？(Y/n)") {
                if ($script:PanelUrl) {
                    try {
                        Start-Process $script:PanelUrl
                        Write-Ok "已在浏览器打开 $script:PanelUrl"
                    } catch {
                        Write-Note "打开浏览器失败：$($_.Exception.Message)"
                    }
                }
            }
            Write-Host ""
            Write-Host "已退出安装器。后续可通过 $dir 下的 scweb-daemon.exe / scweb-panel.exe 重新启动。" -ForegroundColor Green
            return
        } elseif ($c -eq "1") {
            $n = Stop-PanelProcesses $dir
            if ($n -gt 0) { Write-Ok "已终止面板进程（$n 个）" } else { Write-Note "没有检测到正在运行的面板进程" }
            $script:PanelUrl = ""
            continue
        } elseif ($c -eq "2") {
            Write-Host ""
            $n = Stop-PanelProcesses $dir
            if ($n -gt 0) { Write-Note "已先终止正在运行的面板进程（$n 个）" }
            if (Install-Version $entry $dir) {
                if (Start-PanelWithRetry $dir $entry) {
                    Write-InstallRecord $dir ([string]$entry.version)
                    Install-Maintainer $entry
                    Show-Success $dir
                } else { Write-Bad "重新启动失败，请查看 $dir\panel.err.log" }
            } else {
                Write-Bad "重新拉取失败，请检查网络后重试"
            }
            continue
        } else {
            Write-Host "  输入无效，请输入 0、1 或 2" -ForegroundColor Yellow
        }
    }
}

# ---------------------------- 主流程 ----------------------------

function Main {
    Write-Banner

    if (-not (Test-Environment)) {
        $script:FailMsg = "环境检查未通过，安装中止"
        Write-Line ""
        Write-Line "环境检查未通过，安装中止。请按上面的提示处理后重新运行。" Red
        Write-ManualHint
        return $false
    }

    $dir = Select-InstallDir
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $script:FailMsg = "安装目录无效"
        return $false
    }
    $dir = Resolve-InstallTarget $dir
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $script:FailMsg = "已取消安装"
        return $false
    }
    $script:InstallDir = $dir
    Write-Line ""
    Write-Line "  安装目录：$dir" Green

    $cfg = Get-VersionConfig
    if (-not $cfg) {
        $script:FailMsg = "无法获取版本列表"
        Write-Line ""
        Write-Line "无法获取版本列表（仓库可能尚未发布），请稍后重试或手动下载安装包。" Yellow
        Write-ManualHint
        return $false
    }

    $entry = Select-Version $cfg
    if (-not $entry) {
        if (-not $script:FailMsg) { $script:FailMsg = "未选择安装版本" }
        return $false
    }
    $script:ResultVersion = [string]$entry.version

    if (-not (Install-Version $entry $dir)) {
        if (-not $script:FailMsg) { $script:FailMsg = "安装失败（下载或写入失败）" }
        Write-Line ""
        Write-Line "安装失败：$($script:FailMsg)" Red
        Write-ManualHint
        return $false
    }

    if (-not (Start-PanelWithRetry $dir $entry)) {
        if (-not $script:FailMsg) { $script:FailMsg = "面板启动失败，请查看 $dir\panel.err.log / daemon.err.log" }
        Write-Line ""
        Write-Line "启动失败。请查看 $dir\panel.err.log / daemon.err.log。" Red
        return $false
    }

    Write-InstallRecord $dir $script:ResultVersion
    Install-Maintainer $entry
    Show-Success $dir
    # 静默/JSON 模式不进入驻留菜单
    if (-not $script:Mute) { Show-Menu $entry $dir }
    return $true
}

# -h 优先于一切
if ($script:OptHelp) {
    Write-Usage
    exit 0
}

$mainOk = $false
try {
    $mainOk = [bool](Main)
} catch {
    if (-not $script:FailMsg) { $script:FailMsg = "安装器异常终止：$($_.Exception.Message)" }
    if (-not $script:Mute) {
        Write-Host ""
        Write-Bad $script:FailMsg
        Write-Host "  位置：$($_.InvocationInfo.PositionMessage)"
        Write-ManualHint
    }
}

# 最终结果：-json 输出一行 JSON；-f 输出一行人类可读结果；交互模式保持原样
if ($script:OptJson) {
    Write-JsonResult ($mainOk -and -not $script:FailMsg) $script:FailMsg
} elseif ($script:OptSilent) {
    if ($mainOk -and -not $script:FailMsg) {
        [Console]::Out.WriteLine("安装完成：版本 $($script:ResultVersion)  面板 $($script:PanelUrl)  目录 $($script:InstallDir)")
    } else {
        [Console]::Out.WriteLine("安装失败：$($script:FailMsg)")
    }
}

# 临时文件只在安装结束（成功或退出）时清理，安装失败期间保留现场便于复现
Clear-TmpPaths

# 交互模式失败时停一下，避免双击运行时窗口一闪而过
if (-not $script:Mute -and -not ($mainOk -and -not $script:FailMsg)) {
    Write-Host ""
    try { [void](Read-Answer "  按回车键退出安装器") } catch { }
}

# 用退出码表达最终结果：自动化脚本（-f / -json）据此判断是否真的安装成功
if ($mainOk -and -not $script:FailMsg) { exit 0 }
exit 1
