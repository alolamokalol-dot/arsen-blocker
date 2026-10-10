<#
Внутренняя точка входа для ArsenBlockerSetup.exe.
Её запускает собранный EXE, пользователь вручную этот файл не запускает.
PS2EXE извлекает block_agent.ps1 и install_agent.ps1 во временную папку,
после чего этот код передаёт управление установщику.
#>
$ErrorActionPreference = 'Stop'

$bundleDir = Join-Path $env:TEMP 'ArsenBlockerBundle'
$installer = Join-Path $bundleDir 'install_agent.ps1'
$agent = Join-Path $bundleDir 'block_agent.ps1'

if (-not (Test-Path -LiteralPath $installer) -or -not (Test-Path -LiteralPath $agent)) {
    Write-Host "Не удалось подготовить файлы установки. Удалите папку '$bundleDir' и запустите EXE заново." -ForegroundColor Red
    exit 2
}

Write-Host 'ArsenBlocker: устанавливаю агент на этот компьютер.' -ForegroundColor Cyan
Write-Host 'Пожалуйста, не закрывайте это окно, пока установка не завершится.'
Write-Host ''

try {
    # Скрипт установщика выполняется в этом же повышенном процессе.
    # У него $PSScriptRoot указывает на папку с извлечёнными файлами,
    # поэтому он найдёт рядом block_agent.ps1 и скопирует его в ProgramData.
    & $installer
    $result = $LASTEXITCODE
    if ($null -eq $result) { $result = 0 }
    if ($result -ne 0) { exit $result }
} catch {
    Write-Host ''
    Write-Host "Установка не завершилась: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Подробности можно посмотреть в C:\ProgramData\ArsenBlocker\agent.log'
    exit 1
}

Write-Host ''
Write-Host 'Нажмите любую клавишу, чтобы закрыть окно.' -ForegroundColor Cyan
try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 8 }
