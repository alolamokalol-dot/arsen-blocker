# ArsenBlocker 1.0.0 — памятка (начните отсюда)

Система удалённой блокировки учётных записей Windows с телефона Android.
Два компонента: **агент** на ПК (`block_agent.ps1`) и **пульт** на телефоне (`client_tui.py`).

Полное описание: **[ARCHITECTURE.md](ARCHITECTURE.md)** — там схема, протокол, безопасность,
пошаговая установка, диагностика и шпаргалка команд.

---

## Самый простой вариант: EXE на ПК и команда `arsen` на телефоне

В проект добавлены сборщик однокнопочного Windows-установщика и установщик короткой команды Termux:

1. На Windows **один раз** собрать `ArsenBlockerSetup.exe` из `windows/build_setup_exe.ps1` (подробности в `windows/README_EXE.md`). После этого для установки достаточно двойного щелчка по EXE и подтверждения стандартного окна UAC.
2. На телефоне установить Python и запустить `bash setup.sh` из папки `termux`. Затем управлять ПК командой `arsen` — см. `termux/README.md`.

В этой среде Windows нет, поэтому готовый Windows-бинарник здесь не собран и не проверен; проект содержит сборщик, который создаст EXE на Windows. Это важно: нельзя честно приложить и назвать рабочим неподтверждённый EXE.

## Быстрый старт скриптами (если удобнее)

**Шаг 1. На ПК (PowerShell от имени администратора):**

```powershell
Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force
cd C:\ArsenBlocker                                # папка, куда скопированы windows\block_agent.ps1 и windows\install_agent.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_agent.ps1
```

Установщик создаст автозапуск, откроет порт в локальной сети и **покажет ТОКЕН и IP-адрес ПК** — запишите их.

**Шаг 2. На телефоне (Termux из F-Droid):**

```bash
pkg update -y && pkg install -y python
termux-setup-storage
mkdir -p ~/arsen && cp /sdcard/Download/client_tui.py ~/arsen/
cd ~/arsen && python client_tui.py
```

Введите IP, порт (9099) и токен. Дальше — меню: список пользователей, выбор времени, кнопка «Заблокировать».

**Шаг 3. Проверка:** пункт 5 «Проверить связь» → должно ответить `[OK] агент на связи`.

---

## Файлы проекта

| Файл | Что это |
|---|---|
| `ARCHITECTURE.md` | Архитектура, протокол, безопасность, инструкции, диагностика |
| `windows/block_agent.ps1` | **Агент для ПК** (сервер, логика блокировки через `logoff`) |
| `windows/install_agent.ps1` | **Установщик**: автозапуск через Планировщик задач, брандмауэр, права, токен |
| `python/client_tui.py` | **Пульт** для Termux (меню + команды в одну строку) |
| `python/client_gui.py` | **Пульт с кнопками** для Pydroid 3 (и для Windows/Linux) |
| `android/MainActivity.kt` | Вариант «своё приложение» (Kotlin, Android Studio) |
| `android/AndroidManifest_snippet.xml`, `android/build_gradle_snippet.txt` | Что добавить в Android-проект |
| `docs/config.example.json`, `docs/client.example.json` | Примеры настроек агента и пульта |
| `tests/mock_agent.py`, `tests/test_client.py` | «Тренажёр» агента и 16 автотестов пульта |
| `tests/make_request.py`, `tests/test_protocol.ps1` | 20 автотестов агента и совместимости подписи с Python |
| `diagrams/architecture.png`, `diagrams/sequence.png` | Схема системы и последовательность блокировки |

---

## Три главных правила

1. **Токен** из `C:\ProgramData\ArsenBlocker\config.json` — это пароль системы. Не показывайте его посторонним.
2. **Не удаляйте** папку `C:\ProgramData\ArsenBlocker`: в ней токен и активные блокировки; она сохраняется при переустановке программы. Держите копию `config.json` в облаке/почте.
3. Порт **9099 наружу в интернет не открывайте**. Для управления извне используйте VPN (WireGuard/Tailscale) — см. раздел 12 в ARCHITECTURE.md.

---

## Что можно проверить прямо сейчас (без Windows)

```bash
python3 tests/test_client.py        # 16 проверок пульта против тренажёра
pwsh ./tests/test_protocol.ps1      # 20 проверок агента и подписи
```

Оба набора проходят полностью (проверено при сборке).
