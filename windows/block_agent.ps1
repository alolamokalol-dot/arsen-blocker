<#
================================================================================
 block_agent.ps1   —   «Сервер» (агент) для ПК с Windows
 Система: ArsenBlocker   |   Версия: 1.0.0   |   Протокол: v1
--------------------------------------------------------------------------------
 ЧТО ДЕЛАЕТ ЭТОТ СКРИПТ (простыми словами):

   1) Слушает TCP-порт (по умолчанию 9099) и принимает команды от телефона.
   2) По команде "block" НЕМЕДЛЕННО завершает активную сессию указанного
      пользователя Windows (команда logoff) и ставит «флаг блокировки»
      на заданное число минут.
   3) Каждые несколько секунд проверяет: не вошёл ли заблокированный
      пользователь снова? Если вошёл — снова завершает его сессию,
      пока время блокировки не истекло.
   4) Хранит список блокировок в файле config.json, поэтому блокировка
      НЕ теряется при перезагрузке ПК или перезапуске агента.
   5) Пишет журнал (лог) всех действий в файл agent.log.

 ЧТО ВАЖНО ЗНАТЬ:
   • Скрипт нужно запускать от имени Администратора (или от SYSTEM через
     Планировщик задач). Иначе Windows не даст завершить чужую сессию.
   • Пользователи из списка protected_users (администратор, SYSTEM и т.п.)
     защищены от блокировки — это «аварийный тормоз», чтобы нельзя было
     случайно заблокировать сам ПК.
   • Файл конфигурации лежит в C:\ProgramData\ArsenBlocker\config.json —
     эта папка НЕ удаляется при переустановке системы, поэтому настройки
     и токен сохраняются.

 ЗАПУСК ВРУЧНУЮ (для проверки):
   Откройте PowerShell от имени администратора и выполните:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ArsenBlocker\block_agent.ps1"

 ОСТАНОВКА: нажмите Ctrl+C в окне, или остановите задачу в Планировщике.
================================================================================
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    # Где лежит файл настроек. По умолчанию — C:\ProgramData\ArsenBlocker\config.json
    [string]$ConfigPath = (Join-Path $env:ProgramData 'ArsenBlocker\config.json'),

    # Показывать всё происходящее в окне консоли (удобно при первой настройке)
    [switch]$Verbose_Console
)

# ==============================================================================
#  1. ОБЩИЕ ПЕРЕМЕННЫЕ И КОНСТАНТЫ
# ==============================================================================

$script:AgentVersion  = '1.0.0'
$script:ProtocolVer   = 'v1'
$script:StartedAt     = Get-Date
$script:ConfigPath    = $ConfigPath
$script:ConfigDir     = Split-Path -Parent $ConfigPath
$script:LogPath       = Join-Path (Split-Path -Parent $ConfigPath) 'agent.log'

# В этой таблице храним активные блокировки:  логин(в нижнем регистре) -> время окончания (Unix-секунды)
$script:Blocked       = @{}
$script:Config        = @{}

# ==============================================================================
#  2. ФУНКЦИИ ДЛЯ ЗАПИСИ В ЖУРНАЛ (ЛОГ)
# ==============================================================================

function Write-AgentLog {
    <#
      Записывает строку в журнал работы агента и (по желанию) в окно консоли.
      Не выбрасывает ошибок — если лог не удалось записать, работа продолжается.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "$stamp [$Level] $Message"

    if ($Verbose_Console -or $Level -ne 'DEBUG') { Write-Host $line }

    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        # Простая ротация: если журнал больше 5 МБ — переименовываем в agent.log.1
        if ((Test-Path -LiteralPath $script:LogPath) -and
            ((Get-Item -LiteralPath $script:LogPath).Length -gt 5MB)) {
            $old = "$($script:LogPath).1"
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $script:LogPath -Destination $old -Force -ErrorAction SilentlyContinue
        }
        # Пишем в UTF-8 без BOM, чтобы русский текст читался в блокноте
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, $enc)
    } catch {
        # намеренно молчим: проблемы с логом не должны ронять агент
    }
}

# ==============================================================================
#  3. НАСТРОЙКИ (config.json) — ЧТЕНИЕ, СОЗДАНИЕ, СОХРАНЕНИЕ
# ==============================================================================

function ConvertTo-HashtableDeep {
    <#
      Превращает прочитанный JSON в «вложенные таблицы» (hashtable).
      С ними в PowerShell работать проще, чем с объектами.
    #>
    param([Parameter(ValueFromPipeline = $true)]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = @{}
            foreach ($key in $InputObject.Keys) { $result[$key] = ConvertTo-HashtableDeep $InputObject[$key] }
            return $result
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $result = @{}
            foreach ($prop in $InputObject.PSObject.Properties) { $result[$prop.Name] = ConvertTo-HashtableDeep $prop.Value }
            return $result
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
            return @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
        }
        return $InputObject
    }
}

function New-RandomToken {
    <#
      Создаёт случайный «токен доступа» (пароль) длиной 48 символов.
      Именно он вводится в телефоне — без него агент не принимает команды.
    #>
    $bytes   = New-Object byte[] 24
    $rng     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-DefaultConfig {
    <#
      Настройки по умолчанию (применяются, если в config.json чего-то нет).
    #>
    return @{
        listen_port            = 9099
        bind_address           = '0.0.0.0'
        check_interval_seconds = 5
        max_block_minutes      = 1440          # максимум 24 часа за одну команду (защита от «вечной» блокировки)
        protect_admins         = $true         # блокировка админской учётки требует флага force
        protected_users        = @(
            'Administrator', 'Администратор', 'SYSTEM', 'DefaultAccount',
            'WDAGUtilityAccount', 'Гость', 'Guest'
        )
        security               = @{
            mode                 = 'hmac'      # 'hmac' — подпись запроса, 'token' — просто токен
            token                = ''
            max_clock_skew_seconds = 120       # допустимая разница часов телефона и ПК
            allowed_macs         = @()         # пусто = пускать с любого телефона в сети
        }
        log_level              = 'INFO'
        blocked                = @{}            # заполняется автоматически
        comment                = 'Файл настроек ArsenBlocker. Сохраняйте резервную копию: в нём лежит ваш токен.'
    }
}

function Merge-ConfigDeep {
    <#
      Дополняет пользовательские настройки значениями по умолчанию.
      Так старые конфиги продолжают работать после обновления программы.
    #>
    param([hashtable]$Base, [hashtable]$Defaults)

    foreach ($key in $Defaults.Keys) {
        if (-not $Base.ContainsKey($key) -or $null -eq $Base[$key]) {
            $Base[$key] = $Defaults[$key]
        } elseif ($Base[$key] -is [hashtable] -and $Defaults[$key] -is [hashtable]) {
            $Base[$key] = Merge-ConfigDeep -Base $Base[$key] -Defaults $Defaults[$key]
        }
    }
    return $Base
}

function Save-AgentConfig {
    <#
      Сохраняет текущие настройки (включая список активных блокировок) на диск.
      Файл пишется во временный файл и затем подменяется — так конфиг не
      «побьётся», даже если выключить питание в момент записи.
    #>
    $script:Config['blocked'] = $script:Blocked

    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $json = $script:Config | ConvertTo-Json -Depth 8
        $enc  = New-Object System.Text.UTF8Encoding($false)
        $tmp  = "$($script:ConfigPath).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, $enc)
        Move-Item -LiteralPath $tmp -Destination $script:ConfigPath -Force
    } catch {
        Write-AgentLog "Не удалось сохранить настройки: $($_.Exception.Message)" 'ERROR'
    }
}

function Initialize-AgentConfig {
    <#
      Загружает настройки с диска. Если файла нет — создаёт новый
      со случайным токеном и подсказкой, что делать дальше.
    #>
    $defaults = Get-DefaultConfig

    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $raw      = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
            $loaded   = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
            if ($null -eq $loaded) { $loaded = @{} }
            $script:Config = Merge-ConfigDeep -Base $loaded -Defaults $defaults
            Write-AgentLog "Настройки загружены: $($script:ConfigPath)"
        } catch {
            # Конфиг повреждён — не теряем его, переименовываем и создаём новый
            $broken = "$($script:ConfigPath).broken_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Move-Item -LiteralPath $script:ConfigPath -Destination $broken -Force -ErrorAction SilentlyContinue
            Write-AgentLog "Файл настроек повреждён, сохранён как $broken. Создан новый." 'ERROR'
            $script:Config = $defaults
        }
    } else {
        $script:Config = $defaults
        Write-AgentLog 'Файл настроек не найден — создаю новый.' 'WARN'
    }

    # Гарантируем наличие токена
    if ([string]::IsNullOrWhiteSpace($script:Config['security']['token'])) {
        $script:Config['security']['token'] = New-RandomToken
        Write-AgentLog 'Сгенерирован новый токен доступа.'
        Write-AgentLog "ВАШ ТОКЕН (введите его в приложении на телефоне): $($script:Config['security']['token'])" 'WARN'
    }

    # Загружаем сохранённые блокировки в память
    $script:Blocked = @{}
    if ($script:Config['blocked'] -is [hashtable]) {
        foreach ($key in $script:Config['blocked'].Keys) {
            $until = 0
            [void][int64]::TryParse([string]$script:Config['blocked'][$key], [ref]$until)
            if ($until -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
                $script:Blocked[$key.ToLower()] = $until
            }
        }
    }

    Save-AgentConfig
}

# ==============================================================================
#  4. РАБОТА С ПОЛЬЗОВАТЕЛЯМИ И СЕССИЯМИ WINDOWS
# ==============================================================================

function Get-NormalizedUser {
    <#
      Приводит имя пользователя к «единому виду» для сравнения.
      Например:  "HOME-PC\Arsen"  ->  "arsen"
    #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $plain = ($Name -split '\\')[-1]
    return $plain.Trim().ToLowerInvariant()
}

function Get-ActiveSessions {
    <#
      Возвращает список АКТИВНЫХ сессий (кто прямо сейчас вошёл в Windows).

      Как это работает:
        • Основной способ — ищем процессы explorer.exe (рабочий стол) и узнаём,
          какому пользователю и какой сессии Windows они принадлежат.
          Этот способ не зависит от языка Windows (русский/английский).
        • Дополнительно разбираем вывод команды "query session" — на случай
          RDP-подключений без рабочего стола.
    #>
    $sessions = @()

    # --- Способ 1: explorer.exe → владелец процесса + номер сессии ---
    try {
        $explorers = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop
        foreach ($proc in $explorers) {
            $owner = $null
            try { $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop } catch { }
            if ($null -eq $owner -or [string]::IsNullOrWhiteSpace($owner.User)) { continue }

            $sessions += [pscustomobject]@{
                User      = $owner.User
                Domain    = $owner.Domain
                SessionId = [int]$proc.SessionId
                State     = 'Active'
                Source    = 'explorer'
            }
        }
    } catch {
        Write-AgentLog "Не удалось получить список процессов explorer.exe: $($_.Exception.Message)" 'WARN'
    }

    # --- Способ 2: разбор вывода "query session" (дополняет способ 1) ---
    try {
        $knownNames = @('services', 'служба', 'console', 'консоль', 'sessionname', 'имя')
        $raw = (& query.exe session 2>$null | Out-String)
        foreach ($line in ($raw -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            # Строка текущей сессии начинается с символа ">"
            $clean = ($line -replace '^\s*>', '').Trim()
            if ($clean -match '^-+$' -or $clean -match '^\s*$') { continue }

            $parts = $clean -split '\s+'
            $name  = $parts[0]
            if ($knownNames -contains $name.ToLowerInvariant()) { continue }
            if ($name -match '^(rdp|console)') { continue }
            if ($name -match '^#?\d+$') { continue }   # строки без логина

            # Номер сессии — первое «чисто числовое» поле в строке
            $sid = $null
            foreach ($p in $parts) { if ($p -match '^\d+$') { $sid = [int]$p; break } }
            if ($null -eq $sid -or $sid -eq 0) { continue }

            $sessions += [pscustomobject]@{
                User      = $name
                Domain    = ''
                SessionId = $sid
                State     = 'Active'
                Source    = 'query'
            }
        }
    } catch {
        Write-AgentLog "Команда 'query session' недоступна: $($_.Exception.Message)" 'DEBUG'
    }

    # Убираем дубли по номеру сессии
    $unique = @{}
    foreach ($s in $sessions) { $unique[$s.SessionId] = $s }
    return @($unique.Values)
}

function Get-ProfileList {
    <#
      Возвращает список ВСЕХ локальных профилей Windows (для отображения в телефоне).
      Дополнительно отмечает, кто сейчас активен и кто заблокирован.

      Возвращает массив объектов: { user, display, sid, active, session_id, blocked_until }
    #>
    $sessions = Get-ActiveSessions
    $now      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $result   = @{}

    # Профили пользователей из системы
    try {
        $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop
        foreach ($p in $profiles) {
            if ($p.Special) { continue }                       # служебные профили
            if ($p.SID -match '-18$|-19$|-20$') { continue }   # SYSTEM, LocalService, NetworkService

            $name = $null
            try {
                $name = (New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value
            } catch { }
            if ([string]::IsNullOrWhiteSpace($name)) {
                # Если имя не определить — берём название папки профиля
                if ($p.LocalPath) { $name = Split-Path -Leaf $p.LocalPath }
            }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $key  = Get-NormalizedUser $name
            $user = ($name -split '\\')[-1]
            if ($user.EndsWith('$')) { continue }              # скрытые/машинные учётки

            $result[$key] = [ordered]@{
                user          = $user
                display       = $name
                sid           = $p.SID
                loaded        = [bool]$p.Loaded
                active        = $false
                session_id    = $null
                blocked_until = $null
                remaining_min = 0
            }
        }
    } catch {
        Write-AgentLog "Не удалось прочитать список профилей: $($_.Exception.Message)" 'WARN'
    }

    # Добавляем пользователей, которые активны, но профиль найти не удалось
    foreach ($s in $sessions) {
        $key = Get-NormalizedUser $s.User
        if (-not $result.ContainsKey($key)) {
            $result[$key] = [ordered]@{
                user = $s.User; display = $s.User; sid = ''; loaded = $true
                active = $false; session_id = $null; blocked_until = $null; remaining_min = 0
            }
        }
        $result[$key]['active']     = $true
        $result[$key]['session_id'] = $s.SessionId
        $result[$key]['loaded']     = $true
    }

    # Отмечаем блокировки
    foreach ($key in $script:Blocked.Keys) {
        if ($result.ContainsKey($key)) {
            $result[$key]['blocked_until'] = $script:Blocked[$key]
            $result[$key]['remaining_min'] = [math]::Ceiling(($script:Blocked[$key] - $now) / 60)
        }
    }

    return @($result.Values | Sort-Object { $_.display })
}

function Invoke-LogoffSession {
    <#
      Завершает сессию пользователя (аналог «Завершить сеанс» в диспетчере задач).
      Сначала пробуем по НОМЕРУ сессии — этот способ не зависит от языка Windows,
      а если не получилось — пробуем по имени пользователя.
      Возвращает $true, если сессия закрыта.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$SessionId,
        [string]$UserName = ''
    )

    if ($SessionId -le 0) { return $false }   # сессия 0 — системная, трогать нельзя!

    try {
        $out = & logoff.exe $SessionId 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-AgentLog "Сессия $SessionId завершена (logoff по номеру сессии)."
            return $true
        }
        Write-AgentLog "logoff $SessionId вернул код $LASTEXITCODE : $out" 'WARN'
    } catch {
        Write-AgentLog "Ошибка вызова logoff для сессии $SessionId : $($_.Exception.Message)" 'WARN'
    }

    # Резервный вариант — по имени пользователя
    if (-not [string]::IsNullOrWhiteSpace($UserName)) {
        try {
            $out = & logoff.exe $UserName 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-AgentLog "Сессия пользователя $UserName завершена (logoff по имени)."
                return $true
            }
            Write-AgentLog "logoff $UserName вернул код $LASTEXITCODE : $out" 'WARN'
        } catch {
            Write-AgentLog "Ошибка вызова logoff для $UserName : $($_.Exception.Message)" 'WARN'
        }
    }
    return $false
}

function Test-ProtectedUser {
    <#
      Проверяет, входит ли пользователь в «защищённый» список
      (этих пользователей блокировать нельзя).
    #>
    param([string]$User)
    $key = Get-NormalizedUser $User
    foreach ($p in @($script:Config['protected_users'])) {
        if ((Get-NormalizedUser $p) -eq $key) { return $true }
    }
    return $false
}

function Test-IsAdminAccount {
    <#
      Проверяет, входит ли пользователь в группу «Администраторы».
      Нужно для дополнительной защиты: блокировать админа можно только
      с явным подтверждением (поле force=true).
    #>
    param([string]$User)
    $key = Get-NormalizedUser $User
    $groupNames = @('Administrators', 'Администраторы')
    foreach ($g in $groupNames) {
        try {
            $members = Get-LocalGroupMember -Group $g -ErrorAction Stop
            foreach ($m in $members) {
                if ((Get-NormalizedUser $m.Name) -eq $key) { return $true }
            }
        } catch { }
    }
    return $false
}

# ==============================================================================
#  5. ЛОГИКА БЛОКИРОВКИ
# ==============================================================================

function Block-User {
    <#
      Ставит блокировку и немедленно выкидывает пользователя из системы.
        User    — логин Windows (например, "arsen")
        Minutes — на сколько минут блокировать
      Возвращает текст результата для ответа телефону.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][int]$Minutes
    )

    if ($Minutes -le 0) { return (Unblock-User -User $User) }

    $maxMinutes = [int]$script:Config['max_block_minutes']
    if ($Minutes -gt $maxMinutes) {
        $Minutes = $maxMinutes
        Write-AgentLog "Запрошено слишком долгое время блокировки — ограничено до $maxMinutes мин." 'WARN'
    }

    $key  = Get-NormalizedUser $User
    $name = ($User -split '\\')[-1]

    if (Test-ProtectedUser $name) {
        Write-AgentLog "Отказано: пользователь '$name' находится в защищённом списке." 'WARN'
        return "ОТКАЗ: пользователь '$name' защищён настройками и не может быть заблокирован."
    }

    $until = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ($Minutes * 60)
    $script:Blocked[$key] = $until
    Save-AgentConfig

    Write-AgentLog "БЛОКИРОВКА: '$name' до $((Get-Date).AddMinutes($Minutes).ToString('yyyy-MM-dd HH:mm:ss')) ($Minutes мин.)"

    # Немедленно завершаем активные сессии этого пользователя
    $kicked = 0
    foreach ($s in (Get-ActiveSessions)) {
        if ((Get-NormalizedUser $s.User) -eq $key) {
            if (Invoke-LogoffSession -SessionId $s.SessionId -UserName $s.User) { $kicked++ }
        }
    }

    return "Пользователь '$name' заблокирован на $Minutes мин. Завершено активных сессий: $kicked."
}

function Unblock-User {
    <#
      Снимает блокировку. Если передать User = "*", снимаются все блокировки.
    #>
    param([Parameter(Mandatory = $true)][string]$User)

    if ($User -eq '*') {
        $count = $script:Blocked.Count
        $script:Blocked.Clear()
        Save-AgentConfig
        Write-AgentLog "Сняты ВСЕ блокировки ($count шт.)." 'WARN'
        return "Сняты все блокировки ($count шт.)."
    }

    $key  = Get-NormalizedUser $User
    $name = ($User -split '\\')[-1]
    if ($script:Blocked.ContainsKey($key)) {
        $script:Blocked.Remove($key)
        Save-AgentConfig
        Write-AgentLog "Блокировка снята: '$name'."
        return "Блокировка с пользователя '$name' снята."
    }
    return "Пользователь '$name' не был заблокирован."
}

function Invoke-BlockEnforcement {
    <#
      «Сторож»: выполняется каждые несколько секунд.
        1) Убирает истёкшие блокировки.
        2) Если заблокированный пользователь снова вошёл в Windows —
           снова завершает его сессию.

      Это и есть механизм «запрета входа»: Windows не даёт штатного способа
      запретить вход на время без удаления/отключения учётной записи,
      поэтому агент просто выкидывает пользователя каждый раз, как он войдёт.
    #>
    $now     = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $changed = $false

    # 1) истёкшие блокировки
    foreach ($key in @($script:Blocked.Keys)) {
        if ($script:Blocked[$key] -le $now) {
            $script:Blocked.Remove($key)
            $changed = $true
            Write-AgentLog "Блокировка истекла: '$key' — вход снова разрешён."
        }
    }
    if ($changed) { Save-AgentConfig }

    if ($script:Blocked.Count -eq 0) { return }

    # 2) выкидываем тех, кто вошёл, хотя заблокирован
    foreach ($s in (Get-ActiveSessions)) {
        $key = Get-NormalizedUser $s.User
        if ($script:Blocked.ContainsKey($key)) {
            $minsLeft = [math]::Ceiling(($script:Blocked[$key] - $now) / 60)
            Write-AgentLog "Заблокированный '$($s.User)' снова вошёл — завершаю сессию $($s.SessionId) (осталось $minsLeft мин.)." 'WARN'
            [void](Invoke-LogoffSession -SessionId $s.SessionId -UserName $s.User)
        }
    }
}

# ==============================================================================
#  6. БЕЗОПАСНОСТЬ: ПРОВЕРКА ПОДЛИННОСТИ ЗАПРОСА
# ==============================================================================

function Get-CanonicalString {
    <#
      Формирует строку, которую подписывает телефон (HMAC-SHA256).
      Формат ОБЯЗАТЕЛЬНО одинаковый на всех устройствах:
          v1|команда|пользователь|минуты|метка_времени|одноразовый_код
    #>
    param([hashtable]$Request)

    $cmd     = ([string]$Request['cmd']).ToLowerInvariant()
    $user    = [string]$Request['user']
    $minutes = 0
    if ($Request.ContainsKey('minutes')) { [void][int]::TryParse([string]$Request['minutes'], [ref]$minutes) }
    $ts      = [string]$Request['ts']
    $nonce   = [string]$Request['nonce']

    return "$($script:ProtocolVer)|$cmd|$user|$minutes|$ts|$nonce"
}

function Get-HmacSignature {
    <#
      Считает подпись HMAC-SHA256 и возвращает её в виде шестнадцатеричной строки.
    #>
    param([string]$Text, [string]$Key)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-MacAddress {
    <#
      Определяет MAC-адрес устройства по его IP (нужно, если вы ограничили
      доступ списком MAC-адресов телефона). Если определить не удалось — ''.
    #>
    param([string]$IpAddress)

    try {
        $neighbor = Get-NetNeighbor -IPAddress $IpAddress -ErrorAction Stop
        if ($neighbor) { return ([string]($neighbor | Select-Object -First 1).LinkLayerAddress) }
    } catch { }

    try {
        $arp = (& arp.exe -a $IpAddress 2>$null | Out-String)
        if ($arp -match '(?i)([0-9a-f]{2}[-:]){5}[0-9a-f]{2}') { return $Matches[0] }
    } catch { }

    return ''
}

function Test-RequestAuth {
    <#
      Проверяет, можно ли доверять запросу. Возвращает таблицу:
          @{ ok = $true/$false; reason = 'текст причины' }
    #>
    param([hashtable]$Request, [string]$RemoteIp)

    $sec = $script:Config['security']
    $token = [string]$sec['token']

    # --- 1. Проверка MAC-адреса (если список не пустой) ---
    $allowedMacs = @($sec['allowed_macs'])
    if ($allowedMacs.Count -gt 0) {
        $mac = (Get-MacAddress -IpAddress $RemoteIp).Replace('-', '').Replace(':', '').Replace('.', '').ToLowerInvariant()
        $allowed = $false
        foreach ($m in $allowedMacs) {
            $mNorm = ([string]$m).Replace('-', '').Replace(':', '').Replace('.', '').ToLowerInvariant()
            if ($mNorm -eq $mac) { $allowed = $true; break }
        }
        if (-not $allowed) {
            return @{ ok = $false; reason = "MAC-адрес $mac не в списке разрешённых" }
        }
    }

    # --- 2. Проверка подписи или токена ---
    if ([string]$sec['mode'] -eq 'token') {
        if ([string]$Request['token'] -cne $token) {
            return @{ ok = $false; reason = 'неверный токен доступа' }
        }
        return @{ ok = $true; reason = '' }
    }

    # Режим HMAC (по умолчанию)
    $ts = 0
    [void][int64]::TryParse([string]$Request['ts'], [ref]$ts)
    if ($ts -le 0) { return @{ ok = $false; reason = 'в запросе нет метки времени ts' } }

    $skew = [math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ts)
    $maxSkew = [int]$sec['max_clock_skew_seconds']
    if ($skew -gt $maxSkew) {
        return @{ ok = $false; reason = "часы телефона и ПК расходятся на $skew сек. (допустимо $maxSkew). Проверьте время и часовой пояс." }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Request['nonce'])) {
        return @{ ok = $false; reason = 'в запросе нет одноразового кода nonce' }
    }

    $expected = Get-HmacSignature -Text (Get-CanonicalString -Request $Request) -Key $token
    $got      = ([string]$Request['sig']).Trim().ToLowerInvariant()
    if ($got -ne $expected) {
        return @{ ok = $false; reason = 'подпись запроса не совпадает (проверьте токен)' }
    }
    return @{ ok = $true; reason = '' }
}

# ==============================================================================
#  7. ОБРАБОТКА КОМАНД ОТ ТЕЛЕФОНА
# ==============================================================================

function Invoke-AgentCommand {
    <#
      Выполняет одну команду и возвращает объект-ответ для телефона.
    #>
    param([hashtable]$Request)

    $cmd = ([string]$Request['cmd']).ToLowerInvariant()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    switch ($cmd) {

        'ping' {
            return @{ ok = $true; message = 'агент на связи'; data = @{
                agent = $script:AgentVersion; protocol = $script:ProtocolVer
                computer = $env:COMPUTERNAME; time = $now
            } }
        }

        'info' {
            return @{ ok = $true; message = 'информация об агенте'; data = @{
                agent            = $script:AgentVersion
                protocol         = $script:ProtocolVer
                computer         = $env:COMPUTERNAME
                port             = $script:Config['listen_port']
                security_mode    = $script:Config['security']['mode']
                check_interval   = $script:Config['check_interval_seconds']
                max_block_minutes = $script:Config['max_block_minutes']
                protected_users  = @($script:Config['protected_users'])
                uptime_minutes   = [math]::Round(((Get-Date) - $script:StartedAt).TotalMinutes, 1)
            } }
        }

        'users' {
            return @{ ok = $true; message = 'список пользователей'; data = @{ users = @(Get-ProfileList) } }
        }

        'status' {
            $list = @()
            foreach ($key in $script:Blocked.Keys) {
                $list += @{
                    user          = $key
                    until_unix    = $script:Blocked[$key]
                    until_local   = ([DateTimeOffset]::FromUnixTimeSeconds($script:Blocked[$key]).ToLocalTime()).ToString('yyyy-MM-dd HH:mm:ss')
                    remaining_min = [math]::Ceiling(($script:Blocked[$key] - $now) / 60)
                }
            }
            return @{ ok = $true; message = "активных блокировок: $($list.Count)"; data = @{
                blocked = $list
                active_sessions = @(Get-ActiveSessions)
            } }
        }

        'block' {
            $user = [string]$Request['user']
            if ([string]::IsNullOrWhiteSpace($user)) { return @{ ok = $false; message = 'не указан пользователь' } }

            $minutes = 0
            [void][int]::TryParse([string]$Request['minutes'], [ref]$minutes)
            if ($minutes -le 0) { return @{ ok = $false; message = 'не указано время блокировки (минуты > 0)' } }

            # Защита от блокировки администратора без явного подтверждения
            if ($script:Config['protect_admins'] -and (Test-IsAdminAccount $user)) {
                $force = $false
                if ($Request.ContainsKey('force')) { $force = [bool]$Request['force'] }
                if (-not $force) {
                    return @{ ok = $false; message = "Пользователь '$user' — администратор. Повторите с подтверждением (force=true)." }
                }
            }

            $text = Block-User -User $user -Minutes $minutes
            return @{ ok = ($text -notmatch '^ОТКАЗ'); message = $text }
        }

        'unblock' {
            $user = [string]$Request['user']
            if ([string]::IsNullOrWhiteSpace($user)) { $user = '*' }
            return @{ ok = $true; message = (Unblock-User -User $user) }
        }

        default {
            return @{ ok = $false; message = "неизвестная команда: '$cmd' (доступны: ping, info, users, status, block, unblock)" }
        }
    }
}

# ==============================================================================
#  8. СЕТЕВОЙ СЛОЙ (TCP-сервер)
# ==============================================================================

function Receive-ClientLine {
    <#
      Читает одну строку из сети (сообщение заканчивается символом перевода строки).
      Возвращает $null, если ничего не пришло или клиент отключился.
    #>
    param([System.Net.Sockets.TcpClient]$Client, [int]$TimeoutMs = 10000)

    $stream = $Client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $buffer = New-Object byte[] 4096
    $memory = New-Object System.IO.MemoryStream
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

    while ((Get-Date) -lt $deadline) {
        $read = 0
        try { $read = $stream.Read($buffer, 0, $buffer.Length) } catch { return $null }
        if ($read -le 0) { break }
        $memory.Write($buffer, 0, $read)

        $text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
        $idx  = $text.IndexOf("`n")
        if ($idx -ge 0) { return $text.Substring(0, $idx).Trim() }

        if ($memory.Length -gt 65536) { return $null }   # защита от слишком больших сообщений
    }
    return $null
}

function Send-AgentResponse {
    <#
      Отправляет ответ телефону (одна строка JSON).
    #>
    param([System.Net.Sockets.TcpClient]$Client, [hashtable]$Response)

    try {
        $json  = $Response | ConvertTo-Json -Compress -Depth 8
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json + "`n")
        $stream = $Client.GetStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        Write-AgentLog "Не удалось отправить ответ: $($_.Exception.Message)" 'WARN'
    }
}

function Start-AgentServer {
    <#
      Главный цикл: слушаем порт, обрабатываем команды, следим за блокировками.
    #>
    $port = [int]$script:Config['listen_port']
    $bind = [string]$script:Config['bind_address']

    $ipAddress = [System.Net.IPAddress]::Any
    if ($bind -and $bind -ne '0.0.0.0') {
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($bind, [ref]$parsed)) { $ipAddress = $parsed }
    }

    $listener = New-Object System.Net.Sockets.TcpListener($ipAddress, $port)
    try {
        $listener.Start()
    } catch {
        Write-AgentLog "НЕ УДАЛОСЬ ОТКРЫТЬ ПОРТ $port : $($_.Exception.Message)" 'ERROR'
        Write-AgentLog 'Возможно, порт занят другой программой или запущена вторая копия агента.' 'ERROR'
        throw
    }

    Write-AgentLog "=== Агент ArsenBlocker v$($script:AgentVersion) запущен. Порт: $port ==="
    Write-AgentLog "Компьютер: $env:COMPUTERNAME | Режим защиты: $($script:Config['security']['mode'])"

    # Показываем локальные IP-адреса — их нужно ввести в телефоне
    try {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' } |
            ForEach-Object { Write-AgentLog "Мой IP-адрес: $($_.IPAddress) (интерфейс: $($_.InterfaceAlias))" }
    } catch { }

    $interval   = [int]$script:Config['check_interval_seconds']
    $nextCheck  = (Get-Date).AddSeconds($interval)

    try {
        while ($true) {
            # --- 1. Есть входящее подключение? ---
            try {
                if ($listener.Pending()) {
                    $client = $listener.AcceptTcpClient()
                    $remoteIp      = ($client.Client.RemoteEndPoint.Address).ToString()
                    $remoteMac     = Get-MacAddress -IpAddress $remoteIp

                    try {
                        $line = Receive-ClientLine -Client $client -TimeoutMs 10000
                        if ([string]::IsNullOrWhiteSpace($line)) {
                            Write-AgentLog "Пустой запрос от $remoteIp — проигнорирован." 'WARN'
                            Send-AgentResponse -Client $client -Response @{ ok = $false; message = 'пустой запрос' }
                        } else {
                            $request = $null
                            try { $request = ConvertTo-HashtableDeep ($line | ConvertFrom-Json) } catch { }

                            if ($null -eq $request -or -not $request.ContainsKey('cmd')) {
                                Write-AgentLog "Некорректный JSON от $remoteIp : $line" 'WARN'
                                Send-AgentResponse -Client $client -Response @{ ok = $false; message = 'некорректный формат запроса (нужен JSON с полем cmd)' }
                            } else {
                                $auth = Test-RequestAuth -Request $request -RemoteIp $remoteIp
                                if (-not $auth['ok']) {
                                    Write-AgentLog "ОТКАЗ в доступе для $remoteIp (MAC $remoteMac): $($auth['reason'])" 'WARN'
                                    Send-AgentResponse -Client $client -Response @{ ok = $false; message = "отказ в доступе: $($auth['reason'])" }
                                } else {
                                    # Пришла опасная команда block — принудительно запросим поле force у админов
                                    if (([string]$request['cmd']).ToLowerInvariant() -eq 'block') {
                                        $tgt = [string]$request['user']
                                        if ($script:Config['protect_admins'] -and (Test-IsAdminAccount $tgt)) {
                                            $force = $false
                                            if ($request.ContainsKey('force')) { $force = [bool]$request['force'] }
                                            if (-not $force) {
                                                $mins = 0; [void][int]::TryParse([string]$request['minutes'], [ref]$mins)
                                                Write-AgentLog "Блокировка администратора '$tgt' без подтверждения — отказано." 'WARN'
                                                Send-AgentResponse -Client $client -Response @{
                                                    ok = $false; message = "Пользователь '$tgt' — администратор. Нужно подтверждение (force=true)."
                                                    need_force = $true
                                                }
                                                $client.Close()
                                                continue
                                            }
                                        }
                                    }

                                    $response = Invoke-AgentCommand -Request $request
                                    Write-AgentLog ("Команда от $remoteIp : {0} {1} {2} -> {3}" -f `
                                        ([string]$request['cmd']), ([string]$request['user']), ([string]$request['minutes']), ([string]$response['message']))
                                    Send-AgentResponse -Client $client -Response $response
                                }
                            }
                        }
                    } finally {
                        $client.Close()
                    }
                }
            } catch {
                Write-AgentLog "Ошибка при обработке подключения: $($_.Exception.Message)" 'ERROR'
            }

            # --- 2. Пора проверить блокировки? ---
            if ((Get-Date) -ge $nextCheck) {
                try { Invoke-BlockEnforcement } catch { Write-AgentLog "Ошибка сторожевого цикла: $($_.Exception.Message)" 'ERROR' }
                $nextCheck = (Get-Date).AddSeconds($interval)
            }

            # --- 3. Короткая пауза, чтобы не грузить процессор ---
            Start-Sleep -Milliseconds 250
        }
    } finally {
        try { $listener.Stop() } catch { }
        Write-AgentLog '=== Агент остановлен ===' 'WARN'
    }
}

# ==============================================================================
#  9. ТОЧКА ВХОДА
# ==============================================================================

Write-Host ''
Write-Host '=== ArsenBlocker: агент для Windows ===' -ForegroundColor Cyan
Write-Host ''

Initialize-AgentConfig

Write-AgentLog "Токен доступа: $($script:Config['security']['token'])"
if (@($script:Config['security']['allowed_macs']).Count -eq 0) {
    Write-AgentLog 'Фильтр MAC-адресов выключен (командовать может любой телефон, знающий токен).' 'WARN'
}

try {
    Start-AgentServer
} catch {
    Write-AgentLog "КРИТИЧЕСКАЯ ОШИБКА: $($_.Exception.Message)" 'ERROR'
    Write-AgentLog $_.ScriptStackTrace 'ERROR'
    exit 1
}