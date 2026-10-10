#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 client_gui.py  —  Пульт ArsenBlocker с графическим интерфейсом (окна + кнопки)
--------------------------------------------------------------------------------
 ДЛЯ КОГО: если не хочется набирать команды в Termux, а нужны обычные кнопки.

 ГДЕ ЗАПУСКАТЬ:
   • Android: приложение Pydroid 3 (бесплатное, из Play Market).
     Откройте в нём этот файл и нажмите большую кнопку «Play».
     Tkinter в Pydroid 3 уже встроен — ничего доустанавливать не нужно.
   • Windows/Linux: обычный Python 3 (python client_gui.py).

 ЧТО УМЕЕТ: тот же набор команд, что и client_tui.py —
   пинг, список пользователей, блокировка (с выбором времени), снятие блокировки.

 Настройки (IP, порт, токен) берутся из того же файла client.json, что и
 у текстового пульта, поэтому вводить их дважды не нужно.
================================================================================
"""

import os
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Берём всю сетевую логику из текстового пульта — она уже проверена
from client_tui import (  # noqa: E402
    build_request, load_config, save_config, send_command, CONFIG_PATH, setup_wizard,
)

import tkinter as tk                     # noqa: E402
from tkinter import messagebox, scrolledtext, ttk  # noqa: E402


class BlockerApp:
    """Главное окно пульта."""

    def __init__(self, root, cfg):
        self.root = root
        self.cfg = cfg
        self.users = []

        root.title("ArsenBlocker — пульт управления")
        root.geometry("520x640")

        frame = ttk.Frame(root, padding=10)
        frame.pack(fill="both", expand=True)

        # --- Строка состояния подключения ---
        self.lbl_status = ttk.Label(frame, text="", font=("TkDefaultFont", 10, "bold"))
        self.lbl_status.pack(anchor="w")
        self.update_status()

        # --- Кнопки действий ---
        row = ttk.Frame(frame)
        row.pack(fill="x", pady=6)
        ttk.Button(row, text="Проверить связь", command=self.do_ping).pack(side="left", padx=2)
        ttk.Button(row, text="Обновить список", command=self.do_users).pack(side="left", padx=2)
        ttk.Button(row, text="Статус", command=lambda: self.send("status")).pack(side="left", padx=2)
        ttk.Button(row, text="Настройки", command=self.open_settings).pack(side="left", padx=2)

        # --- Список пользователей ---
        ttk.Label(frame, text="Пользователи компьютера:").pack(anchor="w", pady=(8, 0))
        self.listbox = tk.Listbox(frame, height=8)
        self.listbox.pack(fill="both", expand=False, pady=4)

        # --- Время блокировки ---
        ttk.Label(frame, text="Время блокировки (минуты; можно 120, или ввести 1440 = сутки):").pack(anchor="w")
        time_row = ttk.Frame(frame)
        time_row.pack(fill="x", pady=4)

        self.var_minutes = tk.StringVar(value="30")
        ttk.Entry(time_row, textvariable=self.var_minutes, width=8).pack(side="left")
        for value in (15, 30, 60, 120, 1440):
            ttk.Button(time_row, text=str(value), width=6,
                       command=lambda v=value: self.var_minutes.set(str(v))).pack(side="left", padx=2)

        # --- Ползунок (альтернатива полю ввода), диапазон 5..720 минут ---
        self.scale = tk.Scale(frame, from_=5, to=720, orient="horizontal",
                              label="Ползунок: минуты", command=self.on_scale)
        self.scale.set(30)
        self.scale.pack(fill="x")

        # --- Главные кнопки ---
        ttk.Button(frame, text="ЗАБЛОКИРОВАТЬ выбранного пользователя",
                   command=self.do_block).pack(fill="x", pady=(8, 3))
        ttk.Button(frame, text="Снять все блокировки",
                   command=lambda: self.send("unblock", "")).pack(fill="x", pady=3)

        # --- Журнал ---
        ttk.Label(frame, text="Журнал:").pack(anchor="w", pady=(8, 0))
        self.log_box = scrolledtext.ScrolledText(frame, height=10, state="disabled")
        self.log_box.pack(fill="both", expand=True)

        self.log(f"Настройки: {CONFIG_PATH}")
        self.log(f"Компьютер: {self.cfg['host'] or 'не задан'}:{self.cfg['port']}\n")

    # --------------------------------------------------------------------------
    def update_status(self):
        self.lbl_status.config(
            text=f"ПК: {self.cfg['host'] or 'не задан'} : {self.cfg['port']}   "
                 f"режим: {self.cfg['security']}"
        )

    def on_scale(self, value):
        """Ползунок и поле ввода синхронизированы между собой."""
        self.var_minutes.set(str(int(float(value))))

    def log(self, text):
        self.log_box.config(state="normal")
        self.log_box.insert("end", text + "\n")
        self.log_box.see("end")
        self.log_box.config(state="disabled")

    # --------------------------------------------------------------------------
    def send(self, cmd, user="", minutes=0, force=False):
        """Отправляет команду в фоновом потоке (чтобы окно не «зависало»)."""

        def worker():
            request = build_request(self.cfg, cmd, user=user, minutes=minutes, force=force)
            response = send_command(self.cfg, request)
            self.root.after(0, lambda: self.show(response, user, minutes))

        threading.Thread(target=worker, daemon=True).start()

    def show(self, response, user, minutes):
        self.log(f"[{response.get('ok')}] {response.get('message')}")

        data = response.get("data") or {}
        if "users" in data:
            self.users = data["users"]
            self.listbox.delete(0, "end")
            for item in self.users:
                state = "В СИСТЕМЕ" if item.get("active") else "не активен"
                blocked = f" | блок: {item['remaining_min']} мин." if item.get("remaining_min") else ""
                self.listbox.insert("end", f"{item['user']} — {state}{blocked}")
            self.log(f"Получено пользователей: {len(self.users)}")

        if "blocked" in data:
            for item in data["blocked"]:
                self.log(f"  заблокирован: {item['user']} до {item['until_local']}")

        # Если ПК требует подтверждения (администратор) — спрашиваем пользователя
        if not response.get("ok") and response.get("need_force"):
            if messagebox.askyesno("Это администратор",
                                   f"Пользователь «{user}» — администратор.\nЗаблокировать всё равно?"):
                self.send("block", user, minutes, force=True)

    # --------------------------------------------------------------------------
    def do_ping(self):
        self.send("ping")

    def do_users(self):
        self.send("users")

    def do_block(self):
        selection = self.listbox.curselection()
        if not selection:
            messagebox.showinfo("Выбор пользователя",
                                "Сначала нажмите «Обновить список» и выберите пользователя в списке.")
            return

        user = self.users[selection[0]]["user"]
        try:
            minutes = int(float(self.var_minutes.get()))
        except ValueError:
            messagebox.showerror("Ошибка", "Введите время блокировки числом (минуты).")
            return

        if not messagebox.askyesno("Подтверждение",
                                   f"Заблокировать «{user}» на {minutes} мин.?"):
            return
        self.send("block", user, minutes)

    def open_settings(self):
        setup_wizard(self.cfg)
        self.update_status()


def main():
    cfg = load_config()
    if not cfg["host"] or not cfg["token"]:
        print("Сначала заполните настройки (окно «Настройки» или файл", CONFIG_PATH, ")")

    root = tk.Tk()
    app = BlockerApp(root, cfg)
    if not cfg["host"] or not cfg["token"]:
        app.open_settings()
    root.mainloop()


if __name__ == "__main__":
    main()