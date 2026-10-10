<#
ArsenBlocker: сборка однокнопочного Setup.exe на Windows.

ВАЖНО: этот файл запускается ОДИН РАЗ на Windows-компьютере для сборки.
После сборки пользователь запускает только ArsenBlockerSetup.exe.
Для сборки используется открытый модуль PS2EXE из PowerShell Gallery.

Команда:
  powershell.exe -ExecutionPolicy Bypass -File .\build_setup_exe.ps1

Результат:
  .\dist\ArsenBlockerSetup.exe
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$ProjectDir = Split-Path -Parent $PSScriptRoot
$DistDir = Join-Path $ProjectDir 'dist'
$Entry = Join-Path $PSScriptRoot 'setup_exe_entry.ps1'
$Agent = Join-Path $PSScriptRoot 'block_agent.ps1'
$Installer = Join-Path $PSScriptRoot 'install_agent.ps1'
$OutputExe = Join-Path $DistDir 'ArsenBlockerSetup.exe'

foreach ($path in @($Entry, $Agent, $Installer)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Не найден обязательный файл: $path" }
}

New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

# PS2EXE встраивает оба скрипта в EXE и извлекает их во временную папку
# при запуске. В сам EXE не вшиваются токены и другие секреты.
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Устанавливаю открытый модуль PS2EXE из PowerShell Gallery...'
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -ErrorAction Stop

$embedded = @{
    '%TEMP%\ArsenBlockerBundle\block_agent.ps1' = $Agent
    '%TEMP%\ArsenBlockerBundle\install_agent.ps1' = $Installer
}

Write-Host 'Собираю установщик. Подождите...'
Invoke-PS2EXE -inputFile $Entry -outputFile $OutputExe `
    -embedFiles $embedded `
    -requireAdmin `
    -title 'ArsenBlocker Setup' `
    -description 'Однокнопочная установка агента ArsenBlocker для своего ПК' `
    -company 'ArsenBlocker' `
    -product 'ArsenBlocker Setup' `
    -version '1.0.0.0'

if (-not (Test-Path -LiteralPath $OutputExe)) { throw 'EXE не создан. Проверьте вывод PS2EXE выше.' }
Write-Host ''
Write-Host "ГОТОВО: $OutputExe" -ForegroundColor Green
Write-Host 'Теперь достаточно передать ArsenBlockerSetup.exe и дважды нажать на него.'
Write-Host 'Windows покажет стандартный запрос UAC — подтвердите его.'
Write-Host 'Примечание: EXE не подписан сертификатом, поэтому SmartScreen может показывать предупреждение.' -ForegroundColor Yellow
Write-Host 'В EXE встроены исходные PowerShell-скрипты: это упаковка, а не защита от извлечения.' -ForegroundColor Yellow