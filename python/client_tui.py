#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 client_tui.py   —   «Пульт управления» (Android / Termux или любой ПК с Python)
 Система: ArsenBlocker   |   Версия: 1.0.0   |   Протокол: v1
--------------------------------------------------------------------------------
 ЧТО ЭТО ЗА ПРОГРАММА (простыми словами):

   Это текстовый пульт: он отправляет на ваш Windows-ПК команды «заблокируй
   пользователя на N минут». Ничего устанавливать дополнительно не нужно —
   используются только стандартные средства Python 3 (модули socket, hmac, json).

 КАК ЗАПУСТИТЬ В TERMUX (пошагово, см. подробную инструкцию в ARCHITECTURE.md):
   1) Установите Termux из F-Droid (не из Google Play — там версия устарела).
   2) В Termux выполните:
         pkg update && pkg install python -y
   3) Скопируйте этот файл, например, в папку ~/arsen и запустите:
         cd ~/arsen && python client_tui.py
   4) При первом запуске программа спросит IP-адрес ПК, порт и токен —
      они показаны в конце работы install_agent.ps1 на компьютере.
      Настройки сохранятся в файл и больше спрашиваться не будут.

 ГОТОВЫЕ КОМАНДЫ БЕЗ МЕНЮ (удобно для скриптов и ярлыков):
      python client_tui.py ping
      python client_tui.py users
      python client_tui.py block Arsen 30          (Arsen — логин, 30 — минуты)
      python client_tui.py unblock Arsen
      python client_tui.py unblock                 (снять ВСЕ блокировки)
      python client_tui.py status
      python client_tui.py info
      python client_tui.py --set-host 192.168.1.50 (быстро поменять адрес ПК)

 ВАЖНО ПРО ФАЙЛ НАСТРОЕК (чтобы не потерять при переустановке):
   Программа ищет файл client.json по очереди:
      1) /sdcard/ArsenBlocker/client.json   <-- ЛУЧШЕЕ место: переживает
                                              переустановку Termux
      2) ~/.arsen_blocker/client.json
      3) client.json рядом со скриптом
   Первый найденный берётся в работу, туда же сохраняются изменения.
================================================================================
"""

import hashlib
import hmac
import json
import os
import secrets
import socket
import sys
import time

PROTOCOL = "v1"
VERSION = "1.0.0"

# ------------------------------------------------------------------------------
#  ГДЕ ИСКАТЬ ФАЙЛ НАСТРОЕК
# ------------------------------------------------------------------------------
CONFIG_CANDIDATES = [
    "/sdcard/ArsenBlocker/client.json",                          # общая память Android
    os.path.join(os.path.expanduser("~"), ".arsen_blocker", "client.json"),
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "client.json"),
]

DEFAULT_CONFIG = {
    "host": "",            # IP-адрес компьютера, например "192.168.1.50"
    "port": 9099,          # порт агента
    "token": "",           # токен доступа (показан при установке агента на ПК)
    "security": "hmac",    # "hmac" (по умолчанию) или "token"
    "timeout": 8,          # сколько секунд ждать ответа ПК
}


# ==============================================================================
#  РАБОТА С НАСТРОЙКАМИ
# ==============================================================================

def find_config_path():
    """Возвращает путь к используемому файлу настроек (первый найденный)."""
    for path in CONFIG_CANDIDATES:
        if os.path.isfile(path):
            return path
    # Ничего не найдено — будем создавать в лучшем доступном месте
    for path in CONFIG_CANDIDATES:
        folder = os.path.dirname(path)
        try:
            os.makedirs(folder, exist_ok=True)
            if os.access(folder, os.W_OK):
                return path
        except (OSError, PermissionError):
            continue
    return CONFIG_CANDIDATES[1]


CONFIG_PATH = find_config_path()


def load_config():
    """Читает настройки с диска. Если файла нет — возвращает значения по умолчанию."""
    cfg = dict(DEFAULT_CONFIG)
    if os.path.isfile(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception as exc:
            print(f"[!] Не удалось прочитать настройки ({exc}). Использую значения по умолчанию.")
    return cfg


def save_config(cfg):
    """Сохраняет настройки, чтобы не вводить их каждый раз."""
    try:
        os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        try:
            os.chmod(CONFIG_PATH, 0o600)   # только владелец может читать (там токен)
        except OSError:
            pass
        print(f"[i] Настройки сохранены: {CONFIG_PATH}")
    except Exception as exc:
        print(f"[!] Не удалось сохранить настройки: {exc}")


def setup_wizard(cfg):
    """Первый запуск: спрашиваем адрес ПК, порт и токен."""
    print()
    print("=== Первичная настройка пульта ArsenBlocker ===")
    print("Эти данные показаны в конце установки агента на компьютере")
    print("(файл install_agent.ps1 выводит ТОКЕН, ПОРТ и IP-АДРЕС ПК).")
    print()

    host = input(f"IP-адрес компьютера [{cfg['host'] or 'например 192.168.1.50'}]: ").strip()
    if host:
        cfg["host"] = host

    port = input(f"Порт [{cfg['port']}]: ").strip()
    if port.isdigit():
        cfg["port"] = int(port)

    token = input("Токен доступа (можно вставить правой кнопкой в Termux): ").strip()
    if token:
        cfg["token"] = token

    mode = input("Режим защиты ('hmac' или 'token') [hmac]: ").strip().lower()
    if mode in ("hmac", "token"):
        cfg["security"] = mode

    save_config(cfg)
    return cfg


# ==============================================================================
#  ПРОТОКОЛ ОБМЕНА (должен совпадать с block_agent.ps1!)
# ==============================================================================

def build_request(cfg, cmd, user="", minutes=0, force=False):
    """
    Собирает запрос к агенту.

    Формат строки подписи (одинаков на ПК, на телефоне и в приложении Kotlin):
        v1|команда|пользователь|минуты|метка_времени|одноразовый_код
    Подпись = HMAC-SHA256(токен, эта строка), в виде шестнадцатеричной строки.
    Метка времени защищает от повторного использования перехваченного запроса.
    """
    ts = int(time.time())
    nonce = secrets.token_hex(8)              # 16 случайных символов

    request = {
        "cmd": cmd,
        "user": user,
        "minutes": int(minutes),
        "ts": ts,
        "nonce": nonce,
    }
    if force:
        request["force"] = True

    if cfg.get("security", "hmac") == "hmac":
        canonical = f"{PROTOCOL}|{cmd.lower()}|{user}|{int(minutes)}|{ts}|{nonce}"
        signature = hmac.new(
            cfg["token"].encode("utf-8"),
            canonical.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        request["sig"] = signature
    else:
        request["token"] = cfg["token"]

    return request


def send_command(cfg, request, quiet=False):
    """
    Отправляет запрос агенту и возвращает ответ (словарь).
    При ошибке возвращает {'ok': False, 'message': '...'}.
    """
    if not cfg.get("host"):
        return {"ok": False, "message": "не задан IP-адрес компьютера (запустите: python client_tui.py --setup)"}
    if not cfg.get("token"):
        return {"ok": False, "message": "не задан токен доступа (запустите: python client_tui.py --setup)"}

    payload = json.dumps(request, ensure_ascii=False).encode("utf-8") + b"\n"

    try:
        with socket.create_connection((cfg["host"], int(cfg["port"])), timeout=int(cfg.get("timeout", 8))) as sock:
            sock.sendall(payload)
            sock.settimeout(int(cfg.get("timeout", 8)))

            chunks = []
            while True:
                try:
                    part = sock.recv(4096)
                except socket.timeout:
                    break
                if not part:
                    break
                chunks.append(part)
                if b"\n" in part:
                    break

        raw = b"".join(chunks).decode("utf-8", errors="replace").strip()
        if not raw:
            return {"ok": False, "message": "компьютер не ответил (проверьте, включён ли агент и правильный ли IP)"}
        return json.loads(raw)

    except socket.timeout:
        return {"ok": False, "message": "превышено время ожидания — компьютер не отвечает"}
    except ConnectionRefusedError:
        return {"ok": False, "message": "компьютер отклонил подключение (агент не запущен или порт закрыт)"}
    except OSError as exc:
        return {"ok": False, "message": f"ошибка сети: {exc}"}
    except ValueError:
        return {"ok": False, "message": "ответ компьютера не удалось разобрать (несовпадение версий?)"}


# ==============================================================================
#  КРАСИВЫЙ ВЫВОД
# ==============================================================================

def print_response(response, request=None):
    """Печатает ответ агента человеческим языком."""
    if response.get("ok"):
        print(f"\n[OK] {response.get('message', 'готово')}")
    else:
        print(f"\n[ОШИБКА] {response.get('message', 'неизвестная ошибка')}")

    data = response.get("data") or {}

    if "users" in data:
        users = data["users"]
        print("\nПользователи этого компьютера:")
        print("-" * 72)
        print(f"{'№':<4}{'Логин':<22}{'Состояние':<16}{'Блокировка':<20}")
        print("-" * 72)
        for index, user in enumerate(users, start=1):
            state = "В СИСТЕМЕ" if user.get("active") else ("профиль есть" if user.get("loaded") else "не активен")
            if user.get("remaining_min"):
                block = f"ещё {user['remaining_min']} мин."
            else:
                block = "-"
            print(f"{index:<4}{user.get('user', '?'):<22}{state:<16}{block:<20}")
        print("-" * 72)

    if "blocked" in data:
        blocked = data["blocked"]
        if blocked:
            print("\nАктивные блокировки:")
            for item in blocked:
                print(f"  - {item['user']}: до {item['until_local']} (осталось {item['remaining_min']} мин.)")
        else:
            print("\nАктивных блокировок нет.")

    if "agent" in data:
        print("\nИнформация об агенте:")
        for key, value in data.items():
            print(f"  {key}: {value}")


current_users = []   # сюда складываем последний полученный список пользователей


# ==============================================================================
#  ДЕЙСТВИЯ МЕНЮ
# ==============================================================================

def action_ping(cfg):
    print_response(send_command(cfg, build_request(cfg, "ping")))


def action_users(cfg):
    response = send_command(cfg, build_request(cfg, "users"))
    current_users.clear()
    print_response(response)
    return response


def action_status(cfg):
    print_response(send_command(cfg, build_request(cfg, "status")))


def action_info(cfg):
    print_response(send_command(cfg, build_request(cfg, "info")))


def parse_minutes(text):
    """
    Понимает: '45' -> 45 минут, '2ч' или '2h' -> 120 минут, '1д'/'1d' -> 1440 минут.
    """
    text = text.strip().lower().replace(" ", "")
    if not text:
        return None
    if text.endswith(("ч", "h")):
        number = text[:-1].replace(",", ".")
        return int(float(number) * 60) if number else None
    if text.endswith(("д", "d")):
        number = text[:-1].replace(",", ".")
        return int(float(number) * 1440) if number else None
    if text.isdigit():
        return int(text)
    return None


def do_block(cfg, user, minutes, force=False):
    """Отправляет команду блокировки и разбирается с защитой админских учёток."""
    response = send_command(cfg, build_request(cfg, "block", user=user, minutes=minutes, force=force))

    if not response.get("ok") and response.get("need_force"):
        print(f"\n[!] {response.get('message')}")
        answer = input("Всё равно заблокировать этого администратора? (да/нет): ").strip().lower()
        if answer in ("да", "д", "y", "yes"):
            response = send_command(cfg, build_request(cfg, "block", user=user, minutes=minutes, force=True))
        else:
            print("Отменено.")
            return response

    print_response(response)
    return response


def action_block(cfg):
    """Меню блокировки: выбрать пользователя из списка и указать время."""
    response = action_users(cfg)
    users = (response.get("data") or {}).get("users") or []
    if not users:
        print("[!] Список пользователей пуст или недоступен.")
        return

    choice = input("\nНомер пользователя для блокировки (пусто — отмена): ").strip()
    if choice.isdigit() and 1 <= int(choice) <= len(users):
        user = users[int(choice) - 1]
    elif choice:
        user = {"user": choice}   # можно ввести логин вручную
    else:
        print("Отменено.")
        return

    login = user.get("user")
    print(f"\nВыбран пользователь: {login}")
    print("Время блокировки. Можно писать: 30 (минут), 2ч (часа), 0.5ч, 1д (день)")
    duration = parse_minutes(input("На сколько заблокировать [30]: ") or "30")
    if not duration or duration <= 0:
        print("[!] Не понял время блокировки. Отменено.")
        return

    print(f"\nПодтвердите: заблокировать «{login}» на {duration} мин.?")
    if input("Введите 'да' для подтверждения: ").strip().lower() not in ("да", "д", "y", "yes"):
        print("Отменено.")
        return

    do_block(cfg, login, duration)


def action_unblock(cfg):
    """Снятие блокировки: показывает список заблокированных и предлагает выбрать."""
    status = send_command(cfg, build_request(cfg, "status"))
    blocked = (status.get("data") or {}).get("blocked") or []
    if blocked:
        print("\nСейчас заблокированы:")
        for index, item in enumerate(blocked, start=1):
            print(f"  {index}) {item['user']} — осталось {item['remaining_min']} мин.")
        choice = input("\nНомер для разблокировки, 'a' — снять ВСЕ, пусто — отмена: ").strip().lower()
    else:
        print("\nАктивных блокировок нет.")
        choice = input("Введите логин для разблокировки (пусто — отмена): ").strip()

    if not choice:
        print("Отменено.")
        return
    if choice in ("a", "все", "all"):
        print_response(send_command(cfg, build_request(cfg, "unblock", user="*")))
        return
    if choice.isdigit() and blocked and 1 <= int(choice) <= len(blocked):
        user = blocked[int(choice) - 1]["user"]
    else:
        user = choice
    print_response(send_command(cfg, build_request(cfg, "unblock", user=user)))


def action_settings(cfg):
    print(f"\nТекущие настройки (файл: {CONFIG_PATH})")
    print(f"  IP компьютера : {cfg['host']}")
    print(f"  Порт          : {cfg['port']}")
    print(f"  Режим защиты  : {cfg['security']}")
    print(f"  Таймаут, сек  : {cfg['timeout']}")
    hidden = cfg["token"]
    print(f"  Токен         : {hidden[:4]}...{hidden[-4:]}" if len(hidden) > 8 else f"  Токен         : {hidden}")

    if input("\nИзменить настройки? (да/нет): ").strip().lower() in ("да", "д", "y", "yes"):
        return setup_wizard(cfg)
    return cfg


# ==============================================================================
#  ГЛАВНОЕ МЕНЮ
# ==============================================================================

MENU = """
================================================================
  ArsenBlocker — пульт управления (телефон)
  ПК: {host}:{port}   режим: {security}
================================================================
  1) Показать пользователей Windows
  2) Заблокировать пользователя
  3) Снять блокировку
  4) Показать статус блокировок
  5) Проверить связь (пинг)
  6) Информация об агенте
  7) Настройки (IP, порт, токен)
  0) Выход
================================================================"""


def main_menu(cfg):
    while True:
        print(MENU.format(host=cfg["host"] or "не задан", port=cfg["port"], security=cfg["security"]))
        choice = input("Ваш выбор: ").strip()

        if choice == "1":
            action_users(cfg)
        elif choice == "2":
            action_block(cfg)
        elif choice == "3":
            action_unblock(cfg)
        elif choice == "4":
            action_status(cfg)
        elif choice == "5":
            action_ping(cfg)
        elif choice == "6":
            action_info(cfg)
        elif choice == "7":
            cfg = action_settings(cfg)
        elif choice in ("0", "q", "exit", "выход"):
            print("До свидания!")
            return
        else:
            print("[!] Нет такого пункта. Введите цифру от 0 до 7.")


# ==============================================================================
#  ЗАПУСК
# ==============================================================================

def main():
    cfg = load_config()
    args = sys.argv[1:]

    # --- Быстрые команды из командной строки ---
    if args:
        first = args[0].lower()

        if first in ("--setup", "setup", "-s"):
            setup_wizard(cfg)
            return

        if first == "--set-host" and len(args) > 1:
            cfg["host"] = args[1]
            save_config(cfg)
            return

        if first == "ping":
            action_ping(cfg)
            return

        if first == "users":
            action_users(cfg)
            return

        if first == "status":
            action_status(cfg)
            return

        if first == "info":
            action_info(cfg)
            return

        if first == "block":
            if len(args) < 2:
                print("Использование: python client_tui.py block <логин> <минуты>")
                return
            minutes = parse_minutes(args[2]) if len(args) > 2 else 30
            if not minutes:
                print("[!] Не понял время блокировки.")
                return
            do_block(cfg, args[1], minutes)
            return

        if first == "unblock":
            user = args[1] if len(args) > 1 else "*"
            print_response(send_command(cfg, build_request(cfg, "unblock", user=user)))
            return

        print(f"Неизвестная команда: {' '.join(args)}")
        print("Доступно: ping | users | status | info | block <логин> <минуты> | unblock [логин] | --setup | --set-host <IP>")
        return

    # --- Первый запуск без настроек: спрашиваем данные ---
    if not cfg["host"] or not cfg["token"]:
        cfg = setup_wizard(cfg)

    main_menu(cfg)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nПрервано пользователем.")
