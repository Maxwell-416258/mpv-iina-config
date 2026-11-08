param(
    [Parameter(Mandatory=$true)][string]$Zip,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$Episode = '',
    [string]$Season = '',
    [Parameter(Mandatory=$true)][string]$TargetBase
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Ensure-Dir([string]$Path) {
    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-SubtitleScore($File) {
    $extScore = if ($File.Extension -eq '.ass') { 0 } elseif ($File.Extension -eq '.ssa') { 1 } else { 2 }
    $langScore = if ($File.Name -match 'chs|简|簡|zh|chi|双语|雙語') { 0 } elseif ($File.Name -match 'cht|繁') { 1 } else { 2 }
    return @($extScore, $langScore)
}

Ensure-Dir $OutDir
$outerDir = Join-Path $OutDir 'outer'
Ensure-Dir $outerDir

# 解压外层 zip
Expand-Archive -LiteralPath $Zip -DestinationPath $outerDir -Force

# 如果是整季/整剧包，里面还有嵌套的季包，只解压当前季
if ($Season) {
    $nestedDir = Join-Path $OutDir 'nested'
    Ensure-Dir $nestedDir
    $nestedArchives = @()
    $nestedArchives += Get-ChildItem -LiteralPath $outerDir -Filter "*$Season*.zip" -File -ErrorAction SilentlyContinue
    $nestedArchives += Get-ChildItem -LiteralPath $outerDir -Filter "*$Season*.rar" -File -ErrorAction SilentlyContinue
    foreach ($archive in $nestedArchives) {
        if ($archive.Extension -eq '.zip') {
            Expand-Archive -LiteralPath $archive.FullName -DestinationPath $nestedDir -Force
        } elseif ($archive.Extension -eq '.rar') {
            $sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
            if ($sevenZip) {
                & $sevenZip x $archive.FullName "-o$nestedDir" -y | Out-Null
            }
        }
    }
}

# 收集所有字幕文件
$subFiles = @(Get-ChildItem -LiteralPath $OutDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '^\.(ass|ssa|srt)$' })

if ($subFiles.Count -eq 0) {
    Write-Output 'ERR:no subtitle file found'
    exit 2
}

# 按 SxxEyy 建立干净的缓存：clean/S02E01.ass
$cleanDir = Join-Path $OutDir 'clean'
Ensure-Dir $cleanDir
$groups = $subFiles | Where-Object { $_.Name -match '(?i)(S\d{2}E\d{2})' } |
    Group-Object { if ($_.Name -match '(?i)(S\d{2}E\d{2})') { $matches[1].ToUpper() } }

foreach ($group in $groups) {
    $best = $group.Group | Sort-Object `
        @{Expression={ (Get-SubtitleScore $_)[0] }}, `
        @{Expression={ (Get-SubtitleScore $_)[1] }} | Select-Object -First 1
    if ($best) {
        $cleanPath = Join-Path $cleanDir ($group.Name + $best.Extension)
        if (-not (Test-Path -LiteralPath $cleanPath)) {
            Copy-Item -LiteralPath $best.FullName -Destination $cleanPath -Force
        }
    }
}

# 选出当前这一集；指定了集数却找不到时必须报错，不能拿别的集凑数
$wanted = @()
if ($Episode) {
    $wanted = @($subFiles | Where-Object { $_.Name -match [regex]::Escape($Episode) })
    if ($wanted.Count -eq 0) {
        Write-Output 'ERR:no matching episode'
        exit 3
    }
} else {
    $wanted = $subFiles
}
$chosen = $wanted | Sort-Object `
    @{Expression={ (Get-SubtitleScore $_)[0] }}, `
    @{Expression={ (Get-SubtitleScore $_)[1] }} | Select-Object -First 1

if (-not $chosen) {
    Write-Output 'ERR:no matching subtitle'
    exit 3
}

Ensure-Dir (Split-Path -Parent $TargetBase)
$target = $TargetBase + $chosen.Extension
Copy-Item -LiteralPath $chosen.FullName -Destination $target -Force
Write-Output ('OK:' + $target)
