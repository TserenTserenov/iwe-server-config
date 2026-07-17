#!/usr/bin/env python3
"""
Синхронизация экспортов Health Auto Export в локальную SQLite базу.
Запускается ежедневно из launchd.
"""

import os
import sys
import json
import csv
import sqlite3
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Tuple

# Конфигурация
ICLOUD_HEALTH_DIR = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Health Export"
DB_PATH = Path.home() / "Library/IWE/health-data/health.db"
ARCHIVE_DIR = Path.home() / "Library/IWE/health-data/archive"
LOG_FILE = Path.home() / ".local/var/log/sync-health.log"

# Гарантируем директории
DB_PATH.parent.mkdir(parents=True, exist_ok=True)
ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)


def log(msg: str):
    """Логирование в файл + stdout."""
    timestamp = datetime.now().isoformat()
    line = f"[{timestamp}] {msg}"
    print(line)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def init_db():
    """Инициализация схемы базы."""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute("""
        CREATE TABLE IF NOT EXISTS health_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            start_date TEXT NOT NULL,
            end_date TEXT NOT NULL,
            value REAL,
            unit TEXT,
            source TEXT,
            created_date TEXT,
            parsed_date TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(type, start_date, end_date, value, source)
        )
    """)

    c.execute("""
        CREATE INDEX IF NOT EXISTS idx_type_date
        ON health_records(type, start_date)
    """)

    c.execute("""
        CREATE TABLE IF NOT EXISTS sync_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            filename TEXT NOT NULL,
            sync_date TEXT DEFAULT CURRENT_TIMESTAMP,
            record_count INTEGER,
            status TEXT
        )
    """)

    conn.commit()
    conn.close()


def _parse_health_record(elem) -> Dict:
    """Извлекает запись здоровья из XML/CSV элемента."""
    value = elem.get('value') if isinstance(elem, ET.Element) else elem.get('value', 0)
    # Пытаемся преобразовать в float, если не удаётся — оставляем как строка
    parsed_value = None
    if value and str(value) != '':
        try:
            parsed_value = float(value)
        except (ValueError, TypeError):
            parsed_value = str(value)
    return {
        'type': elem.get('type', ''),
        'start_date': elem.get('startDate', ''),
        'end_date': elem.get('endDate', ''),
        'value': parsed_value,
        'unit': elem.get('unit', ''),
        'source': elem.get('sourceName', 'Health App'),
        'created_date': elem.get('createdDate', ''),
    }


def parse_xml_export(xml_data) -> List[Dict]:
    """Парсит XML из Health (встроенный экспорт или zip)."""
    records = []
    try:
        if isinstance(xml_data, Path):
            tree = ET.parse(xml_data)
            root = tree.getroot()
        else:
            root = ET.fromstring(xml_data)

        # Оба формата: с namespace и без
        ns = {'health': 'http://www.apple.com/healthkit/export'}

        # Пытаемся с namespace
        elements = root.findall('.//health:Record', ns)
        if not elements:
            # Если namespace не работает, ищем без него
            elements = root.findall('.//Record')

        for record_elem in elements:
            try:
                records.append(_parse_health_record(record_elem))
            except (ValueError, KeyError) as e:
                log(f"Пропуск записи: {e}")

    except Exception as e:
        log(f"Ошибка парсинга XML: {e}")
    return records


def insert_records(records: List[Dict]) -> int:
    """Вставляет записи в БД, игнорируя дубликаты."""
    if not records:
        return 0

    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    inserted = 0

    for rec in records:
        try:
            c.execute("""
                INSERT OR IGNORE INTO health_records
                (type, start_date, end_date, value, unit, source, created_date)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (
                rec['type'],
                rec['start_date'],
                rec['end_date'],
                rec['value'],
                rec['unit'],
                rec['source'],
                rec['created_date'],
            ))
            if c.rowcount > 0:
                inserted += 1
        except sqlite3.Error as e:
            log(f"Ошибка вставки: {e}")

    conn.commit()
    conn.close()
    return inserted


def _extract_records_from_zip(zf: zipfile.ZipFile) -> List[Dict]:
    """Извлекает записи из ZIP файла (XML или CSV)."""
    records = []
    for file_info in zf.filelist:
        if file_info.filename.endswith('export.xml'):
            with zf.open(file_info) as f:
                xml_data = f.read()
                records.extend(parse_xml_export(xml_data))
        elif file_info.filename.endswith('.csv'):
            with zf.open(file_info) as f:
                reader = csv.DictReader(f.read().decode('utf-8').splitlines())
                for row in reader:
                    records.append(_parse_health_record(row))
    return records


def process_zip(zip_path: Path) -> Tuple[int, bool]:
    """Распаковывает ZIP и парсит содержимое."""
    try:
        with zipfile.ZipFile(zip_path, 'r') as zf:
            records = _extract_records_from_zip(zf)
        inserted = insert_records(records)
        return inserted, True
    except Exception as e:
        log(f"Ошибка обработки ZIP {zip_path}: {e}")
        return 0, False


def sync():
    """Главная функция синхронизации."""
    if not ICLOUD_HEALTH_DIR.exists():
        log(f"Директория {ICLOUD_HEALTH_DIR} не найдена. Проверь iCloud Drive монтирование.")
        sys.exit(1)

    init_db()
    log("Синхронизация началась")

    total_inserted = 0
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    # Ищем ZIP файлы в корне
    for zip_file in sorted(ICLOUD_HEALTH_DIR.glob("*.zip")):
        log(f"Обработка {zip_file.name}")
        inserted, success = process_zip(zip_file)

        if success:
            total_inserted += inserted
            c.execute(
                "INSERT INTO sync_log (filename, record_count, status) VALUES (?, ?, ?)",
                (zip_file.name, inserted, "success")
            )

            archive_file = ARCHIVE_DIR / f"{zip_file.stem}-{datetime.now().isoformat()}.zip"
            zip_file.rename(archive_file)
            log(f"Архивирован: {archive_file.name}")
        else:
            c.execute(
                "INSERT INTO sync_log (filename, status) VALUES (?, ?)",
                (zip_file.name, "error")
            )

    # Ищем XML файлы в папке apple_health_export (формат Health Auto Export)
    export_dir = ICLOUD_HEALTH_DIR / "apple_health_export"
    if export_dir.exists():
        for xml_file in sorted(export_dir.glob("*.xml")):
            if xml_file.name.endswith("_cda.xml"):
                continue
            log(f"Обработка {xml_file.name}")
            try:
                records = parse_xml_export(xml_file)
                inserted = insert_records(records)
                total_inserted += inserted
                c.execute(
                    "INSERT INTO sync_log (filename, record_count, status) VALUES (?, ?, ?)",
                    (xml_file.name, inserted, "success")
                )
                log(f"Загружено из {xml_file.name}: {inserted} записей")
            except Exception as e:
                log(f"Ошибка обработки {xml_file.name}: {e}")
                c.execute(
                    "INSERT INTO sync_log (filename, status) VALUES (?, ?)",
                    (xml_file.name, "error")
                )

    conn.commit()
    conn.close()

    log(f"Синхронизация завершена. Загружено записей: {total_inserted}")
    return 0 if total_inserted > 0 else 1


if __name__ == "__main__":
    sys.exit(sync())
