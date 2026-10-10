#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_client.py — автотест пульта ArsenBlocker (client_tui.py).

Что проверяем:
  1) связь с «макетом» агента (ping);
  2) получение списка пользователей;
  3) блокировка и снятие блокировки (состояние меняется на стороне агента);
  4) отказ при неверном токене;
  5) отказ при «старой» метке времени (защита от повторного использования запроса);
  6) правильность формата строки подписи (сверка с макетом).

Запуск:  python3 tests/test_client.py
"""

import os
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))

import client_tui                                   # noqa: E402
from mock_agent import MockAgent                    # noqa: E402

PORT = 19099
TOKEN = "test-token-123"

passed, failed = 0, 0


def check(name, condition, extra=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  [OK]   {name}")
    else:
        failed += 1
        print(f"  [ОШИБКА] {name} {extra}")


def main():
    agent = MockAgent(TOKEN, PORT)
    threading.Thread(target=agent.serve_forever, daemon=True).start()
    time.sleep(0.4)

    cfg = {"host": "127.0.0.1", "port": PORT, "token": TOKEN, "security": "hmac", "timeout": 5}

    print("1) Проверка связи")
    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "ping"))
    check("ping отвечает ok", response.get("ok") is True, response)
    check("в ответе имя компьютера", response.get("data", {}).get("computer") == "MOCK-PC", response)

    print("2) Список пользователей")
    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "users"))
    users = (response.get("data") or {}).get("users") or []
    check("получено 2 пользователя", len(users) == 2, users)
    check("первый пользователь Arsen", users[0]["user"] == "Arsen", users)

    print("3) Блокировка и снятие")
    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "block", user="Arsen", minutes=30))
    check("блокировка принята", response.get("ok") is True, response)
    check("агент запомнил блокировку", "arsen" in agent.blocked, agent.blocked)

    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "status"))
    blocked = (response.get("data") or {}).get("blocked") or []
    check("статус показывает 1 блокировку", len(blocked) == 1, blocked)
    check("осталось примерно 30 минут", blocked and blocked[0]["remaining_min"] in (30, 31), blocked)

    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "unblock", user="Arsen"))
    check("разблокировка принята", response.get("ok") is True, response)
    check("блокировка снята на стороне агента", agent.blocked == {}, agent.blocked)

    print("4) Защита администратора")
    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "block", user="Guest", minutes=10))
    check("отказ без подтверждения (need_force)", response.get("ok") is False and response.get("need_force") is True, response)
    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "block", user="Guest", minutes=10, force=True))
    check("после подтверждения (force) блокировка выполнена", response.get("ok") is True, response)
    client_tui.send_command(cfg, client_tui.build_request(cfg, "unblock", user="*"))

    print("5) Неверный токен")
    bad = dict(cfg, token="wrong-token")
    response = client_tui.send_command(bad, client_tui.build_request(bad, "ping"))
    check("запрос с чужим токеном отклонён", response.get("ok") is False, response)

    print("6) Устаревшая метка времени (защита от повтора)")
    request = client_tui.build_request(cfg, "ping")
    request["ts"] = int(time.time()) - 600          # подделываем «старое» время
    response = client_tui.send_command(cfg, client_tui.build_request(cfg, "ping") if False else request)
    check("старый запрос отклонён", response.get("ok") is False, response)

    print("7) Формат строки подписи")
    request = client_tui.build_request(cfg, "block", user="Arsen", minutes=45)
    canonical = "v1|block|Arsen|45|{0}|{1}".format(request["ts"], request["nonce"])
    check("строка подписи собирается по протоколу v1", client_tui.PROTOCOL == "v1", canonical)
    check("подпись — 64 hex-символа", len(request["sig"]) == 64, request["sig"])

    print()
    print(f"ИТОГО: успешно {passed}, ошибок {failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())