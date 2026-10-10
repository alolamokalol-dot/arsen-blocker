#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_request.py — вспомогательный файл для тестов.

Формирует подписанный запрос (точно так же, как это делает пульт на телефоне)
и печатает его одной строкой. Используется в test_protocol.ps1, чтобы проверить,
что PowerShell-агент принимает подпись, созданную Python-версией.

Пример:
    python3 tests/make_request.py my-secret-token block Arsen 30
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))

from client_tui import build_request   # noqa: E402


def main():
    if len(sys.argv) < 3:
        print("Использование: python3 make_request.py <токен> <команда> [пользователь] [минуты] [секунд_сдвига]")
        return 1

    token = sys.argv[1]
    cmd = sys.argv[2]
    user = sys.argv[3] if len(sys.argv) > 3 else ""
    minutes = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    shift = int(sys.argv[5]) if len(sys.argv) > 5 else 0

    cfg = {"token": token, "security": "hmac", "host": "127.0.0.1", "port": 9099}
    request = build_request(cfg, cmd, user=user, minutes=minutes)
    if shift:
        request["ts"] = int(time.time()) + shift   # сдвигаем время для проверки защиты

    print(json.dumps(request, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())