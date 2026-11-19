#!/bin/bash
# Double-click on a Mac that is on the home Wi-Fi.
cd "$(dirname "$0")" || exit 1
export LANG="${LANG:-ru_RU.UTF-8}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "Нужен Python 3. Установите его с https://www.python.org/downloads/macos/"
  read -r -p "Enter…"
  exit 1
fi
echo "Чиним Keenetic 192.168.3.1 — Instagram и Cursor через VPN."
echo "Интернет пропадёт на 1–2 минуты: роутер перезагрузится."
echo
python3 vpn_fix.py "$@"
status=$?
echo
read -r -p "Готово. Нажмите Enter, чтобы закрыть окно."
exit "$status"
