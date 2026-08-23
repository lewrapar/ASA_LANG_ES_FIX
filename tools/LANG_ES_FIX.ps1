[CmdletBinding()]
param(
    [ValidateSet('Install','Diagnostic','Revert')]
    [string]$Action = 'Install',
    [string]$GamePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Release = 'LANG_ES_FIX'
$Revision = 'release-1.0.0-2026-08-23'
$PakName = 'LANG_ES_FIX_P.pak'
$StateFolderName = 'LANG_ES_FIX_STATE'
$script:LogFile = $null

trap {
    $message = $_.Exception.ToString()
    Write-Host ''
    Write-Host ('ERROR LANG_ES_FIX: ' + $_.Exception.Message) -ForegroundColor Red
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value '===== ERROR COMPLETO =====' -Encoding UTF8
        Add-Content -LiteralPath $script:LogFile -Value $message -Encoding UTF8
        Add-Content -LiteralPath $script:LogFile -Value ('FullyQualifiedErrorId: ' + $_.FullyQualifiedErrorId) -Encoding UTF8
        Add-Content -LiteralPath $script:LogFile -Value ('CategoryInfo: ' + $_.CategoryInfo) -Encoding UTF8
        Add-Content -LiteralPath $script:LogFile -Value ('Position: ' + $_.InvocationInfo.PositionMessage) -Encoding UTF8
        Add-Content -LiteralPath $script:LogFile -Value ('Stack: ' + $_.ScriptStackTrace) -Encoding UTF8
    }
    exit 1
}

function Write-Log([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Color
    if ($script:LogFile) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Add-Content -LiteralPath $script:LogFile -Value ("[$stamp] $Text") -Encoding UTF8
    }
}

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Add-SteamRoot([hashtable]$Map, [string]$Value) {
    if (-not $Value) { return }
    $normalized = $Value.Trim().Trim('"') -replace '/', '\'
    if ($normalized) { $Map[$normalized.ToLowerInvariant()] = $normalized }
}

function Find-ArkInstall {
    $roots = @{}
    try { Add-SteamRoot $roots (Get-ItemPropertyValue 'HKCU:\Software\Valve\Steam' 'SteamPath') } catch {}
    try { Add-SteamRoot $roots (Get-ItemPropertyValue 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath') } catch {}
    try { Add-SteamRoot $roots (Get-ItemPropertyValue 'HKLM:\SOFTWARE\Valve\Steam' 'InstallPath') } catch {}
    if ($env:ProgramFiles) { Add-SteamRoot $roots (Join-Path $env:ProgramFiles 'Steam') }
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { Add-SteamRoot $roots (Join-Path $pf86 'Steam') }

    foreach ($root in @($roots.Values)) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            try {
                $text = Get-Content -LiteralPath $vdf -Raw
                foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                    Add-SteamRoot $roots ($match.Groups[1].Value -replace '\\\\','\')
                }
            } catch {}
        }
    }

    foreach ($root in @($roots.Values)) {
        $steamApps = Join-Path $root 'steamapps'
        $manifest = Join-Path $steamApps 'appmanifest_2399830.acf'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            try {
                $acf = Get-Content -LiteralPath $manifest -Raw
                $match = [regex]::Match($acf, '"installdir"\s+"([^"]+)"')
                if ($match.Success) {
                    $candidate = Join-Path (Join-Path $steamApps 'common') $match.Groups[1].Value
                    if (Test-Path -LiteralPath (Join-Path $candidate 'ShooterGame\Content\Paks') -PathType Container) { return $candidate }
                }
            } catch {}
        }
        $candidate = Join-Path $steamApps 'common\ARK Survival Ascended'
        if (Test-Path -LiteralPath (Join-Path $candidate 'ShooterGame\Content\Paks') -PathType Container) { return $candidate }
    }
    return $null
}

function Assert-GameClosed {
    foreach ($name in @('ArkAscended','ArkAscended_BE','ShooterGame')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            throw 'ARK: Survival Ascended esta abierto. Cierra el juego antes de continuar.'
        }
    }
}

function Quote-NativeArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"'
}

function Invoke-Captured([string]$Exe, [string[]]$Arguments, [switch]$AllowFailure) {
    $argumentText = (($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    Write-Log ('[TOOL][START] "' + $Exe + '" ' + $argumentText) DarkGray
    $start = Get-Date
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = $argumentText
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Process.Start devolvio false.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
    } catch {
        Write-Log ('[TOOL][START-ERROR] ' + $_.Exception.ToString()) Red
        throw
    } finally {
        $process.Dispose()
    }
    $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 3)
    Write-Log ("[TOOL][EXIT] code=$exitCode seconds=$elapsed") $(if ($exitCode -eq 0) { 'DarkGray' } else { 'Yellow' })
    if ($stdout) { Add-Content -LiteralPath $script:LogFile -Value ("[STDOUT]`r`n" + $stdout.TrimEnd()) -Encoding UTF8 }
    if ($stderr) { Add-Content -LiteralPath $script:LogFile -Value ("[STDERR]`r`n" + $stderr.TrimEnd()) -Encoding UTF8 }
    $result = [pscustomobject]@{ ExitCode=$exitCode; StdOut=$stdout; StdErr=$stderr; Seconds=$elapsed }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = if ($stderr) { $stderr.Trim() } elseif ($stdout) { $stdout.Trim() } else { 'sin salida de diagnostico' }
        throw "La herramienta termino con codigo $exitCode.`r`n$detail"
    }
    return $result
}

function Download-Pinned([string]$Url, [string]$Destination, [string]$ExpectedSha256) {
    $ExpectedSha256 = $ExpectedSha256.ToLowerInvariant()
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $cached = Get-Sha256 $Destination
        if ($cached -eq $ExpectedSha256) {
            Write-Log ('[CACHE][OK] ' + (Split-Path -Leaf $Destination)) DarkGray
            return
        }
        Write-Log ('[CACHE][REJECT] Hash inesperado para ' + $Destination) Yellow
        Remove-Item -LiteralPath $Destination -Force
    }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $part = $Destination + '.part'
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    Write-Log ('Descargando artefacto fijado: ' + $Url) Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $part
    } catch {
        $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
        if (-not $curl) { throw }
        $download = Invoke-Captured $curl.Source @('-L','--fail','--retry','3','--output',$part,$Url) -AllowFailure
        if ($download.ExitCode -ne 0) { throw "No se pudo descargar $Url" }
    }
    if (-not (Test-Path -LiteralPath $part -PathType Leaf)) { throw "No se creo la descarga: $Destination" }
    $actual = Get-Sha256 $part
    if ($actual -ne $ExpectedSha256) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw "SHA-256 incorrecto para $Url. Esperado $ExpectedSha256; obtenido $actual"
    }
    Move-Item -LiteralPath $part -Destination $Destination -Force
    Write-Log ('[DOWNLOAD][VERIFIED] ' + (Split-Path -Leaf $Destination) + ' SHA-256=' + $actual) Green
}

function Expand-ZipFresh([string]$ZipPath, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination -PathType Container) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function Ensure-PakReader([string]$CacheRoot) {
    $runtimeRoot = Join-Path $CacheRoot 'python-pak-v12'
    $downloads = Join-Path $CacheRoot 'downloads'
    $pythonZip = Join-Path $downloads 'python-3.12.10-embed-amd64.zip'
    $wheel = Join-Path $downloads 'pyuepak-0.2.8-py3-none-any.whl'
    $oodle = Join-Path $downloads 'oo2core_9_win64.dll'
    Download-Pinned 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' $pythonZip '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'
    Download-Pinned 'https://files.pythonhosted.org/packages/f8/ec/3efc16113edbcca1c2f50759c17d8be04a2a923d249ce68ba006c1ed1ff6/pyuepak-0.2.8-py3-none-any.whl' $wheel '22628162e755ef2e42a537bbb35a51251a75494af95edaeb4d6baf76007be26c'
    Download-Pinned 'https://github.com/WorkingRobot/OodleUE/raw/refs/heads/main/Engine/Source/Programs/Shared/EpicGames.Oodle/Sdk/2.9.10/win/redist/oo2core_9_win64.dll' $oodle '6f5d41a7892ea6b2db420f2458dad2f84a63901c9a93ce9497337b16c195f457'

    $marker = Join-Path $runtimeRoot 'LANG_ES_FIX_RUNTIME_OK.txt'
    $expectedMarker = 'python=3.12.10;pyuepak=0.2.8;patch=asa-footer-212-fix'
    $valid = (Test-Path -LiteralPath (Join-Path $runtimeRoot 'python.exe') -PathType Leaf) -and
             (Test-Path -LiteralPath (Join-Path $runtimeRoot 'lib\pyuepak\pak.py') -PathType Leaf) -and
             (Test-Path -LiteralPath $marker -PathType Leaf) -and
             ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $expectedMarker)
    if (-not $valid) {
        Write-Log 'Preparando lector PAK V12 aislado...' Cyan
        Expand-ZipFresh $pythonZip $runtimeRoot
        $lib = Join-Path $runtimeRoot 'lib'
        New-Item -ItemType Directory -Path $lib -Force | Out-Null
        $wheelCopy = Join-Path $runtimeRoot 'pyuepak.zip'
        Copy-Item -LiteralPath $wheel -Destination $wheelCopy -Force
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($wheelCopy, $lib)
        Remove-Item -LiteralPath $wheelCopy -Force

        $footerPath = Join-Path $lib 'pyuepak\footer.py'
        $footer = [IO.File]::ReadAllText($footerPath)
        $needle = '    reader.set_pos(size - 204)  # Version 8B, 10, 11, 13'
        if (-not $footer.Contains($needle)) { throw 'pyuepak no coincide con la revision fijada: footer.py inesperado.' }
        $replacement = @'
    reader.set_pos(size - 212)  # ASA UE5.5+: 8 bytes extra al final del footer
    magic = reader.uint32()
    if magic == PAK_MAGIC:
        return PakVersion(reader.uint32() + 1)

    reader.set_pos(size - 204)  # Version 8B, 10, 11, 13
'@
        $footer = $footer.Replace($needle, $replacement.TrimEnd("`r","`n"))
        $footer = $footer.Replace('            reader.set_pos(221, SEEK_END)', '            reader.set_pos(229 if self.version == PakVersion.V12 else 221, SEEK_END)')
        [IO.File]::WriteAllText($footerPath, $footer, [Text.UTF8Encoding]::new($false))

        foreach ($relative in @('pyuepak\entry.py','pyuepak\index.py')) {
            $cryptoPath = Join-Path $lib $relative
            $crypto = [IO.File]::ReadAllText($cryptoPath)
            $nl = if ($crypto.Contains("`r`n")) { "`r`n" } else { "`n" }
            if ($relative -like '*entry.py') {
                $old = 'from cryptography.hazmat.backends import default_backend' + $nl + 'from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes'
            } else {
                $old = 'from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes' + $nl + 'from cryptography.hazmat.backends import default_backend'
            }
            if (-not $crypto.Contains($old)) { throw "pyuepak no coincide con la revision fijada: $relative inesperado." }
            $new = 'try:' + $nl + '    from cryptography.hazmat.backends import default_backend' + $nl + '    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes' + $nl + 'except ImportError:' + $nl + '    default_backend = Cipher = algorithms = modes = None'
            $crypto = $crypto.Replace($old, $new)
            [IO.File]::WriteAllText($cryptoPath, $crypto, [Text.UTF8Encoding]::new($false))
        }
        Copy-Item -LiteralPath $oodle -Destination (Join-Path $lib 'pyuepak\oo2core_9_win64.dll') -Force
        Write-Utf8NoBom (Join-Path $runtimeRoot 'python312._pth') "python312.zip`r`n.`r`nlib`r`n"
        Write-Utf8NoBom $marker $expectedMarker
    }
    $python = Join-Path $runtimeRoot 'python.exe'
    $check = Invoke-Captured $python @('-c','import pyuepak; print("pyuepak-runtime-ok")')
    if ($check.StdOut -notmatch 'pyuepak-runtime-ok') { throw 'El runtime PAK V12 no supero su autocomprobacion.' }
    return $python
}

function Ensure-Repak([string]$CacheRoot) {
    $downloads = Join-Path $CacheRoot 'downloads'
    $zip = Join-Path $downloads 'repak-0.2.3-windows.zip'
    Download-Pinned 'https://github.com/trumank/repak/releases/download/v0.2.3/repak_cli-x86_64-pc-windows-msvc.zip' $zip '6720d602144d75df477a99d5bedb6ea780997546afc335901d4937cafeaa73fa'
    $dir = Join-Path $CacheRoot 'repak-0.2.3'
    $exe = Join-Path $dir 'repak.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Expand-ZipFresh $zip $dir }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'No se encontro repak.exe en el ZIP verificado.' }
    return $exe
}

function Find-SpecialMods([string]$Root) {
    $definitions = @(
        [pscustomobject]@{ Id='912815'; ExpectedInternal='SDinoVariants'; Role='S-Dino: 61 claves S- se inyectan en ShooterGame.locres' },
        [pscustomobject]@{ Id='928548'; ExpectedInternal='ShinyAscended'; Role='Shiny: hereda nombres base y alias del mismo ShooterGame.locres' }
    )
    $results = New-Object Collections.ArrayList
    foreach ($definition in $definitions) {
        $folder = Get-ChildItem -LiteralPath $Root -Directory -Filter ($definition.Id + '_*') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $folder) {
            [void]$results.Add([pscustomobject]@{ id=$definition.Id; installed=$false; friendly=''; internal=$definition.ExpectedInternal; build=''; version=''; role=$definition.Role; path='' })
            continue
        }
        $pluginFile = Get-ChildItem -LiteralPath $folder.FullName -Filter '*.uplugin' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $friendly = ''
        $version = ''
        $internal = $definition.ExpectedInternal
        if ($pluginFile) {
            try {
                $plugin = Get-Content -LiteralPath $pluginFile.FullName -Raw | ConvertFrom-Json
                $friendly = [string]$plugin.FriendlyName
                $version = [string]$plugin.VersionName
                $internal = [IO.Path]::GetFileNameWithoutExtension($pluginFile.Name)
            } catch {}
        }
        $build = ($folder.Name -split '_',2)[1]
        [void]$results.Add([pscustomobject]@{ id=$definition.Id; installed=$true; friendly=$friendly; internal=$internal; build=$build; version=$version; role=$definition.Role; path=$folder.FullName })
    }
    return @($results)
}

function Install-Transactional([string]$GameRoot, [string]$GeneratedPak, [string]$BuildReport, [string]$MatchesReport) {
    $paksDir = Join-Path $GameRoot 'ShooterGame\Content\Paks'
    $saved = Join-Path $GameRoot 'ShooterGame\Saved'
    $stateDir = Join-Path $saved $StateFolderName
    if (Test-Path -LiteralPath $stateDir) {
        throw 'Ya existe una instalacion FIX gestionada. Usa este mismo BAT y elige REVERTIR antes de reinstalar.'
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $pending = Join-Path $saved ($StateFolderName + '.pending-' + $stamp)
    $disabled = Join-Path $pending 'conflictos_anteriores'
    $destination = Join-Path $paksDir $PakName
    $staged = $destination + '.new'
    $installed = $false
    $originalExisted = $false
    New-Item -ItemType Directory -Path $disabled -Force | Out-Null
    try {
        $patterns = @('LANG_ES_FIX.pak','LANG_ES_FIX_V1.pak','LANG_ES_001_V3_P.pak','LANG_ES_001_P.pak','ASA_ES_Comunidad*_P.pak','ASA_ES_MOD_001_P.pak','ASA_ES_001_P.pak','ASA_ES_001.pak')
        foreach ($pattern in $patterns) {
            foreach ($old in Get-ChildItem -LiteralPath $paksDir -Filter $pattern -File -ErrorAction SilentlyContinue) {
                Move-Item -LiteralPath $old.FullName -Destination (Join-Path $disabled $old.Name) -Force
                Write-Log ('Apartado durante LANG_ES_FIX: ' + $old.Name) Yellow
            }
        }
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Copy-Item -LiteralPath $destination -Destination (Join-Path $pending 'original_destination.pak') -Force
            $originalExisted = $true
        }
        Copy-Item -LiteralPath $GeneratedPak -Destination $staged -Force
        if ((Get-Sha256 $staged) -ne (Get-Sha256 $GeneratedPak)) { throw 'El PAK preparado no coincide con el generado.' }
        if (Test-Path -LiteralPath $destination -PathType Leaf) { Remove-Item -LiteralPath $destination -Force }
        Move-Item -LiteralPath $staged -Destination $destination -Force
        $installed = $true
        $installedHash = Get-Sha256 $destination
        Copy-Item -LiteralPath $GeneratedPak -Destination (Join-Path $pending 'LANG_ES_FIX_P.pak.generado') -Force
        Copy-Item -LiteralPath $BuildReport -Destination (Join-Path $pending 'BUILD_REPORT.txt') -Force
        Copy-Item -LiteralPath $MatchesReport -Destination (Join-Path $pending 'CAMBIOS_VERIFICADOS.csv') -Force
        $state = [pscustomobject][ordered]@{
            state_version=1; release=$Release; revision=$Revision; game_path=$GameRoot
            installed_utc=[DateTime]::UtcNow.ToString('o'); pak_destination=$destination
            installed_sha256=$installedHash; original_destination_existed=$originalExisted
        }
        Write-Utf8NoBom (Join-Path $pending 'install_state.json') ($state | ConvertTo-Json -Depth 6)
        Move-Item -LiteralPath $pending -Destination $stateDir
        Write-Log ('Instalacion transaccional completada: ' + $destination) Green
        return $destination
    } catch {
        Write-Log ('Fallo durante commit; iniciando rollback automatico: ' + $_.Exception.Message) Red
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        if ($installed -and (Test-Path -LiteralPath $destination -PathType Leaf)) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
        $original = Join-Path $pending 'original_destination.pak'
        if ($originalExisted -and (Test-Path -LiteralPath $original -PathType Leaf)) { Copy-Item -LiteralPath $original -Destination $destination -Force }
        if (Test-Path -LiteralPath $disabled -PathType Container) {
            foreach ($old in Get-ChildItem -LiteralPath $disabled -File -ErrorAction SilentlyContinue) {
                Copy-Item -LiteralPath $old.FullName -Destination (Join-Path $paksDir $old.Name) -Force
            }
        }
        throw
    }
}

function Revert-FIX([string]$GameRoot) {
    $paksDir = Join-Path $GameRoot 'ShooterGame\Content\Paks'
    $saved = Join-Path $GameRoot 'ShooterGame\Saved'
    $stateDir = Join-Path $saved $StateFolderName
    $stateFile = Join-Path $stateDir 'install_state.json'
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        Write-Host 'No hay una instalacion FIX gestionada que revertir.' -ForegroundColor Yellow
        return
    }
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $destination = Join-Path $paksDir $PakName
    $archiveRoot = Join-Path $saved 'LANG_ES_FIX_BACKUPS'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archive = Join-Path $archiveRoot ('reversion_fix_' + $stamp)
    New-Item -ItemType Directory -Path $archive -Force | Out-Null
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Copy-Item -LiteralPath $destination -Destination (Join-Path $archive ($PakName + '.antes_de_revertir.bak')) -Force
        Remove-Item -LiteralPath $destination -Force
    }
    $original = Join-Path $stateDir 'original_destination.pak'
    if ($state.original_destination_existed -and (Test-Path -LiteralPath $original -PathType Leaf)) {
        Copy-Item -LiteralPath $original -Destination $destination -Force
    }
    $disabled = Join-Path $stateDir 'conflictos_anteriores'
    if (Test-Path -LiteralPath $disabled -PathType Container) {
        foreach ($old in Get-ChildItem -LiteralPath $disabled -File -ErrorAction SilentlyContinue) {
            $restore = Join-Path $paksDir $old.Name
            if (Test-Path -LiteralPath $restore -PathType Leaf) {
                Copy-Item -LiteralPath $restore -Destination (Join-Path $archive ($old.Name + '.colision.bak')) -Force
            }
            Copy-Item -LiteralPath $old.FullName -Destination $restore -Force
        }
    }
    Move-Item -LiteralPath $stateDir -Destination (Join-Path $archive 'estado_fix') -Force
    Write-Host 'FIX revertida. Se ha restaurado el estado anterior disponible.' -ForegroundColor Green
    Write-Host ('Archivo de seguridad: ' + $archive) -ForegroundColor Cyan
}

# Inicio
if (-not $GamePath) { $GamePath = Find-ArkInstall }
if (-not $GamePath) { $GamePath = Read-Host 'Escribe la carpeta ARK Survival Ascended' }
$GamePath = [Environment]::ExpandEnvironmentVariables($GamePath.Trim().Trim('"'))
$PaksDir = Join-Path $GamePath 'ShooterGame\Content\Paks'
if (-not (Test-Path -LiteralPath $PaksDir -PathType Container)) { throw 'La carpeta indicada no parece una instalacion de ASA.' }
if ($Action -ne 'Diagnostic') { Assert-GameClosed }

if ($Action -eq 'Revert') {
    Revert-FIX $GamePath
    exit 0
}

$PackageRoot = Split-Path -Parent $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PackageRoot
$CompiledCsv = Join-Path $PackageRoot 'source\correcciones_compiladas.csv'
if (-not (Test-Path -LiteralPath $CompiledCsv -PathType Leaf)) { throw 'No se encontro source/correcciones_compiladas.csv.' }
$compiledRows = @(Import-Csv -LiteralPath $CompiledCsv | Where-Object { $_.enabled -eq '1' })
if ($compiledRows.Count -lt 1) { throw 'El CSV no contiene correcciones habilitadas.' }
$duplicates = @($compiledRows | Group-Object { $_.namespace + '/' + $_.key } | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) { throw ('El CSV contiene claves duplicadas: ' + (($duplicates | Select-Object -ExpandProperty Name) -join ', ')) }

$ResultDir = Join-Path $PackageRoot 'RESULTADO_ULTIMA_EJECUCION'
if (Test-Path -LiteralPath $ResultDir -PathType Container) { Remove-Item -LiteralPath $ResultDir -Recurse -Force }
New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null
$script:LogFile = Join-Path $ResultDir 'INSTALACION.log.txt'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkDir = if ($Action -eq 'Diagnostic') {
    Join-Path $ResultDir '_diagnostic_work'
} else {
    Join-Path (Join-Path $GamePath 'ShooterGame\Saved\LANG_ES_FIX_WORK') $stamp
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

Write-Log ("LANG_ES_FIX - accion=$Action revision=$Revision") Cyan
Write-Log ('ASA: ' + $GamePath) Green
Write-Log ('CSV: ' + $CompiledCsv + ' SHA-256=' + (Get-Sha256 $CompiledCsv)) DarkGray
Write-Log ('Preferencias habilitadas: ' + $compiledRows.Count) Cyan

$modsRoot = Join-Path $GamePath 'ShooterGame\Binaries\Win64\ShooterGame\Mods\83374'
$specialMods = if (Test-Path -LiteralPath $modsRoot -PathType Container) { Find-SpecialMods $modsRoot } else { @() }
$modsJson = Join-Path $ResultDir 'MODS_ESPECIALES_DETECTADOS.json'
Write-Utf8NoBom $modsJson ($specialMods | ConvertTo-Json -Depth 5)
foreach ($mod in $specialMods) {
    Write-Log ("[MOD] id=$($mod.id) installed=$($mod.installed) friendly=$($mod.friendly) internal=$($mod.internal) build=$($mod.build)") $(if ($mod.installed) { 'Green' } else { 'Yellow' })
}

$ToolsCache = Join-Path $env:LOCALAPPDATA 'LANG_ES_FIX\tools'
New-Item -ItemType Directory -Path $ToolsCache -Force | Out-Null
$PythonExe = Ensure-PakReader $ToolsCache
$RepakExe = Ensure-Repak $ToolsCache
$Bridge = Join-Path $PSScriptRoot 'pak_bridge.py'
$LocresSource = Join-Path $PSScriptRoot 'LocresPatcher.cs'

$BasePak = Join-Path $PaksDir 'pakchunk0-Windows.pak'
if (-not (Test-Path -LiteralPath $BasePak -PathType Leaf)) { throw 'No existe pakchunk0-Windows.pak.' }
$inventoryResult = Invoke-Captured $PythonExe @($Bridge,'inventory','--pak',$BasePak)
$inventory = $inventoryResult.StdOut.Trim() | ConvertFrom-Json
Write-Log ("PAK base detectado: version_interna=$($inventory.version) entradas=$($inventory.count) locres=$(@($inventory.locres).Count)") Cyan
$SpanishInternal = @($inventory.locres | Where-Object { $_ -ieq 'ShooterGame/Content/Localization/ShooterGame/es/ShooterGame.locres' } | Select-Object -First 1)
$EnglishInternal = @($inventory.locres | Where-Object { $_ -ieq 'ShooterGame/Content/Localization/ShooterGame/en/ShooterGame.locres' } | Select-Object -First 1)
if ($SpanishInternal.Count -eq 0 -or $EnglishInternal.Count -eq 0) { throw 'El PAK V12 no contiene los locres esperados de ShooterGame en es/en.' }

$SpanishOriginal = Join-Path $WorkDir 'ShooterGame.es.original.locres'
$EnglishOriginal = Join-Path $WorkDir 'ShooterGame.en.original.locres'
[void](Invoke-Captured $PythonExe @($Bridge,'extract','--pak',$BasePak,'--internal',$SpanishInternal[0],'--output',$SpanishOriginal))
[void](Invoke-Captured $PythonExe @($Bridge,'extract','--pak',$BasePak,'--internal',$EnglishInternal[0],'--output',$EnglishOriginal))
Write-Log ('LOCRES espanol extraido: bytes=' + (Get-Item -LiteralPath $SpanishOriginal).Length + ' SHA-256=' + (Get-Sha256 $SpanishOriginal)) Green

Add-Type -Path $LocresSource
$PatchedLocres = Join-Path $WorkDir 'ShooterGame.es.fix.locres'
$MatchesReport = Join-Path $ResultDir 'CAMBIOS_VERIFICADOS.csv'
$stats = [LangEsFix.LocresPatcher]::PatchFromCsv($SpanishOriginal,$EnglishOriginal,$CompiledCsv,$PatchedLocres,$MatchesReport,$true)
if ($stats.Requested -ne $compiledRows.Count -or $stats.Verified -ne $compiledRows.Count) {
    throw "Verificacion incompleta: $($stats.Verified)/$($compiledRows.Count)"
}
Write-Log ("LOCRES: originales=$($stats.OriginalEntries) finales=$($stats.FinalEntries) cambiadas=$($stats.Changed) ya_correctas=$($stats.AlreadyCorrect) agregadas=$($stats.Added) verificadas=$($stats.Verified)") Green
Write-Log ("Entradas ajenas al CSV verificadas sin cambios: $($stats.UnrelatedVerified)") Green
Write-Log ("Auditoria inglesa: coincidencias=$($stats.EnglishMatches) distintas=$($stats.EnglishMismatches) ausentes=$($stats.EnglishMissing)") Cyan

$PackRoot = Join-Path $WorkDir 'packroot'
$PackDestination = Join-Path $PackRoot ($SpanishInternal[0] -replace '/', '\')
New-Item -ItemType Directory -Path (Split-Path -Parent $PackDestination) -Force | Out-Null
Copy-Item -LiteralPath $PatchedLocres -Destination $PackDestination -Force
$GeneratedPak = Join-Path $ResultDir $PakName
[void](Invoke-Captured $RepakExe @('pack',$PackRoot,$GeneratedPak,'--mount-point','../../../','--version','V11','--quiet'))
if (-not (Test-Path -LiteralPath $GeneratedPak -PathType Leaf)) { throw 'repak no genero el PAK de idioma.' }
$listResult = Invoke-Captured $RepakExe @('list',$GeneratedPak)
$listed = @($listResult.StdOut -split "`r?`n" | ForEach-Object { $_.Trim().TrimStart('/') } | Where-Object { $_ })
if ($listed -notcontains $SpanishInternal[0]) { throw 'El PAK no contiene la ruta exacta del ShooterGame.locres espanol.' }
$PakHash = Get-Sha256 $GeneratedPak
Write-Log ('PAK validado: ' + $GeneratedPak + ' SHA-256=' + $PakHash) Green

$sCount = @($compiledRows | Where-Object { $_.source -like 'S-*' }).Count
$buildReport = Join-Path $ResultDir 'BUILD_REPORT.txt'
$reportLines = @(
    'LANG_ES_FIX - INFORME FIX',
    ('Revision: ' + $Revision),
    ('Fecha UTC: ' + [DateTime]::UtcNow.ToString('o')),
    ('Accion: ' + $Action),
    ('Juego: ' + $GamePath),
    ('PAK origen V12: ' + $BasePak),
    ('Ruta LOCRES: ' + $SpanishInternal[0]),
    '',
    ('Preferencias CSV: ' + $stats.Requested),
    ('Entradas originales conservadas: ' + $stats.OriginalEntries),
    ('Entradas finales: ' + $stats.FinalEntries),
    ('Valores cambiados: ' + $stats.Changed),
    ('Valores que ya eran correctos: ' + $stats.AlreadyCorrect),
    ('Claves agregadas para mods/variantes: ' + $stats.Added),
    ('Claves verificadas al final: ' + $stats.Verified),
    ('Entradas ajenas al CSV verificadas sin cambios: ' + $stats.UnrelatedVerified),
    ('Claves S-Dino incluidas: ' + $sCount),
    ('Coincidencias con ingles actual: ' + $stats.EnglishMatches),
    ('Fuentes inglesas distintas: ' + $stats.EnglishMismatches),
    ('Claves ausentes del ingles base (mods/variantes): ' + $stats.EnglishMissing),
    '',
    'Compatibilidad especial:',
    '- S-Dino: las claves Content/* de los nombres S- se agregan al ShooterGame.locres oficial completo.',
    '- Shiny: recibe los nombres base y alias parcheados; sus adjetivos dinamicos permanecen bajo control del mod.',
    '- No se modifican activos, Blueprints, UI ni configuraciones de los mods.',
    '',
    ('Python embebido ZIP SHA-256: 4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'),
    ('pyuepak wheel SHA-256: 22628162e755ef2e42a537bbb35a51251a75494af95edaeb4d6baf76007be26c'),
    ('Oodle DLL SHA-256: 6f5d41a7892ea6b2db420f2458dad2f84a63901c9a93ce9497337b16c195f457'),
    ('repak ZIP SHA-256: 6720d602144d75df477a99d5bedb6ea780997546afc335901d4937cafeaa73fa'),
    ('PAK generado SHA-256: ' + $PakHash)
)
Write-Utf8NoBom $buildReport ($reportLines -join "`r`n")

if ($Action -eq 'Diagnostic') {
    Write-Log 'DIAGNOSTICO COMPLETADO: PAK generado y validado, pero no instalado.' Green
    Write-Host ('Resultados: ' + $ResultDir) -ForegroundColor Cyan
    exit 0
}

$installedPath = Install-Transactional $GamePath $GeneratedPak $buildReport $MatchesReport
Add-Content -LiteralPath $buildReport -Value ("`r`nPAK instalado: $installedPath`r`nSHA-256 instalado: " + (Get-Sha256 $installedPath)) -Encoding UTF8
Write-Host ''
Write-Host 'LANG_ES_FIX INSTALADO Y VERIFICADO.' -ForegroundColor Green
Write-Host ('PAK: ' + $installedPath) -ForegroundColor Cyan
Write-Host 'Usa -culture=es. Prueba los nombres del CSV, S-Dino y Shiny.' -ForegroundColor Yellow
Write-Host 'Si no funciona, ejecuta ESTE MISMO BAT y elige REVERTIR.' -ForegroundColor Yellow
