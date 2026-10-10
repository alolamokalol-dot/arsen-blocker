#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mock_agent.py — «тренажёр» агента для проверки пульта без Windows.

Это упрощённая копия логики block_agent.ps1 на Python: тот же формат запросов,
та же проверка подписи HMAC-SHA256. Нужен, чтобы проверить пульт (client_tui.py,
client_gui.py, Kotlin-приложение), когда под рукой нет Windows-ПК.

Запуск вручную (например, чтобы «поиграть» с пультом):
    python3 mock_agent.py --port 19099 --token test-token-123
"""

import argparse
import hashlib
import hmac
import json
import socket
import threading
import time

PROTOCOL = "v1"

USERS = [
    {"user": "Arsen", "display": "HOME-PC\\Arsen", "active": True, "loaded": True, "session_id": 1,
     "blocked_until": None, "remaining_min": 0},
    {"user": "Guest", "display": "HOME-PC\\Guest", "active": False, "loaded": False, "session_id": None,
     "blocked_until": None, "remaining_min": 0},
]

PROTECTED = ["administrator", "администратор", "system", "guest", "гость"]


class MockAgent:
    def __init__(self, token, port=19099, mode="hmac"):
        self.token = token
        self.port = port
        self.mode = mode
        self.blocked = {}          # логин(нижний регистр) -> время окончания
        self.log = []

    # ----------------------------------------------------------------------
    def canonical(self, request):
        return "{0}|{1}|{2}|{3}|{4}|{5}".format(
            PROTOCOL,
            str(request.get("cmd", "")).lower(),
            request.get("user", ""),
            int(request.get("minutes", 0) or 0),
            request.get("ts", ""),
            request.get("nonce", ""),
        )

    def check_auth(self, request):
        if self.mode == "token":
            return (request.get("token") == self.token, "неверный токен")
        ts = int(request.get("ts", 0) or 0)
        if abs(time.time() - ts) > 120:
            return (False, "расхождение часов")
        expected = hmac.new(self.token.encode(), self.canonical(request).encode(), hashlib.sha256).hexdigest()
        if expected != str(request.get("sig", "")).lower():
            return (False, "подпись не совпадает")
        return (True, "")

    # ----------------------------------------------------------------------
    def handle(self, request):
        ok, reason = self.check_auth(request)
        if not ok:
            return {"ok": False, "message": "отказ в доступе: " + reason}

        cmd = str(request.get("cmd", "")).lower()
        now = int(time.time())

        if cmd == "ping":
            return {"ok": True, "message": "агент на связи",
                    "data": {"agent": "1.0.0-mock", "protocol": PROTOCOL, "computer": "MOCK-PC", "time": now}}

        if cmd == "users":
            users = []
            for user in USERS:
                copy = dict(user)
                key = user["user"].lower()
                if key in self.blocked:
                    copy["blocked_until"] = self.blocked[key]
                    copy["remaining_min"] = int((self.blocked[key] - now) / 60) + 1
                users.append(copy)
            return {"ok": True, "message": "список пользователей", "data": {"users": users}}

        if cmd == "status":
            blocked = [
                {"user": key, "until_unix": value, "remaining_min": int((value - now) / 60) + 1,
                 "until_local": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(value))}
                for key, value in self.blocked.items()
            ]
            return {"ok": True, "message": "активных блокировок: %d" % len(blocked), "data": {"blocked": blocked}}

        if cmd == "block":
            user = str(request.get("user", ""))
            minutes = int(request.get("minutes", 0) or 0)
            if not user:
                return {"ok": False, "message": "не указан пользователь"}
            if minutes <= 0:
                return {"ok": False, "message": "не указано время блокировки"}
            if user.lower() in PROTECTED and not request.get("force"):
                return {"ok": False, "need_force": True,
                        "message": "Пользователь '%s' защищён (администратор)." % user}
            self.blocked[user.lower()] = now + minutes * 60
            return {"ok": True, "message": "Пользователь '%s' заблокирован на %d мин." % (user, minutes)}

        if cmd == "unblock":
            user = str(request.get("user", "")) or "*"
            if user == "*":
                count = len(self.blocked)
                self.blocked.clear()
                return {"ok": True, "message": "Сняты все блокировки (%d шт.)." % count}
            if user.lower() in self.blocked:
                del self.blocked[user.lower()]
                return {"ok": True, "message": "Блокировка с пользователя '%s' снята." % user}
            return {"ok": True, "message": "Пользователь '%s' не был заблокирован." % user}

        if cmd == "info":
            return {"ok": True, "message": "информация об агенте",
                    "data": {"agent": "1.0.0-mock", "protocol": PROTOCOL, "mode": self.mode}}

        return {"ok": False, "message": "неизвестная команда: '%s'" % cmd}

    # ----------------------------------------------------------------------
    def serve_forever(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", self.port))
        server.listen(5)
        while True:
            client, _ = server.accept()
            threading.Thread(target=self.serve_client, args=(client,), daemon=True).start()

    def serve_client(self, client):
        try:
            client.settimeout(5)
            data = b""
            while b"\n" not in data:
                part = client.recv(4096)
                if not part:
                    break
                data += part
            line = data.decode("utf-8").strip()
            if not line:
                return
            try:
                request = json.loads(line)
            except ValueError:
                client.sendall('{"ok": false, "message": "некорректный JSON"}\n'.encode("utf-8"))
                return
            response = self.handle(request)
            client.sendall((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))
        finally:
            client.close()


def main():
    parser = argparse.ArgumentParser(description="Макет агента ArsenBlocker для тестов")
    parser.add_argument("--port", type=int, default=19099)
    parser.add_argument("--token", default="test-token-123")
    parser.add_argument("--mode", default="hmac", choices=["hmac", "token"])
    args = parser.parse_args()

    agent = MockAgent(args.token, args.port, args.mode)
    print("Макет агента запущен на порту %d, режим %s" % (args.port, args.mode))
    agent.serve_forever()


if __name__ == "__main__":
    main()
