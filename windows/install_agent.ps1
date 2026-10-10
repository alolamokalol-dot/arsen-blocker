<#
================================================================================
 install_agent.ps1   —   УСТАНОВЩИК агента ArsenBlocker
--------------------------------------------------------------------------------
 ЧТО ДЕЛАЕТ ЭТОТ СКРИПТ (по шагам, автоматически):

   1) Проверяет, что запущен от имени администратора.
   2) Создаёт папку C:\ProgramData\ArsenBlocker (папка НЕ удаляется при
      переустановке Windows — настройки и токен сохраняются).
   3) Копирует туда block_agent.ps1.
   4) Закрывает доступ к папке для обычных пользователей (там лежит токен).
   5) Создаёт правило брандмауэра: разрешить входящее подключение на порт
      агента ТОЛЬКО из локальной сети.
   6) Создаёт задачу в Планировщике задач Windows (ArsenBlockerAgent),
      которая запускает агента при включении компьютера от имени SYSTEM
      (у SYSTEM есть права администратора, значит агент сможет завершать
      чужие сессии).
   7) Запускает задачу и показывает: токен доступа и IP-адрес ПК
      (эти два значения нужно ввести в приложении на телефоне).

 КАК ЗАПУСКАТЬ:
   Правый клик на этом файле -> "Выполнить с помощью PowerShell"
   ИЛИ (надёжнее) открой PowerShell от имени администратора и выполни:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\путь\install_agent.ps1"

 УДАЛЕНИЕ:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\путь\install_agent.ps1" -Uninstall
   (настройки и токен при этом сохраняются)
================================================================================
#>

[CmdletBinding()]
param(
    # Порт, на котором агент будет слушать телефон
    [int]$Port = 9099,

    # Если нужен свой токен — вставьте его сюда. Если не указывать,
    # агент создаст случайный токен сам при первом запуске.
    [string]$Token = '',

    # Необязательно: ограничить доступ по MAC-адресу телефона (можно несколько)
    [string[]]$AllowMac = @(),

    # Удалить задачу и правило брандмауэра (файлы настроек останутся)
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$TargetDir = Join-Path $env:ProgramData 'ArsenBlocker'
$TargetScript = Join-Path $TargetDir 'block_agent.ps1'
$ConfigPath = Join-Path $TargetDir 'config.json'
$TaskName = 'ArsenBlockerAgent'
$FirewallRuleName = 'ArsenBlocker Agent (TCP)'

function Write-Step { param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------
#  1. ПРОВЕРКА ПРАВ АДМИНИСТРАТОРА
# ------------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host 'ОШИБКА: скрипт нужно запустить от имени администратора!' -ForegroundColor Red
    Write-Host 'Нажмите правой кнопкой на PowerShell -> "Запуск от имени администратора",' -ForegroundColor Yellow
    Write-Host 'затем повторите команду установки.' -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------------------------------------------
#  2. РЕЖИМ УДАЛЕНИЯ
# ------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Step 'Удаление агента'
    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host 'Задача автозапуска удалена.'
    } catch { Write-Host "Задача не была установлена: $($_.Exception.Message)" }

    try {
        Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
        Write-Host 'Правило брандмауэра удалено.'
    } catch { }

    Write-Host ''
    Write-Host "Файлы настроек оставлены на месте: $TargetDir" -ForegroundColor Green
    Write-Host '(токен и список блокировок сохранены для следующей установки)'
    exit 0
}

# ------------------------------------------------------------------------------
#  3. ПАПКА, КОПИРОВАНИЕ ФАЙЛА АГЕНТА
# ------------------------------------------------------------------------------
Write-Step "Создаю папку $TargetDir"
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

$sourceScript = Join-Path $PSScriptRoot 'block_agent.ps1'
if (-not (Test-Path -LiteralPath $sourceScript)) {
    Write-Host "ОШИБКА: рядом с установщиком нет файла block_agent.ps1 ($sourceScript)" -ForegroundColor Red
    exit 1
}

Write-Step 'Копирую block_agent.ps1'
Copy-Item -LiteralPath $sourceScript -Destination $TargetScript -Force
# Снимаем «блокировку из интернета», если файл был скачан
Unblock-File -LiteralPath $TargetScript -ErrorAction SilentlyContinue
Write-Host "Скопировано: $TargetScript"

# ------------------------------------------------------------------------------
#  4. НАСТРОЙКИ: ПОРТ, ТОКЕН, MAC-ФИЛЬТР
# ------------------------------------------------------------------------------
Write-Step 'Проверяю файл настроек'
if (Test-Path -LiteralPath $ConfigPath) {
    Write-Host "Найден существующий файл настроек — он сохранён: $ConfigPath" -ForegroundColor Green
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.security.token) {
            Write-Host ''
            Write-Host 'ВАШ ТОКЕН ДОСТУПА (нужен для телефона):' -ForegroundColor Yellow
            Write-Host "   $($cfg.security.token)" -ForegroundColor White
        }
        Write-Host "Текущий порт в настройках: $($cfg.listen_port)"
    } catch {
        Write-Host 'Не удалось прочитать существующий config.json — агент пересоздаст его при запуске.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'Файла настроек ещё нет. Агент создаст его при первом запуске.'
}
# Токен/порт из параметров применим чуть позже — когда агент создаст конфиг
$PendingToken = $Token
$PendingMac   = $AllowMac

# ------------------------------------------------------------------------------
#  5. ЗАКРЫВАЕМ ДОСТУП К ПАПКЕ (там лежит токен)
# ------------------------------------------------------------------------------
Write-Step 'Ограничиваю доступ к папке (только SYSTEM и Администраторы)'
try {
    $acl = Get-Acl -LiteralPath $TargetDir
    $acl.SetAccessRuleProtection($true, $false)   # отключаем наследование от C:\ProgramData

    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }

    $rules = @(
        (New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')),
        (New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    )
    foreach ($r in $rules) { $acl.AddAccessRule($r) }
    Set-Acl -LiteralPath $TargetDir -AclObject $acl
    Write-Host 'Права обновлены: обычные пользователи не смогут прочитать токен.'
} catch {
    Write-Host "Не удалось изменить права доступа: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'Это не критично, но токен лучше держать в секрете.' -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
#  6. ПРАВИЛО БРАНДМАУЭРА
# ------------------------------------------------------------------------------
Write-Step "Разрешаю входящие подключения на порт $Port (только локальная сеть)"
try {
    Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $FirewallRuleName `
        -Description 'ArsenBlocker: пульт управления с телефона (только локальная сеть)' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
        -Profile Any -RemoteAddress LocalSubnet | Out-Null
    Write-Host 'Правило создано.'
    Write-Host 'ВАЖНО: доступ разрешён только из локальной сети (Wi-Fi).' -ForegroundColor Yellow
    Write-Host 'Если нужно управлять ПК через интернет — используйте VPN (WireGuard/Tailscale),' -ForegroundColor Yellow
    Write-Host 'открывать порт «наружу» напрямую небезопасно.' -ForegroundColor Yellow
} catch {
    Write-Host "Не удалось создать правило: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
#  7. ЗАДАЧА АВТОЗАПУСКА В ПЛАНИРОВЩИКЕ ЗАДАЧ
# ------------------------------------------------------------------------------
Write-Step 'Создаю задачу автозапуска (Планировщик задач Windows)'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetScript`""

$trigger = New-ScheduledTaskTrigger -AtStartup

# Работаем от имени SYSTEM — у него есть административные права,
# поэтому агент сможет завершать сессии других пользователей.
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $taskPrincipal -Settings $settings `
    -Description 'ArsenBlocker: агент удалённой блокировки учётных записей Windows' | Out-Null

Write-Host "Задача '$TaskName' создана и будет запускаться при включении ПК."

Write-Step 'Запускаю агент сейчас'
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 6

# ------------------------------------------------------------------------------
#  8. ПРИМЕНЯЕМ ТОКЕН / MAC ИЗ ПАРАМЕТРОВ (ЕСЛИ ЗАДАНЫ)
# ------------------------------------------------------------------------------
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfgText = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $cfgObj  = $cfgText | ConvertFrom-Json
        $changed = $false

        if ($cfgObj.listen_port -ne $Port) { $cfgObj.listen_port = $Port; $changed = $true }
        if ($PendingToken -and $cfgObj.security.token -ne $PendingToken) { $cfgObj.security.token = $PendingToken; $changed = $true }
        if ($PendingMac.Count -gt 0) { $cfgObj.security.allowed_macs = $PendingMac; $changed = $true }

        if ($changed) {
            $cfgObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
            Write-Host 'Настройки обновлены.' -ForegroundColor Green
            Restart-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
    } catch { Write-Host "Не удалось обновить настройки: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# ------------------------------------------------------------------------------
#  9. ИТОГОВАЯ ПАМЯТКА
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '==========================================================' -ForegroundColor Green
Write-Host ' ГОТОВО. Что ввести в приложении на телефоне:' -ForegroundColor Green
Write-Host '==========================================================' -ForegroundColor Green

try {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ''
    Write-Host ' ТОКЕН  : ' -NoNewline; Write-Host $cfg.security.token -ForegroundColor Yellow
    Write-Host ' ПОРТ   : ' -NoNewline; Write-Host $cfg.listen_port -ForegroundColor Yellow
    Write-Host " РЕЖИМ  : $($cfg.security.mode)  (hmac = подпись запросов, рекомендуется)"
} catch {
    Write-Host ' Не удалось прочитать настройки — откройте' -ForegroundColor Yellow
    Write-Host " $ConfigPath" -ForegroundColor Yellow
}

Write-Host ''
Write-Host ' IP-АДРЕС ЭТОГО ПК:' -ForegroundColor White
try {
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne '127.0.0.1' } |
        ForEach-Object { Write-Host "   $($_.IPAddress)   ($($_.InterfaceAlias))" -ForegroundColor Yellow }
} catch { }

Write-Host ''
Write-Host ' Проверка работы: в приложении нажмите «Пинг».' -ForegroundColor White
Write-Host " Журнал работы агента: $(Join-Path $TargetDir 'agent.log')" -ForegroundColor White
Write-Host ' Если блокировка не срабатывает — в Планировщике задач очистите историю' -ForegroundColor White
Write-Host " задачи $TaskName и посмотрите её «Последний результат выполнения»." -ForegroundColor White
Write-Host ''
Write-Host ' ВАЖНО: IP-адрес ПК может меняться. Чтобы он был постоянным, закрепите' -ForegroundColor Yellow
Write-Host ' адрес в настройках роутера (DHCP reservation) — иначе придётся смотреть' -ForegroundColor Yellow
Write-Host ' новый IP в приложении каждый раз.' -ForegroundColor Yellow
Write-Host ''