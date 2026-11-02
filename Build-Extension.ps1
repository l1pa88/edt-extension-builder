#requires -Version 7.0
<#
.SYNOPSIS
Exports an EDT extension project and builds CFE in an isolated file infobase.
This packages an extension; it does not verify applicability to a production base.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\build.local.psd1",
    [string]$Branch,
    [switch]$NonInteractive
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
function Log([string]$Message) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $Message" -ForegroundColor Cyan }
function Run([string]$Exe, [string[]]$Arguments, [string]$LogFile) {
    Log "Run $(Split-Path $Exe -Leaf); log: $LogFile"
    & $Exe @Arguments 2>&1 | Out-File -LiteralPath $LogFile -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $Exe -Leaf) exited with $LASTEXITCODE. See $LogFile" }
}
function EdtQuote([string]$Value) {
    if ($Value -match '["\r\n]') { throw 'Quotes/newlines are not supported in EDT paths.' }
    return '"' + $Value.Replace('\','/') + '"'
}
try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Configuration missing: $ConfigPath. Copy build.example.psd1 to build.local.psd1 and fill in paths." }
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $settings = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $allowed = @('BaseProject','ExtensionProject','EdtCli','Ibcmd','OutputDirectory','EdtTimeoutSeconds','EdtHeapMb','EdtIni')
    foreach ($key in $settings.Keys) { if ($key -notin $allowed) { throw "Unknown configuration key: $key" } }
    foreach ($key in @('BaseProject','ExtensionProject','EdtCli','Ibcmd')) {
        if (-not $settings.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($settings[$key])) { throw "Configuration requires $key" }
    }
    foreach ($key in @('BaseProject','ExtensionProject','EdtCli','Ibcmd','OutputDirectory','EdtIni')) {
        if ($settings.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($settings[$key])) {
            $value = [string]$settings[$key]
            if (-not [IO.Path]::IsPathRooted($value)) { $value = Join-Path (Split-Path $ConfigPath) $value }
            $settings[$key] = [IO.Path]::GetFullPath($value)
        }
    }
    $ExtensionProject = $settings.ExtensionProject
    $BaseProject = $settings.BaseProject
    $EdtCli = $settings.EdtCli
    $Ibcmd = $settings.Ibcmd
    $OutputDirectory = if ($settings.ContainsKey('OutputDirectory')) { $settings.OutputDirectory } else { Join-Path (Split-Path $ConfigPath) 'artifacts' }
    $EdtIni = if ($settings.ContainsKey('EdtIni')) { $settings.EdtIni } else { '' }
    $EdtTimeoutSeconds = if ($settings.ContainsKey('EdtTimeoutSeconds')) { [int]$settings.EdtTimeoutSeconds } else { 3600 }
    $EdtHeapMb = if ($settings.ContainsKey('EdtHeapMb')) { [int]$settings.EdtHeapMb } else { 4096 }
    if ($EdtTimeoutSeconds -lt 60 -or $EdtTimeoutSeconds -gt 14400) { throw 'EdtTimeoutSeconds must be 60..14400.' }
    if ($EdtHeapMb -lt 512 -or $EdtHeapMb -gt 65536) { throw 'EdtHeapMb must be 512..65536.' }
    foreach ($path in @($EdtCli,$Ibcmd,(Join-Path $BaseProject '.project'),(Join-Path $ExtensionProject '.project'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file missing: $path" }
    }
    $EdtCli = (Resolve-Path -LiteralPath $EdtCli).Path
    $Ibcmd = (Resolve-Path -LiteralPath $Ibcmd).Path
    if (-not $EdtIni) { $EdtIni = Join-Path (Split-Path $EdtCli) '1cedt.ini' }
    if (-not (Test-Path -LiteralPath $EdtIni -PathType Leaf)) { throw "EDT launcher INI missing: $EdtIni" }
    $BaseProject = (Resolve-Path -LiteralPath $BaseProject).Path
    $ExtensionProject = (Resolve-Path -LiteralPath $ExtensionProject).Path
    if ($BaseProject -eq $ExtensionProject) { throw 'Base and extension must be different projects.' }
    $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
    foreach ($source in @($BaseProject,$ExtensionProject)) {
        if ($outputRoot.Equals($source,[StringComparison]::OrdinalIgnoreCase) -or
            $outputRoot.StartsWith($source.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'OutputDirectory must be outside source projects.'
        }
    }
    [xml]$baseDescription = Get-Content -LiteralPath (Join-Path $BaseProject '.project') -Raw
    [xml]$extensionDescription = Get-Content -LiteralPath (Join-Path $ExtensionProject '.project') -Raw
    if ([string]::IsNullOrWhiteSpace($baseDescription.projectDescription.name) -or
        [string]::IsNullOrWhiteSpace($extensionDescription.projectDescription.name) -or
        $baseDescription.projectDescription.name -eq $extensionDescription.projectDescription.name) {
        throw 'EDT project names must be nonempty and distinct.'
    }
    $manifestFile = Join-Path $ExtensionProject 'DT-INF\PROJECT.PMF'
    if (-not (Test-Path -LiteralPath $manifestFile)) { throw 'Extension PROJECT.PMF is missing.' }
    $baseReference = @(Get-Content -LiteralPath $manifestFile | Where-Object { $_ -match '^Base-Project:' })
    if ($baseReference.Count -ne 1 -or $baseReference[0].Substring(13).Trim() -ne $baseDescription.projectDescription.name) {
        throw 'Extension Base-Project does not match the supplied base project name.'
    }
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        if ($NonInteractive) { throw 'Specify -Branch for noninteractive builds.' }
        $Branch = Read-Host 'Branch label for this build (sources must already be checked out)'
    }
    $Branch = $Branch.Trim()
    if ([string]::IsNullOrWhiteSpace($Branch) -or $Branch -match '[\r\n]') { throw 'Branch label must be nonempty and single-line.' }
    Log "Build branch label: $Branch (no Git checkout is performed)"
    $run = Join-Path $outputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $run | Out-Null
    $sources = New-Item -ItemType Directory -Path (Join-Path $run 'sources')
    # EDT may update project settings: operate only on private copies.
    Copy-Item -LiteralPath $BaseProject -Destination (Join-Path $sources.FullName 'base') -Recurse
    Copy-Item -LiteralPath $ExtensionProject -Destination (Join-Path $sources.FullName 'extension') -Recurse
    $baseCopy = Join-Path $sources.FullName 'base'
    $extensionCopy = Join-Path $sources.FullName 'extension'
    $xmlDir = Join-Path $run 'xml'
    $workspace = Join-Path $run 'workspace'
    # A private launcher INI keeps Eclipse's writable configuration inside the run.
    $edtDir = Split-Path $EdtCli
    $iniLines = [Collections.Generic.List[string]]::new()
    $original = @(Get-Content -LiteralPath $EdtIni)
    if (@($original | Where-Object { $_ -eq '-vmargs' }).Count -ne 1) { throw 'EDT INI must contain one -vmargs line.' }
    for ($i=0; $i -lt $original.Count; $i++) {
        $line = $original[$i]
        if ($line -eq '-configuration') { $i++; continue }
        if ($line -eq '-vmargs') {
            $iniLines.Add('-configuration'); $iniLines.Add((Join-Path $run 'edt-configuration'))
            $iniLines.Add('-vmargs'); $iniLines.Add("-Xmx${EdtHeapMb}m")
            continue
        }
        if ($i -gt 0 -and $original[$i-1] -in @('-startup','--launcher.library','-vm','-showsplash') -and -not [IO.Path]::IsPathRooted($line)) { $line = Join-Path $edtDir $line }
        if ($line -match '^-Xm[xs]') { continue }
        $iniLines.Add($line)
    }
    $ini = Join-Path $run 'edt.ini'
    $iniLines | Set-Content -LiteralPath $ini -Encoding utf8NoBOM
    $step = 0
    foreach ($command in @(
        "import --project $(EdtQuote $baseCopy)",
        "import --project $(EdtQuote $extensionCopy)",
        "export --project-name $(EdtQuote $extensionDescription.projectDescription.name) --configuration-files $(EdtQuote $xmlDir)"
    )) {
        $step++
        $commands = Join-Path $run "edt-$step.txt"
        $command | Set-Content -LiteralPath $commands -Encoding utf8NoBOM
        Run $EdtCli @('-ini-file',$ini,'-data',$workspace,'-timeout',"$EdtTimeoutSeconds",'-file',$commands) (Join-Path $run "edt-$step.log")
    }
    $configurationFile = Join-Path $xmlDir 'Configuration.xml'
    if (-not (Test-Path -LiteralPath $configurationFile)) { throw 'EDT did not produce Configuration.xml.' }
    [xml]$configuration = Get-Content -LiteralPath $configurationFile -Raw
    $purpose = $configuration.SelectSingleNode("//*[local-name()='ConfigurationExtensionPurpose']")
    if ($null -eq $purpose -or [string]::IsNullOrWhiteSpace($purpose.InnerText)) { throw 'Exported project is not an extension.' }
    $name = $configuration.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Name']").InnerText
    $runtime = Join-Path $run 'runtime'
    $db = Join-Path $run 'db'
    $cfe = Join-Path $run 'extension.cfe'
    Run $Ibcmd @('infobase','create',"--data=$runtime","--db-path=$db") (Join-Path $run 'ib-create.log')
    Run $Ibcmd @('config','import',"--data=$runtime","--db-path=$db","--out=$cfe",$xmlDir) (Join-Path $run 'ib-pack.log')
    if (-not (Test-Path -LiteralPath $cfe) -or (Get-Item -LiteralPath $cfe).Length -eq 0) { throw 'CFE was not produced.' }
    # Reopen the artifact with the platform, rather than trusting file existence only.
    Run $Ibcmd @('config','load',"--data=$runtime","--db-path=$db","--extension=$name",$cfe) (Join-Path $run 'ib-readback.log')
    [ordered]@{
        extension = $name; createdUtc = [DateTime]::UtcNow.ToString('o')
        toolVersion = '1.0.0'
        branchLabel = $Branch
        extensionProject = $extensionDescription.projectDescription.name
        baseProject = $baseDescription.projectDescription.name
        platformVersion = (Get-Item $Ibcmd).VersionInfo.FileVersion
        sha256 = (Get-FileHash -LiteralPath $cfe -Algorithm SHA256).Hash
        applicabilityTested = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'manifest.json') -Encoding utf8NoBOM
    Write-Host "CFE built and read back: $cfe" -ForegroundColor Green
    Write-Output $cfe
} catch {
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
