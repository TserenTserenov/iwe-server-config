#!/bin/bash
set -e

echo "Установка синхронизации Apple Health..."

# 1. Сделай скрипт исполняемым
chmod +x ~/IWE/scripts/sync-health-data.py
echo "✓ Скрипт получил права на выполнение"

# 2. Создай директории для логов и базы
mkdir -p ~/Library/IWE/health-data/archive
mkdir -p ~/.local/var/log
echo "✓ Директории созданы"

# 3. Установи скрипт в launchd
launchctl unload ~/Library/LaunchAgents/com.iwe.sync-health-data.plist 2>/dev/null || true
cp ~/Library/LaunchAgents/com.iwe.sync-health-data.plist ~/Library/LaunchAgents/com.iwe.sync-health-data.plist
launchctl load ~/Library/LaunchAgents/com.iwe.sync-health-data.plist
echo "✓ Задача добавлена в launchd (запускается ежедневно в 07:30)"

# 4. Проверка связи с iCloud Drive
if [ ! -d ~/Library/Mobile\ Documents/com~apple~CloudDocs/Health\ Export ]; then
    echo "⚠ Папка iCloud Drive/Health Export не найдена"
    echo "  Создай её вручную на Mac Finder → iCloud Drive"
    echo "  Или использованное приложение Health Auto Export создаст её автоматически"
else
    echo "✓ Папка iCloud Drive/Health Export найдена"
fi

# 5. Первый запуск (вручную)
echo ""
echo "Запуск первой синхронизации..."
~/IWE/scripts/sync-health-data.py
echo ""

# 6. Проверка БД
if [ -f ~/Library/IWE/health-data/health.db ]; then
    count=$(sqlite3 ~/Library/IWE/health-data/health.db "SELECT COUNT(*) FROM health_records;" 2>/dev/null || echo "0")
    echo "✓ База создана: $count записей о здоровье"
else
    echo "⚠ База не создана — проверь, есть ли файлы в iCloud Drive/Health Export"
fi

echo ""
echo "Установка завершена!"
echo ""
echo "Дальше:"
echo "1. На iPhone установи 'Health Auto Export' из App Store"
echo "2. Настрой экспорт в iCloud Drive (сон + другие данные)"
echo "3. Включи расписание (ежедневно в 06:00)"
echo "4. Mac будет подхватывать файлы автоматически в 07:30"
echo ""
echo "Просмотр логов:"
echo "  tail -f ~/.local/var/log/sync-health.log"
echo ""
echo "Запрос к базе:"
echo "  sqlite3 ~/Library/IWE/health-data/health.db \"SELECT * FROM health_records LIMIT 10;\""
