<#
================================================================================
 test_protocol.ps1 — проверка «внутренностей» агента (block_agent.ps1).

 Зачем нужно: Windows-специфичные команды (logoff, сессии) проверить на Linux
 нельзя, а вот всю логику безопасности и работы с настройками — можно.
 Скрипт берёт функции из block_agent.ps1 БЕЗ запуска самого агента и проверяет:

   1) разбор настроек и «склейку» со значениями по умолчанию;
   2) сохранение и повторную загрузку списка блокировок (важно при перезагрузке ПК);
   3) проверку подписи HMAC-SHA256 запроса, созданного ПУЛЬТОМ НА PYTHON
      (это доказывает, что телефон и ПК «понимают» друг друга);
   4) отказ при неверном токене и при «старом» времени запроса;
   5) отказ в блокировке защищённого пользователя.

 Запуск (в Windows или в Linux с PowerShell 7):
     pwsh ./tests/test_protocol.ps1
================================================================================
#>

$ErrorActionPreference = 'Stop'

$root       = Split-Path -Parent $PSScriptRoot
$agentPath  = Join-Path $root 'windows/block_agent.ps1'
$pythonFile = Join-Path $root 'tests/make_request.py'
$token      = 'test-token-123'

$script:passed = 0
$script:failed = 0

function Assert-True {
    param([string]$Name, $Condition, [string]$Extra = '')
    if ($Condition) {
        $script:passed++
        Write-Host "  [OK]     $Name"
    } else {
        $script:failed++
        Write-Host "  [ОШИБКА] $Name $Extra" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------------------
# 1. Загружаем ТОЛЬКО функции из block_agent.ps1 (сам агент не запускаем)
# ------------------------------------------------------------------------------
Write-Host "1) Загрузка функций агента"
$source = Get-Content -LiteralPath $agentPath -Raw
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$parseErrors)
Assert-True 'файл агента разбирается без ошибок' ($parseErrors.Count -eq 0) ($parseErrors | ForEach-Object { $_.Message })

$functionText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $_.Extent.Text }) -join "`n`n"
. ([scriptblock]::Create($functionText))
Assert-True 'функция Get-CanonicalString загружена' ($null -ne (Get-Command Get-CanonicalString -ErrorAction SilentlyContinue))
Assert-True 'функция Invoke-AgentCommand загружена' ($null -ne (Get-Command Invoke-AgentCommand -ErrorAction SilentlyContinue))

# В самом агенте эти константы задаются в начале файла — повторяем их здесь
$script:ProtocolVer = 'v1'
$script:AgentVersion = '1.0.0'
$script:StartedAt = Get-Date

# ------------------------------------------------------------------------------
# 2. Настройки: значения по умолчанию, сохранение, повторная загрузка
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '2) Настройки и сохранение блокировок'
$script:ConfigDir  = Join-Path ([System.IO.Path]::GetTempPath()) ('arsen_test_' + (Get-Random))
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'
$script:LogPath    = Join-Path $script:ConfigDir 'agent.log'
$script:Config = Merge-ConfigDeep -Base @{ listen_port = 9999; security = @{ token = $token } } -Defaults (Get-DefaultConfig)
Assert-True 'порт из файла сохранён' ($script:Config['listen_port'] -eq 9999)
Assert-True 'остальные значения по умолчанию добавлены' ($script:Config['check_interval_seconds'] -eq 5)
Assert-True 'вложенные настройки security не потеряны' ($script:Config['security']['mode'] -eq 'hmac')

$script:Blocked = @{}
$until = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800
$script:Blocked['arsen'] = $until
Save-AgentConfig
Assert-True 'файл настроек создан' (Test-Path -LiteralPath $script:ConfigPath)

# Имитируем перезагрузку ПК: заново читаем файл
$reloaded = ConvertTo-HashtableDeep ((Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json)
Assert-True 'блокировка сохранилась в файл' ($reloaded['blocked']['arsen'] -eq $until)
Assert-True 'токен сохранился в файл' ($reloaded['security']['token'] -eq $token)

# ------------------------------------------------------------------------------
# 3. Строка подписи и HMAC — сверка с Python-пультом
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '3) Проверка подписи запроса, созданного пультом на Python'

function Get-PythonRequest {
    param([string[]]$Arguments)
    $python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
    $json = & $python $pythonFile @Arguments
    if ($LASTEXITCODE -ne 0) { throw "python вернул ошибку" }
    return (ConvertTo-HashtableDeep ($json | ConvertFrom-Json))
}

$script:Config['security']['token'] = $token
$script:Config['security']['mode']  = 'hmac'

$request = Get-PythonRequest @($token, 'block', 'Arsen', '30')
$auth = Test-RequestAuth -Request $request -RemoteIp '192.168.1.77'
Assert-True 'подпись Python принята агентом' ($auth['ok']) ($auth['reason'])

$requestWrong = Get-PythonRequest @('другой-токен', 'block', 'Arsen', '30')
$authWrong = Test-RequestAuth -Request $requestWrong -RemoteIp '192.168.1.77'
Assert-True 'чужой токен отклонён' (-not $authWrong['ok'])

$requestOld = Get-PythonRequest @($token, 'ping', '', '0', '-600')
$authOld = Test-RequestAuth -Request $requestOld -RemoteIp '192.168.1.77'
Assert-True 'старый запрос (сдвиг 10 минут) отклонён' (-not $authOld['ok'])

$canonical = Get-CanonicalString -Request $request
$expected = "$($script:ProtocolVer)|block|Arsen|30|$($request['ts'])|$($request['nonce'])"
Assert-True 'строка подписи собирается корректно' ($canonical -eq $expected) $canonical

# ------------------------------------------------------------------------------
# 4. Логика команд (с подменой системных функций — без реальных сессий Windows)
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '4) Логика команд block / unblock / status'

function Get-ActiveSessions { return @() }        # подменяем: реальных сессий нет
$script:Config['protected_users'] = @('Administrator', 'Администратор')

$response = Invoke-AgentCommand -Request @{ cmd = 'block'; user = 'Arsen'; minutes = 30 }
Assert-True 'команда block выполнена' ($response['ok'])
Assert-True 'блокировка записана в память' ($script:Blocked.ContainsKey('arsen'))

$response = Invoke-AgentCommand -Request @{ cmd = 'block'; user = 'Администратор'; minutes = 30 }
Assert-True 'защищённый пользователь заблокирован быть не может' (-not $response['ok']) ($response['message'])

$response = Invoke-AgentCommand -Request @{ cmd = 'status' }
Assert-True 'статус сообщает 1 блокировку' ($response['data']['blocked'].Count -eq 1)

$response = Invoke-AgentCommand -Request @{ cmd = 'unblock'; user = 'Arsen' }
Assert-True 'блокировка снята' ($response['ok'] -and $script:Blocked.Count -eq 0)

$response = Invoke-AgentCommand -Request @{ cmd = 'block'; user = 'Arsen'; minutes = 99999 }
Assert-True 'слишком долгая блокировка обрезана до максимума' ($script:Blocked['arsen'] -le ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1441 * 60))

$response = Invoke-AgentCommand -Request @{ cmd = 'бред' }
Assert-True 'неизвестная команда отклонена' (-not $response['ok'])

# ------------------------------------------------------------------------------
# 5. Итог
# ------------------------------------------------------------------------------
Remove-Item -LiteralPath $script:ConfigDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "ИТОГО: успешно $($script:passed), ошибок $($script:failed)"
if ($script:failed -gt 0) { exit 1 }
