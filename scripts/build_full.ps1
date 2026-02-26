#Requires -Version 5.0
<#
.SYNOPSIS
    RenderDoc 完整构建脚本
    
.DESCRIPTION
    自动化构建RenderDoc的完整流程，包括：
    - Windows RenderDoc编译 (MSBuild x64 Release)
    - Android APK编译 (ARM32/ARM64)
    - 准备dist发布目录
    - 生成MSI安装包
    - 打包ZIP便携版
    
.PARAMETER SkipWindowsBuild
    跳过Windows编译步骤
    
.PARAMETER SkipAndroidBuild
    跳过Android APK编译步骤
    
.PARAMETER SkipMSI
    跳过MSI安装包生成
    
.PARAMETER SkipZIP
    跳过ZIP便携版打包
    
.PARAMETER Clean
    清理之前的构建产物
    
.PARAMETER CleanAndroid
    仅清理Android构建目录，强制重新编译APK
    不使用此参数时将使用增量编译（更快）
    
.PARAMETER AndroidArm32Only
    仅编译ARM32架构的APK
    
.PARAMETER AndroidArm64Only
    仅编译ARM64架构的APK
    
.EXAMPLE
    .\build_full.ps1
    执行完整构建流程（Android使用增量编译）
    
.EXAMPLE
    .\build_full.ps1 -SkipAndroidBuild
    跳过Android编译，只构建Windows版本
    
.EXAMPLE
    .\build_full.ps1 -SkipWindowsBuild -AndroidArm64Only
    仅编译ARM64 APK（增量编译）
    
.EXAMPLE
    .\build_full.ps1 -SkipWindowsBuild -CleanAndroid
    强制完全重新编译Android APK
#>

param(
    [switch]$SkipWindowsBuild,
    [switch]$SkipAndroidBuild,
    [switch]$SkipMSI,
    [switch]$SkipZIP,
    [switch]$Clean,
    [switch]$CleanAndroid,           # 仅清理Android构建目录（强制重新编译APK）
    [switch]$AndroidArm32Only,       # 仅编译ARM32
    [switch]$AndroidArm64Only        # 仅编译ARM64
)

# ============================================================================
# 配置变量
# ============================================================================

$ErrorActionPreference = "Stop"

# 获取脚本所在目录的父目录作为项目根目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# 版本信息 (从 version.h 提取)
$VersionMajor = 1
$VersionMinor = 43
$DistributionName = "YF6TA"
$DistributionVersion = "0.1"
$FullVersion = "$VersionMajor.$VersionMinor"
$ReleaseVersion = "${DistributionName}_v${DistributionVersion}"

# 目录配置
$SolutionFile = Join-Path $ProjectRoot "renderdoc.sln"
$DistDir = Join-Path $ProjectRoot "dist"
$DistRelease64 = Join-Path $DistDir "Release64"
$BuildOutputDir = Join-Path $ProjectRoot "x64\Release"

# Android 构建目录
$AndroidBuildArm32 = Join-Path $ProjectRoot "build-android-arm32"
$AndroidBuildArm64 = Join-Path $ProjectRoot "build-android-arm64"

# WiX 安装脚本
$WixSourceFile = Join-Path $ProjectRoot "util\installer\Installer64_Simple.wxs"
$WixLocFile = Join-Path $ProjectRoot "util\installer\customtext.wxl"

# 输出文件名
$MSIFileName = "RenderDoc_${FullVersion}_v${DistributionVersion}.msi"
$ZIPFileName = "RenderDoc_${FullVersion}_v${DistributionVersion}_Portable.zip"

# ============================================================================
# 工具函数
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "============================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[X] $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

# 进度条相关变量
$script:ProgressId = 1
$script:CurrentStep = 0
$script:TotalSteps = 0
$script:StepNames = @()
$script:SubProgressId = 2

function Initialize-BuildProgress {
    <#
    .SYNOPSIS
        初始化构建进度条，计算实际要执行的步骤数
    #>
    $script:StepNames = @()
    
    if ($Clean) {
        $script:StepNames += "清理构建产物"
    }
    if (-not $SkipWindowsBuild) {
        $script:StepNames += "编译 Windows RenderDoc"
    }
    if (-not $SkipAndroidBuild) {
        $script:StepNames += "编译 Android APK"
    }
    $script:StepNames += "准备 dist 目录"
    if (-not $SkipMSI) {
        $script:StepNames += "生成 MSI 安装包"
    }
    if (-not $SkipZIP) {
        $script:StepNames += "打包 ZIP 便携版"
    }
    
    $script:TotalSteps = $script:StepNames.Count
    $script:CurrentStep = 0
}

function Update-BuildProgress {
    param(
        [string]$StepName,
        [string]$Status = "正在处理...",
        [switch]$Completed
    )
    <#
    .SYNOPSIS
        更新构建进度条
    #>
    
    if ($Completed) {
        $script:CurrentStep++
    }
    
    $percentComplete = if ($script:TotalSteps -gt 0) {
        [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
    } else {
        0
    }
    
    $activity = "RenderDoc 构建进度 [$script:CurrentStep/$script:TotalSteps]"
    
    Write-Progress -Id $script:ProgressId `
                   -Activity $activity `
                   -Status "$StepName - $Status" `
                   -PercentComplete $percentComplete
}

function Update-SubProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1,
        [int]$Current = 0,
        [int]$Total = 0,
        [switch]$Completed
    )
    <#
    .SYNOPSIS
        更新子进度条（用于显示编译等长时间操作的详细进度）
    #>
    
    if ($Completed) {
        Write-Progress -Id $script:SubProgressId -Activity $Activity -Completed
        return
    }
    
    # 如果提供了 Current 和 Total，计算百分比
    if ($Total -gt 0) {
        $PercentComplete = [math]::Round(($Current / $Total) * 100)
        $Status = "[$Current/$Total] $Status"
    }
    
    # 确保百分比在有效范围内
    if ($PercentComplete -lt 0) { $PercentComplete = 0 }
    if ($PercentComplete -gt 100) { $PercentComplete = 100 }
    
    Write-Progress -Id $script:SubProgressId `
                   -ParentId $script:ProgressId `
                   -Activity $Activity `
                   -Status $Status `
                   -PercentComplete $PercentComplete
}

function Complete-BuildProgress {
    <#
    .SYNOPSIS
        完成并关闭进度条
    #>
    Write-Progress -Id $script:SubProgressId -Activity "子任务" -Completed
    Write-Progress -Id $script:ProgressId -Activity "构建完成" -Completed
}

function Find-MSBuild {
    <#
    .SYNOPSIS
        查找 MSBuild.exe 的路径
    #>
    
    # 优先使用 vswhere 查找最新版本的 Visual Studio
    $vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    
    if (Test-Path $vswherePath) {
        $vsPath = & $vswherePath -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($vsPath) {
            $msbuildPath = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
            if (Test-Path $msbuildPath) {
                return $msbuildPath
            }
            
            # 尝试 VS2017/2019 路径
            $msbuildPath = Join-Path $vsPath "MSBuild\15.0\Bin\MSBuild.exe"
            if (Test-Path $msbuildPath) {
                return $msbuildPath
            }
        }
    }
    
    # 回退到 PATH 中的 MSBuild
    if (Test-CommandExists "msbuild") {
        return "msbuild"
    }
    
    # 尝试常见的安装路径
    $commonPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
    )
    
    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

function Find-WiXTool {
    param([string]$ToolName)
    
    <#
    .SYNOPSIS
        查找 WiX 工具 (candle.exe 或 light.exe)
    #>
    
    # 检查 PATH
    if (Test-CommandExists $ToolName) {
        return $ToolName
    }
    
    # 检查 WIX 环境变量
    if ($env:WIX) {
        $toolPath = Join-Path $env:WIX "bin\$ToolName"
        if (Test-Path $toolPath) {
            return $toolPath
        }
    }
    
    # 常见的 WiX 安装路径
    $commonPaths = @(
        "${env:ProgramFiles(x86)}\WiX Toolset v3.14\bin\$ToolName",
        "${env:ProgramFiles(x86)}\WiX Toolset v3.11\bin\$ToolName",
        "${env:ProgramFiles(x86)}\WiX Toolset v3.10\bin\$ToolName",
        "${env:ProgramFiles}\WiX Toolset v3.14\bin\$ToolName",
        "${env:ProgramFiles}\WiX Toolset v3.11\bin\$ToolName"
    )
    
    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

# ============================================================================
# 步骤 1: Windows RenderDoc 编译
# ============================================================================

function Invoke-WindowsBuild {
    Write-Header "步骤 1: 编译 Windows RenderDoc (x64 Release)"
    
    if (-not (Test-Path $SolutionFile)) {
        Write-Error "找不到解决方案文件: $SolutionFile"
        exit 1
    }
    
    $msbuild = Find-MSBuild
    if (-not $msbuild) {
        Write-Error "找不到 MSBuild.exe，请确保已安装 Visual Studio 或 Build Tools"
        exit 1
    }
    
    Write-Step "使用 MSBuild: $msbuild"
    Write-Step "编译配置: Release, 平台: x64"
    
    # 切换到项目根目录
    Push-Location $ProjectRoot
    
    try {
        # 执行 MSBuild
        $buildArgs = @(
            $SolutionFile,
            "/p:Configuration=Release",
            "/p:Platform=x64",
            "/m",                          # 并行编译
            "/v:minimal",                  # 最小输出详细度
            "/nologo"
        )
        
        Write-Step "正在编译..."
        & $msbuild $buildArgs
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "MSBuild 编译失败，退出代码: $LASTEXITCODE"
            exit 1
        }
        
        Write-Step "Windows 编译完成!"
        
        # 验证输出文件
        $requiredFiles = @(
            "qrenderdoc.exe",
            "renderdoc.dll",
            "renderdoccmd.exe",
            "renderdocui.exe",
            "renderdocshim64.dll"
        )
        
        foreach ($file in $requiredFiles) {
            $filePath = Join-Path $BuildOutputDir $file
            if (-not (Test-Path $filePath)) {
                Write-Warning "预期的输出文件不存在: $file"
            }
        }
    }
    finally {
        Pop-Location
    }
}

# ============================================================================
# 步骤 2: Android APK 编译
# ============================================================================

function Find-BashShell {
    <#
    .SYNOPSIS
        查找可用的 Bash Shell (Git Bash 或 MSYS2)
    #>
    
    # 优先查找 Git Bash
    $gitBashPaths = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    
    foreach ($path in $gitBashPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # 查找 MSYS2
    $msys2Paths = @(
        "C:\msys64\usr\bin\bash.exe",
        "C:\msys32\usr\bin\bash.exe",
        "$env:USERPROFILE\msys64\usr\bin\bash.exe"
    )
    
    foreach ($path in $msys2Paths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # 检查 PATH
    if (Test-CommandExists "bash") {
        return "bash"
    }
    
    return $null
}

function Invoke-AndroidBuildArch {
    param(
        [string]$BashPath,
        [string]$Arch,           # "arm32" 或 "arm64"
        [string]$ABI,            # "armeabi-v7a" 或 "arm64-v8a"
        [string]$ProjectRootUnix,
        [string]$AndroidSdkUnix,
        [string]$AndroidNdkUnix,
        [string]$JavaHomeUnix,
        [bool]$CleanBuild
    )
    <#
    .SYNOPSIS
        编译单个架构的 Android APK，并实时显示进度
    #>
    
    $buildDir = Join-Path $ProjectRoot "build-android-$Arch"
    $cleanFlag = if ($CleanBuild) { "1" } else { "0" }
    
    # 子步骤：检测构建工具和配置
    $needConfigure = $CleanBuild -or (-not (Test-Path $buildDir)) -or (-not (Test-Path (Join-Path $buildDir "CMakeCache.txt")))
    
    # 创建编译脚本
    $buildScript = @"
#!/bin/bash
set -e

export ANDROID_SDK="$AndroidSdkUnix"
export ANDROID_NDK="$AndroidNdkUnix"
export ANDROID_HOME="$AndroidSdkUnix"
export ANDROID_NDK_HOME="$AndroidNdkUnix"
export JAVA_HOME="$JavaHomeUnix"
export PATH="$AndroidNdkUnix/prebuilt/windows-x86_64/bin:`$JAVA_HOME/bin:`$PATH"

cd "$ProjectRootUnix"

ARCH="$Arch"
ABI="$ABI"
BUILD_DIR="build-android-`$ARCH"
CLEAN_BUILD=$cleanFlag

# 检测构建工具
if command -v ninja &> /dev/null; then
    GENERATOR="Ninja"
    BUILD_CMD="ninja"
else
    GENERATOR="Unix Makefiles"
    BUILD_CMD="make"
fi

JOBS=`$(nproc 2>/dev/null || echo 4)

# CMake 配置
if [ "`$CLEAN_BUILD" = "1" ] || [ ! -d "`$BUILD_DIR" ] || [ ! -f "`$BUILD_DIR/CMakeCache.txt" ]; then
    echo "PROGRESS:CONFIGURE:START"
    if [ "`$CLEAN_BUILD" = "1" ] && [ -d "`$BUILD_DIR" ]; then
        rm -rf "`$BUILD_DIR"
    fi
    mkdir -p "`$BUILD_DIR"
    cd "`$BUILD_DIR"
    
    cmake -G "`$GENERATOR" \
        -DBUILD_ANDROID=1 \
        -DANDROID_ABI=`$ABI \
        -DANDROID_NATIVE_API_LEVEL=23 \
        -DCMAKE_BUILD_TYPE=Release \
        -DSTRIP_ANDROID_LIBRARY=On \
        ..
    echo "PROGRESS:CONFIGURE:DONE"
else
    echo "PROGRESS:CONFIGURE:SKIP"
    cd "`$BUILD_DIR"
fi

# 编译
echo "PROGRESS:BUILD:START"
if [ "`$BUILD_CMD" = "ninja" ]; then
    # Ninja 默认输出 [x/y] 格式的进度
    ninja 2>&1
else
    # Make 使用 --jobserver-style=pipe 来显示进度（如果支持）
    make -j`$JOBS 2>&1
fi
echo "PROGRESS:BUILD:DONE"

# 验证
if [ ! -f "bin/org.renderdoc.renderdoccmd.`$ARCH.apk" ]; then
    echo "PROGRESS:BUILD:FAILED"
    exit 1
fi

echo "PROGRESS:COMPLETE"
"@

    $buildScriptPath = Join-Path $ProjectRoot "scripts\build_android_${Arch}_temp.sh"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($buildScriptPath, ($buildScript -replace "`r`n", "`n"), $utf8NoBom)
    
    $buildScriptUnix = $buildScriptPath -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
    
    # 执行编译并解析输出
    $currentPhase = "准备中"
    $buildCurrent = 0
    $buildTotal = 0
    $lastPercent = 0
    
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $BashPath
        $psi.Arguments = if ($BashPath -eq "bash") { $buildScriptUnix } else { "--login -c `"bash '$buildScriptUnix'`"" }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $ProjectRoot
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        
        # 注册输出事件处理
        $outputBuilder = New-Object System.Text.StringBuilder
        $errorBuilder = New-Object System.Text.StringBuilder
        
        $process.Start() | Out-Null
        
        # 实时读取输出
        while (-not $process.HasExited) {
            $line = $process.StandardOutput.ReadLine()
            if ($null -ne $line) {
                # 解析进度信息
                if ($line -match "^PROGRESS:CONFIGURE:START") {
                    $currentPhase = "CMake 配置"
                    Update-SubProgress -Activity "$Arch APK" -Status "正在配置 CMake..." -PercentComplete 10
                }
                elseif ($line -match "^PROGRESS:CONFIGURE:(DONE|SKIP)") {
                    $currentPhase = "配置完成"
                    Update-SubProgress -Activity "$Arch APK" -Status "配置完成" -PercentComplete 20
                }
                elseif ($line -match "^PROGRESS:BUILD:START") {
                    $currentPhase = "编译中"
                    Update-SubProgress -Activity "$Arch APK" -Status "开始编译..." -PercentComplete 25
                }
                elseif ($line -match "^\[(\d+)/(\d+)\]") {
                    # Ninja 格式: [当前/总数] 目标
                    $buildCurrent = [int]$Matches[1]
                    $buildTotal = [int]$Matches[2]
                    $buildPercent = [math]::Round(($buildCurrent / $buildTotal) * 75) + 25  # 25-100%
                    if ($buildPercent -gt $lastPercent) {
                        $lastPercent = $buildPercent
                        $targetName = ($line -replace "^\[\d+/\d+\]\s*", "").Trim()
                        if ($targetName.Length -gt 50) {
                            $targetName = $targetName.Substring(0, 47) + "..."
                        }
                        Update-SubProgress -Activity "$Arch APK 编译" -Status $targetName -Current $buildCurrent -Total $buildTotal
                    }
                }
                elseif ($line -match "^\[\s*(\d+)%\]") {
                    # Make 百分比格式
                    $makePercent = [int]$Matches[1]
                    $buildPercent = [math]::Round($makePercent * 0.75) + 25  # 25-100%
                    if ($buildPercent -gt $lastPercent) {
                        $lastPercent = $buildPercent
                        Update-SubProgress -Activity "$Arch APK 编译" -Status "编译中..." -PercentComplete $buildPercent
                    }
                }
                elseif ($line -match "^PROGRESS:BUILD:DONE") {
                    Update-SubProgress -Activity "$Arch APK" -Status "编译完成" -PercentComplete 100
                }
                elseif ($line -match "^PROGRESS:COMPLETE") {
                    Update-SubProgress -Activity "$Arch APK" -Status "完成!" -PercentComplete 100
                }
                elseif ($line -notmatch "^PROGRESS:") {
                    # 输出非进度信息
                    [void]$outputBuilder.AppendLine($line)
                    # 只显示重要信息
                    if ($line -match "(error|warning|Error|Warning|ERROR|WARNING)" -or $line -match "^--") {
                        Write-Host "  $line" -ForegroundColor $(if ($line -match "error|Error|ERROR") { "Red" } elseif ($line -match "warning|Warning|WARNING") { "Yellow" } else { "DarkGray" })
                    }
                }
            }
            Start-Sleep -Milliseconds 50
        }
        
        # 读取剩余输出
        $remaining = $process.StandardOutput.ReadToEnd()
        if ($remaining) {
            [void]$outputBuilder.Append($remaining)
        }
        
        $errorOutput = $process.StandardError.ReadToEnd()
        if ($errorOutput) {
            [void]$errorBuilder.Append($errorOutput)
        }
        
        $process.WaitForExit()
        
        if ($process.ExitCode -ne 0) {
            Write-Error "  $Arch 编译失败 (退出代码: $($process.ExitCode))"
            if ($errorBuilder.Length -gt 0) {
                Write-Host $errorBuilder.ToString() -ForegroundColor Red
            }
            return $false
        }
        
        # 关闭子进度条
        Update-SubProgress -Activity "$Arch APK" -Completed
        
        return $true
    }
    finally {
        # 清理临时脚本
        if (Test-Path $buildScriptPath) {
            Remove-Item -Path $buildScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AndroidBuild {
    Write-Header "步骤 2: 编译 Android APK"
    
    # 检查环境变量
    $androidSdk = $env:ANDROID_SDK
    if (-not $androidSdk) { $androidSdk = $env:ANDROID_SDK_ROOT }
    if (-not $androidSdk) { $androidSdk = $env:ANDROID_HOME }
    
    $androidNdk = $env:ANDROID_NDK
    if (-not $androidNdk) { $androidNdk = $env:ANDROID_NDK_HOME }
    if (-not $androidNdk) { $androidNdk = $env:ANDROID_NDK_ROOT }
    if (-not $androidNdk) { $androidNdk = $env:NDK_HOME }
    
    $javaHome = $env:JAVA_HOME
    
    # 验证环境
    if (-not $androidSdk -or -not (Test-Path $androidSdk)) {
        Write-Warning "未找到 Android SDK，跳过 Android 编译"
        Write-Warning "请设置 ANDROID_SDK 或 ANDROID_HOME 环境变量"
        return $false
    }
    
    if (-not $androidNdk -or -not (Test-Path $androidNdk)) {
        Write-Warning "未找到 Android NDK，跳过 Android 编译"
        Write-Warning "请设置 ANDROID_NDK 或 ANDROID_NDK_HOME 环境变量"
        return $false
    }
    
    if (-not $javaHome -or -not (Test-Path $javaHome)) {
        Write-Warning "未找到 Java JDK，跳过 Android 编译"
        Write-Warning "请设置 JAVA_HOME 环境变量"
        return $false
    }
    
    # 查找 Bash Shell
    $bashPath = Find-BashShell
    if (-not $bashPath) {
        Write-Warning "未找到 Bash Shell (Git Bash 或 MSYS2)，跳过 Android 编译"
        Write-Warning "请安装 Git for Windows 或 MSYS2"
        return $false
    }
    
    Write-Step "Android SDK: $androidSdk"
    Write-Step "Android NDK: $androidNdk"
    Write-Step "Java Home: $javaHome"
    Write-Step "Bash Shell: $bashPath"
    
    # 将 Windows 路径转换为 MSYS 风格的路径
    $projectRootUnix = $ProjectRoot -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
    $androidSdkUnix = $androidSdk -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
    $androidNdkUnix = $androidNdk -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
    $javaHomeUnix = $javaHome -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
    
    # 确定要编译的架构
    $buildArm32 = -not $AndroidArm64Only
    $buildArm64 = -not $AndroidArm32Only
    
    $archList = @()
    if ($buildArm32) { $archList += "ARM32" }
    if ($buildArm64) { $archList += "ARM64" }
    
    Write-Step "将编译: $($archList -join ' + ')"
    
    if (-not $CleanAndroid) {
        Write-Step "使用增量编译 (如需完全重建，请添加 -CleanAndroid 参数)"
    } else {
        Write-Step "将清理并完全重新编译"
    }
    
    Write-Host ""
    
    Push-Location $ProjectRoot
    
    $success = $true
    $archCount = $archList.Count
    $currentArch = 0
    
    try {
        # 编译 ARM32
        if ($buildArm32) {
            $currentArch++
            Write-Step "[$currentArch/$archCount] 编译 ARM32 APK..."
            Update-SubProgress -Activity "ARM32 APK" -Status "准备中..." -PercentComplete 0
            
            $arm32Success = Invoke-AndroidBuildArch `
                -BashPath $bashPath `
                -Arch "arm32" `
                -ABI "armeabi-v7a" `
                -ProjectRootUnix $projectRootUnix `
                -AndroidSdkUnix $androidSdkUnix `
                -AndroidNdkUnix $androidNdkUnix `
                -JavaHomeUnix $javaHomeUnix `
                -CleanBuild $CleanAndroid
            
            if (-not $arm32Success) {
                $success = $false
                Write-Error "ARM32 APK 编译失败"
            } else {
                Write-Step "ARM32 APK 编译成功!"
            }
        }
        
        # 编译 ARM64
        if ($buildArm64 -and $success) {
            $currentArch++
            Write-Step "[$currentArch/$archCount] 编译 ARM64 APK..."
            Update-SubProgress -Activity "ARM64 APK" -Status "准备中..." -PercentComplete 0
            
            $arm64Success = Invoke-AndroidBuildArch `
                -BashPath $bashPath `
                -Arch "arm64" `
                -ABI "arm64-v8a" `
                -ProjectRootUnix $projectRootUnix `
                -AndroidSdkUnix $androidSdkUnix `
                -AndroidNdkUnix $androidNdkUnix `
                -JavaHomeUnix $javaHomeUnix `
                -CleanBuild $CleanAndroid
            
            if (-not $arm64Success) {
                $success = $false
                Write-Error "ARM64 APK 编译失败"
            } else {
                Write-Step "ARM64 APK 编译成功!"
            }
        }
        
        # 关闭子进度条
        Update-SubProgress -Activity "Android APK" -Completed
        
        if ($success) {
            # 验证输出文件
            $apkArm32 = Join-Path $AndroidBuildArm32 "bin\org.renderdoc.renderdoccmd.arm32.apk"
            $apkArm64 = Join-Path $AndroidBuildArm64 "bin\org.renderdoc.renderdoccmd.arm64.apk"
            
            Write-Step "Android APK 编译完成!"
            if ($buildArm32 -and (Test-Path $apkArm32)) {
                Write-Step "  - ARM32: $apkArm32"
            }
            if ($buildArm64 -and (Test-Path $apkArm64)) {
                Write-Step "  - ARM64: $apkArm64"
            }
        }
        
        return $success
    }
    finally {
        Pop-Location
    }
}

# ============================================================================
# 步骤 3: 准备 dist 目录
# ============================================================================

function Invoke-PrepareDistDir {
    Write-Header "步骤 3: 准备 dist 发布目录"
    
    # 验证编译输出存在
    if (-not (Test-Path $BuildOutputDir)) {
        Write-Error "编译输出目录不存在: $BuildOutputDir"
        Write-Error "请先运行 Windows 编译步骤"
        return $false
    }
    
    # 创建 dist 目录结构
    Write-Step "创建目录结构..."
    
    $directories = @(
        $DistDir,
        $DistRelease64,
        (Join-Path $DistRelease64 "plugins"),
        (Join-Path $DistRelease64 "plugins\android"),
        (Join-Path $DistRelease64 "qtplugins"),
        (Join-Path $DistRelease64 "qtplugins\imageformats"),
        (Join-Path $DistRelease64 "qtplugins\platforms")
    )
    
    foreach ($dir in $directories) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "  创建目录: $dir"
        }
    }
    
    $pluginsAndroidDir = Join-Path $DistRelease64 "plugins\android"
    $qtpluginsImgDir = Join-Path $DistRelease64 "qtplugins\imageformats"
    $qtpluginsPlatDir = Join-Path $DistRelease64 "qtplugins\platforms"
    
    Write-Step "复制编译输出文件到 dist/Release64..."
    
    # 核心文件 (必须存在)
    $coreFiles = @(
        "qrenderdoc.exe",
        "renderdoc.dll",
        "renderdoccmd.exe"
    )
    
    # 可选文件
    $optionalFiles = @(
        "renderdoc.json",
        "renderdocui.exe",
        "renderdocshim64.dll",
        "renderdoc_app.h",
        "d3dcompiler_47.dll",
        "dbghelp.dll",
        "symsrv.dll",
        "symsrv.yes",
        # Qt 依赖
        "Qt5Core.dll",
        "Qt5Gui.dll",
        "Qt5Network.dll",
        "Qt5Svg.dll",
        "Qt5Widgets.dll",
        # Python 依赖
        "python36.dll",
        "python36.zip",
        "_ctypes.pyd",
        # 帮助文件
        "renderdoc.chm"
    )
    
    $copyCount = 0
    $skipCount = 0
    
    # 复制核心文件
    foreach ($file in $coreFiles) {
        $sourcePath = Join-Path $BuildOutputDir $file
        $destPath = Join-Path $DistRelease64 $file
        
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $destPath -Force
            Write-Host "  [核心] 复制: $file"
            $copyCount++
        } else {
            Write-Error "  [核心] 缺失: $file - 此文件是必需的！"
            return $false
        }
    }
    
    # 复制可选文件
    foreach ($file in $optionalFiles) {
        $sourcePath = Join-Path $BuildOutputDir $file
        $destPath = Join-Path $DistRelease64 $file
        
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $destPath -Force
            Write-Host "  复制: $file"
            $copyCount++
        } else {
            Write-Host "  跳过 (不存在): $file" -ForegroundColor DarkGray
            $skipCount++
        }
    }
    
    # 复制 32 位 shim (如果存在于 Win32\Release)
    $shim32Source = Join-Path $ProjectRoot "Win32\Release\renderdocshim32.dll"
    if (Test-Path $shim32Source) {
        Copy-Item -Path $shim32Source -Destination (Join-Path $DistRelease64 "renderdocshim32.dll") -Force
        Write-Host "  复制: renderdocshim32.dll (32-bit)"
        $copyCount++
    }
    
    # 复制 Qt 插件
    Write-Step "复制 Qt 插件..."
    $qtSrcImgDir = Join-Path $BuildOutputDir "qtplugins\imageformats"
    $qtSrcPlatDir = Join-Path $BuildOutputDir "qtplugins\platforms"
    
    if (Test-Path $qtSrcImgDir) {
        $imgFiles = Get-ChildItem -Path $qtSrcImgDir -File
        foreach ($imgFile in $imgFiles) {
            Copy-Item -Path $imgFile.FullName -Destination $qtpluginsImgDir -Force
            Write-Host "  复制: qtplugins/imageformats/$($imgFile.Name)"
            $copyCount++
        }
    } else {
        Write-Warning "  Qt imageformats 插件目录不存在"
    }
    
    if (Test-Path $qtSrcPlatDir) {
        $platFiles = Get-ChildItem -Path $qtSrcPlatDir -File
        foreach ($platFile in $platFiles) {
            Copy-Item -Path $platFile.FullName -Destination $qtpluginsPlatDir -Force
            Write-Host "  复制: qtplugins/platforms/$($platFile.Name)"
            $copyCount++
        }
    } else {
        Write-Warning "  Qt platforms 插件目录不存在"
    }
    
    # 复制 Android APK
    Write-Step "复制 Android APK..."
    
    $apkArm32 = Join-Path $AndroidBuildArm32 "bin\org.renderdoc.renderdoccmd.arm32.apk"
    $apkArm64 = Join-Path $AndroidBuildArm64 "bin\org.renderdoc.renderdoccmd.arm64.apk"
    
    $apkCopied = 0
    
    # ARM32 APK
    if (Test-Path $apkArm32) {
        Copy-Item -Path $apkArm32 -Destination $pluginsAndroidDir -Force
        Write-Host "  复制: org.renderdoc.renderdoccmd.arm32.apk (从构建目录)"
        $apkCopied++
    } else {
        # 检查备用位置
        $altLocations = @(
            (Join-Path $DistDir "org.renderdoc.renderdoccmd.arm32.apk"),
            (Join-Path $ProjectRoot "org.renderdoc.renderdoccmd.arm32.apk")
        )
        $found = $false
        foreach ($altPath in $altLocations) {
            if (Test-Path $altPath) {
                Copy-Item -Path $altPath -Destination $pluginsAndroidDir -Force
                Write-Host "  复制: org.renderdoc.renderdoccmd.arm32.apk (从备用位置)"
                $apkCopied++
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Warning "  未找到 ARM32 APK"
        }
    }
    
    # ARM64 APK
    if (Test-Path $apkArm64) {
        Copy-Item -Path $apkArm64 -Destination $pluginsAndroidDir -Force
        Write-Host "  复制: org.renderdoc.renderdoccmd.arm64.apk (从构建目录)"
        $apkCopied++
    } else {
        # 检查备用位置
        $altLocations = @(
            (Join-Path $DistDir "org.renderdoc.renderdoccmd.arm64.apk"),
            (Join-Path $ProjectRoot "org.renderdoc.renderdoccmd.arm64.apk")
        )
        $found = $false
        foreach ($altPath in $altLocations) {
            if (Test-Path $altPath) {
                Copy-Item -Path $altPath -Destination $pluginsAndroidDir -Force
                Write-Host "  复制: org.renderdoc.renderdoccmd.arm64.apk (从备用位置)"
                $apkCopied++
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Warning "  未找到 ARM64 APK"
        }
    }
    
    # 汇总统计
    Write-Host ""
    Write-Step "文件复制统计:"
    Write-Host "  - 已复制: $copyCount 个文件"
    Write-Host "  - 已跳过: $skipCount 个文件"
    Write-Host "  - APK 文件: $apkCopied 个"
    
    # 验证 dist 目录内容
    Write-Step "验证 dist 目录..."
    $distFiles = Get-ChildItem -Path $DistRelease64 -File -Recurse
    Write-Host "  dist/Release64 包含 $($distFiles.Count) 个文件"
    
    Write-Step "dist 目录准备完成!"
    return $true
}

# ============================================================================
# 步骤 4: 生成 MSI 安装包
# ============================================================================

function Invoke-GenerateMSI {
    Write-Header "步骤 4: 生成 MSI 安装包"
    
    # 验证 WiX 源文件存在
    if (-not (Test-Path $WixSourceFile)) {
        Write-Error "找不到 WiX 源文件: $WixSourceFile"
        return $false
    }
    
    if (-not (Test-Path $WixLocFile)) {
        Write-Error "找不到 WiX 本地化文件: $WixLocFile"
        return $false
    }
    
    # 验证 dist 目录已准备
    $requiredFiles = @(
        (Join-Path $DistRelease64 "qrenderdoc.exe"),
        (Join-Path $DistRelease64 "renderdoc.dll"),
        (Join-Path $DistRelease64 "renderdoccmd.exe")
    )
    
    foreach ($reqFile in $requiredFiles) {
        if (-not (Test-Path $reqFile)) {
            Write-Error "缺少必需文件: $reqFile"
            Write-Error "请先运行 dist 目录准备步骤"
            return $false
        }
    }
    
    # 查找 WiX 工具
    $candlePath = Find-WiXTool "candle.exe"
    $lightPath = Find-WiXTool "light.exe"
    
    if ((-not $candlePath) -or (-not $lightPath)) {
        Write-Warning "找不到 WiX 工具集 (candle.exe / light.exe)"
        Write-Warning "跳过 MSI 生成"
        Write-Warning ""
        Write-Warning "安装 WiX Toolset 的方法:"
        Write-Warning "  1. 下载: https://wixtoolset.org/releases/"
        Write-Warning "  2. 或使用 Chocolatey: choco install wixtoolset"
        Write-Warning "  3. 或使用 winget: winget install WiXToolset.WiXToolset"
        Write-Warning ""
        Write-Warning "安装后，可能需要设置 WIX 环境变量或将 bin 目录添加到 PATH"
        return $false
    }
    
    Write-Step "WiX 工具:"
    Write-Host "  - candle: $candlePath"
    Write-Host "  - light: $lightPath"
    
    # 设置环境变量
    $env:RENDERDOC_VERSION = $FullVersion
    Write-Step "版本号: $FullVersion"
    
    Push-Location $ProjectRoot
    
    try {
        $wixObjFile = Join-Path $DistDir "Installer64_Simple.wixobj"
        $msiFile = Join-Path $DistDir $MSIFileName
        $pdbFile = Join-Path $DistDir ($MSIFileName -replace '\.msi$', '.wixpdb')
        
        # 删除旧的输出文件
        if (Test-Path $wixObjFile) { Remove-Item -Path $wixObjFile -Force }
        if (Test-Path $msiFile) { Remove-Item -Path $msiFile -Force }
        if (Test-Path $pdbFile) { Remove-Item -Path $pdbFile -Force }
        
        # 运行 candle (WiX 编译器)
        Write-Step "运行 candle.exe (编译 WiX 源文件)..."
        $candleArgs = @(
            "-nologo",
            "-o", $wixObjFile,
            $WixSourceFile
        )
        
        & $candlePath @candleArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "candle.exe 失败，退出代码: $LASTEXITCODE"
            return $false
        }
        
        if (-not (Test-Path $wixObjFile)) {
            Write-Error "candle.exe 未生成 .wixobj 文件"
            return $false
        }
        
        Write-Host "  生成: $wixObjFile"
        
        # 运行 light (WiX 链接器)
        Write-Step "运行 light.exe (生成 MSI)..."
        $lightArgs = @(
            "-nologo",
            "-ext", "WixUIExtension",
            "-sw1076",                    # 忽略 ICE 警告
            "-loc", $WixLocFile,          # 本地化文件
            "-o", $msiFile,
            $wixObjFile
        )
        
        & $lightPath @lightArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "light.exe 失败，退出代码: $LASTEXITCODE"
            return $false
        }
        
        if (-not (Test-Path $msiFile)) {
            Write-Error "light.exe 未生成 MSI 文件"
            return $false
        }
        
        # 获取文件信息
        $msiInfo = Get-Item $msiFile
        $msiSizeMB = [math]::Round($msiInfo.Length / 1MB, 2)
        
        Write-Step "MSI 安装包生成完成!"
        Write-Host "  - 文件: $MSIFileName"
        Write-Host "  - 大小: $msiSizeMB MB"
        Write-Host "  - 路径: $msiFile"
        
        # 清理中间文件
        if (Test-Path $wixObjFile) { 
            Remove-Item -Path $wixObjFile -Force 
            Write-Host "  - 已清理: Installer64_Simple.wixobj"
        }
        if (Test-Path $pdbFile) { 
            Remove-Item -Path $pdbFile -Force 
            Write-Host "  - 已清理: $(Split-Path $pdbFile -Leaf)"
        }
        
        return $true
    }
    catch {
        Write-Error "MSI 生成过程中发生错误: $_"
        return $false
    }
    finally {
        Pop-Location
    }
}

# ============================================================================
# 步骤 5: 打包 ZIP 便携版
# ============================================================================

function Invoke-GenerateZIP {
    Write-Header "步骤 5: 打包 ZIP 便携版"
    
    # 验证 dist 目录存在且不为空
    if (-not (Test-Path $DistRelease64)) {
        Write-Error "dist/Release64 目录不存在"
        Write-Error "请先运行 dist 目录准备步骤"
        return $false
    }
    
    $distFiles = Get-ChildItem -Path $DistRelease64 -File -Recurse
    if ($distFiles.Count -eq 0) {
        Write-Error "dist/Release64 目录为空"
        return $false
    }
    
    Write-Step "dist/Release64 包含 $($distFiles.Count) 个文件"
    
    $zipFile = Join-Path $DistDir $ZIPFileName
    
    # 删除旧的 ZIP 文件
    if (Test-Path $zipFile) {
        Write-Step "删除旧的 ZIP 文件..."
        Remove-Item -Path $zipFile -Force
    }
    
    Write-Step "创建 ZIP 文件: $ZIPFileName"
    
    try {
        # 检查是否有 7-Zip (更快的压缩)
        $sevenZipPaths = @(
            "$env:ProgramFiles\7-Zip\7z.exe",
            "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
            "C:\Program Files\7-Zip\7z.exe"
        )
        
        $sevenZip = $null
        foreach ($path in $sevenZipPaths) {
            if (Test-Path $path) {
                $sevenZip = $path
                break
            }
        }
        
        if ($sevenZip) {
            # 使用 7-Zip (更快，压缩率更好)
            Write-Step "使用 7-Zip 进行压缩..."
            
            Push-Location $DistRelease64
            try {
                & $sevenZip a -tzip -mx=9 $zipFile * | ForEach-Object {
                    if ($_ -match "^Compressing" -or $_ -match "^Everything is Ok") {
                        Write-Host "  $_"
                    }
                }
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "7-Zip 返回非零退出码: $LASTEXITCODE"
                }
            }
            finally {
                Pop-Location
            }
        } else {
            # 使用 PowerShell 内置的 Compress-Archive
            Write-Step "使用 PowerShell Compress-Archive 进行压缩..."
            Write-Host "  (提示: 安装 7-Zip 可获得更快的压缩速度)"
            
            # Compress-Archive 在某些情况下可能较慢，显示进度
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            
            Compress-Archive -Path "$DistRelease64\*" -DestinationPath $zipFile -Force -CompressionLevel Optimal
            
            $sw.Stop()
            Write-Host "  压缩用时: $([math]::Round($sw.Elapsed.TotalSeconds, 2)) 秒"
        }
        
        # 验证 ZIP 文件
        if (Test-Path $zipFile) {
            $zipInfo = Get-Item $zipFile
            $zipSizeMB = [math]::Round($zipInfo.Length / 1MB, 2)
            
            # 计算压缩率
            $originalSize = ($distFiles | Measure-Object -Property Length -Sum).Sum
            $originalSizeMB = [math]::Round($originalSize / 1MB, 2)
            $compressionRatio = [math]::Round((1 - ($zipInfo.Length / $originalSize)) * 100, 1)
            
            Write-Step "ZIP 便携版打包完成!"
            Write-Host "  - 文件: $ZIPFileName"
            Write-Host "  - 大小: $zipSizeMB MB (原始: $originalSizeMB MB)"
            Write-Host "  - 压缩率: $compressionRatio%"
            Write-Host "  - 路径: $zipFile"
            Write-Host "  - 文件数: $($distFiles.Count)"
            
            return $true
        } else {
            Write-Error "ZIP 文件创建失败"
            return $false
        }
    }
    catch {
        Write-Error "ZIP 打包过程中发生错误: $_"
        return $false
    }
}

# ============================================================================
# 清理函数
# ============================================================================

function Invoke-Clean {
    Write-Header "清理构建产物"
    
    $dirsToClean = @(
        (Join-Path $ProjectRoot "x64\Release"),
        (Join-Path $ProjectRoot "Win32\Release"),
        $DistDir
    )
    
    foreach ($dir in $dirsToClean) {
        if (Test-Path $dir) {
            Write-Step "清理目录: $dir"
            Remove-Item -Path $dir -Recurse -Force
        }
    }
    
    Write-Step "清理完成!"
}

# ============================================================================
# 主入口
# ============================================================================

function Main {
    Write-Header "RenderDoc 完整构建脚本"
    
    Write-Host "项目目录: $ProjectRoot"
    Write-Host "版本: $FullVersion ($ReleaseVersion)"
    Write-Host ""
    Write-Host "构建选项:"
    Write-Host "  - SkipWindowsBuild: $SkipWindowsBuild"
    Write-Host "  - SkipAndroidBuild: $SkipAndroidBuild"
    Write-Host "  - SkipMSI: $SkipMSI"
    Write-Host "  - SkipZIP: $SkipZIP"
    Write-Host "  - Clean: $Clean"
    Write-Host "  - CleanAndroid: $CleanAndroid"
    Write-Host "  - AndroidArm32Only: $AndroidArm32Only"
    Write-Host "  - AndroidArm64Only: $AndroidArm64Only"
    Write-Host ""
    
    # 检查是否在正确的目录
    if (-not (Test-Path $SolutionFile)) {
        Write-Error "找不到 renderdoc.sln，请确保在正确的项目目录中运行此脚本"
        exit 1
    }
    
    # 跟踪构建结果
    $buildResults = @{
        WindowsBuild = $null
        AndroidBuild = $null
        PrepareDist  = $null
        GenerateMSI  = $null
        GenerateZIP  = $null
    }
    
    $startTime = Get-Date
    
    # 初始化进度条
    Initialize-BuildProgress
    Write-Host "将执行 $script:TotalSteps 个构建步骤: $($script:StepNames -join ' → ')" -ForegroundColor DarkCyan
    Write-Host ""
    
    # 清理
    if ($Clean) {
        Update-BuildProgress -StepName "清理构建产物" -Status "正在清理..."
        Invoke-Clean
        Update-BuildProgress -StepName "清理构建产物" -Status "完成" -Completed
    }
    
    # 步骤 1: Windows 编译
    if (-not $SkipWindowsBuild) {
        Update-BuildProgress -StepName "编译 Windows RenderDoc" -Status "正在编译..."
        Invoke-WindowsBuild
        $buildResults.WindowsBuild = $LASTEXITCODE -eq 0
        Update-BuildProgress -StepName "编译 Windows RenderDoc" -Status "完成" -Completed
    } else {
        Write-Step "跳过 Windows 编译"
        $buildResults.WindowsBuild = $null
    }
    
    # 步骤 2: Android 编译
    if (-not $SkipAndroidBuild) {
        Update-BuildProgress -StepName "编译 Android APK" -Status "正在编译..."
        $buildResults.AndroidBuild = Invoke-AndroidBuild
        Update-BuildProgress -StepName "编译 Android APK" -Status "完成" -Completed
    } else {
        Write-Step "跳过 Android 编译"
        $buildResults.AndroidBuild = $null
    }
    
    # 步骤 3: 准备 dist 目录
    Update-BuildProgress -StepName "准备 dist 目录" -Status "正在复制文件..."
    $buildResults.PrepareDist = Invoke-PrepareDistDir
    Update-BuildProgress -StepName "准备 dist 目录" -Status "完成" -Completed
    
    # 如果 dist 准备失败，则跳过后续步骤
    if ($buildResults.PrepareDist -eq $false) {
        Write-Error "dist 目录准备失败，跳过 MSI 和 ZIP 生成"
    } else {
        # 步骤 4: 生成 MSI
        if (-not $SkipMSI) {
            Update-BuildProgress -StepName "生成 MSI 安装包" -Status "正在生成..."
            $buildResults.GenerateMSI = Invoke-GenerateMSI
            Update-BuildProgress -StepName "生成 MSI 安装包" -Status "完成" -Completed
        } else {
            Write-Step "跳过 MSI 生成"
            $buildResults.GenerateMSI = $null
        }
        
        # 步骤 5: 打包 ZIP
        if (-not $SkipZIP) {
            Update-BuildProgress -StepName "打包 ZIP 便携版" -Status "正在压缩..."
            $buildResults.GenerateZIP = Invoke-GenerateZIP
            Update-BuildProgress -StepName "打包 ZIP 便携版" -Status "完成" -Completed
        } else {
            Write-Step "跳过 ZIP 打包"
            $buildResults.GenerateZIP = $null
        }
    }
    
    # 关闭进度条
    Complete-BuildProgress
    
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    # 完成汇总
    Write-Header "构建完成!"
    
    Write-Host "构建用时: $([math]::Round($duration.TotalMinutes, 2)) 分钟"
    Write-Host ""
    
    # 显示构建结果
    Write-Host "构建结果汇总:" -ForegroundColor Cyan
    
    # 获取结果显示信息的辅助函数
    function Get-ResultDisplay {
        param($Result)
        if ($Result -eq $true) {
            return @{ Symbol = "[OK]"; Color = "Green" }
        } elseif ($Result -eq $false) {
            return @{ Symbol = "[X]"; Color = "Red" }
        } else {
            return @{ Symbol = "[-]"; Color = "DarkGray" }
        }
    }
    
    $steps = @(
        @{ Name = "Windows 编译"; Key = "WindowsBuild" },
        @{ Name = "Android APK 编译"; Key = "AndroidBuild" },
        @{ Name = "Dist 目录准备"; Key = "PrepareDist" },
        @{ Name = "MSI 安装包生成"; Key = "GenerateMSI" },
        @{ Name = "ZIP 便携版打包"; Key = "GenerateZIP" }
    )
    
    foreach ($step in $steps) {
        $result = $buildResults[$step.Key]
        $display = Get-ResultDisplay $result
        Write-Host "  $($display.Symbol) $($step.Name)" -ForegroundColor $display.Color
    }
    
    Write-Host ""
    Write-Host "输出文件:" -ForegroundColor Cyan
    
    if (Test-Path $DistRelease64) {
        $fileCount = (Get-ChildItem -Path $DistRelease64 -File -Recurse).Count
        Write-Host "  [✓] dist/Release64/ ($fileCount 个文件)" -ForegroundColor Green
    }
    
    $msiPath = Join-Path $DistDir $MSIFileName
    $zipPath = Join-Path $DistDir $ZIPFileName
    
    if (Test-Path $msiPath) {
        $msiSize = [math]::Round((Get-Item $msiPath).Length / 1MB, 2)
        Write-Host "  [✓] dist/$MSIFileName ($msiSize MB)" -ForegroundColor Green
    } elseif (-not $SkipMSI) {
        Write-Host "  [✗] dist/$MSIFileName (未生成)" -ForegroundColor Red
    }
    
    if (Test-Path $zipPath) {
        $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Host "  [✓] dist/$ZIPFileName ($zipSize MB)" -ForegroundColor Green
    } elseif (-not $SkipZIP) {
        Write-Host "  [✗] dist/$ZIPFileName (未生成)" -ForegroundColor Red
    }
    
    # 检查 Android APK
    $pluginsAndroidDir = Join-Path $DistRelease64 "plugins\android"
    if (Test-Path $pluginsAndroidDir) {
        $apkFiles = Get-ChildItem -Path $pluginsAndroidDir -Filter "*.apk"
        if ($apkFiles.Count -gt 0) {
            Write-Host "  [✓] Android APK ($($apkFiles.Count) 个)" -ForegroundColor Green
        }
    }
    
    Write-Host ""
}

# 执行主函数
Main
