#!/data/data/com.termux/files/usr/bin/bash
# Устанавливает короткую команду `arsen` и кладёт Python-клиент в постоянную папку.
# Запускается один раз из каталога, где лежит этот файл и client_tui.py.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
APP_DIR="$HOME/.local/share/arsenblocker"
BIN_DIR="$PREFIX/bin"

if ! command -v python >/dev/null 2>&1; then
  echo "Сначала установите Python: pkg install python -y"
  exit 1
fi

CLIENT="$HERE/client_tui.py"
if [ ! -f "$CLIENT" ] && [ -f "$HERE/../python/client_tui.py" ]; then
  CLIENT="$HERE/../python/client_tui.py"
fi
if [ ! -f "$CLIENT" ]; then
  echo "Не найден client_tui.py. Скопируйте его в папку рядом с setup.sh."
  exit 1
fi

mkdir -p "$APP_DIR" "$BIN_DIR"
cp "$CLIENT" "$APP_DIR/client_tui.py"

cat > "$BIN_DIR/arsen" <<'LAUNCHER'
#!/data/data/com.termux/files/usr/bin/bash
APP_DIR="$HOME/.local/share/arsenblocker"
exec python "$APP_DIR/client_tui.py" "$@"
LAUNCHER
chmod 700 "$BIN_DIR/arsen"
chmod 600 "$APP_DIR/client_tui.py"

# Это разрешение можно дать сейчас: потом клиент сохранит настройки в общей памяти,
# что помогает восстановить их после переустановки Termux.
if command -v termux-setup-storage >/dev/null 2>&1; then
  echo ""
  echo "Сейчас Android может спросить доступ Termux к общей памяти. Разрешите его."
  termux-setup-storage || true
fi

mkdir -p "$HOME/storage/shared/ArsenBlocker" 2>/dev/null || true

echo ""
echo "Готово. Теперь просто введите: arsen"
echo "Первая команда arsen попросит IP компьютера, порт 9099 и токен."
echo "Для быстрых команд: arsen ping | arsen users | arsen block LOGIN 30 | arsen unblock LOGIN"
echo "Пульт установлен в $APP_DIR; настройки сохраняются отдельно в client.json."
