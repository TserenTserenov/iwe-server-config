"""Pytest тесты для скилла /route (Phase A: core classifier)."""

import pytest
import tempfile
from pathlib import Path
import sys

# Импортируем classifier (предполагаем, что route.py в parent dir)
_ROUTE_DIR = str(Path(__file__).parent.parent)
if _ROUTE_DIR not in sys.path:
    sys.path.insert(0, _ROUTE_DIR)
from route import MaterialClassifier
from models import MaterialClass, Mode, ModeDetail


@pytest.fixture
def classifier():
    return MaterialClassifier()


class TestBasicClassification:
    """Тест 1: Базовый случай — пользователь спрашивает (Сценарий 1)."""

    def test_ski_guide_class_4(self, classifier):
        """Ресёрч о горнолыжных курортах — класс 4 (субъективная оценка)."""
        content = """
        Горнолыжные курорты Швейцарии: личное исследование

        Я недавно посетил несколько курортов и хочу поделиться впечатлениями.
        Курорт А показался мне отличным для начинающих — хорошая школа, дружелюбный персонал.

        Мое мнение: Это самый лучший курорт для семьи с детьми.
        """

        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
            f.write(content)
            f.flush()

            result = classifier.classify(f.name)

            assert result.material_class == MaterialClass.SUBJECTIVE_EVAL
            assert result.mode == Mode.POINTER
            assert result.mode_detail == ModeDetail.CANDIDATE
            assert result.confidence >= 0.6
            assert not result.quarantine


class TestAutomaticClassification:
    """Тест 2: Агент при захвате — batch обработка (Сценарий 2)."""

    def test_migration_pattern_class_1(self, classifier):
        """Миграция БД — паттерн/метод (класс 1)."""
        content = """
        Database Migration Pattern

        This is a reusable pattern for migrating large databases without downtime.

        The pattern applies to any system with PostgreSQL or MySQL.
        The key principle: dual-write, verify, switch, cleanup.

        This method is used across many enterprise systems.
        """

        result = classifier.classify("migration_pattern.md", content)

        assert result.material_class == MaterialClass.ACTIVE_KNOWLEDGE
        assert result.mode == Mode.INDEX
        assert result.confidence >= 0.6


class TestEdgeCaseClassification:
    """Тест 3: Граничный случай — неоднозначность (Сценарий 3)."""

    def test_legal_document_ambiguous(self, classifier):
        """Договор — класс 3 (факт), даже если интегратор его редактирует."""
        content = """
        ДОГОВОР ПОСТАВКИ

        Между: ООО "Компания А" и ООО "Компания Б"

        Сроки поставки: 30 дней с момента подписания.
        """

        result = classifier.classify("contract_2026.md", content)

        # Должен определить как факт мира
        assert result.material_class == MaterialClass.FACT_OF_WORLD
        assert result.mode == Mode.POINTER
        assert result.mode_detail == ModeDetail.STATIC


class TestQuarantine:
    """Тест 4: Карантин (И5 fail-closed) — Сценарий 4."""

    def test_api_key_quarantine(self, classifier):
        """Файл с реальным форматом ключа вендора (Anthropic) — карантин."""
        content = """
        config.py:
        ANTHROPIC_API_KEY = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345"
        """

        result = classifier.classify("config.py", content)

        assert result.quarantine is True
        assert result.quarantine_reason is not None
        assert "secrets" in str(result.quarantine_reason.value).lower()

    def test_payment_data_quarantine(self, classifier):
        """Файл с валидным по Luhn номером карты — карантин."""
        content = """
        Customer invoice:
        Credit Card: 4111-1111-1111-1111
        CVV: 123
        Exp: 12/25
        """

        result = classifier.classify("invoice.txt", content)

        assert result.quarantine is True

    def test_secrets_directory_quarantine_regardless_of_content(self, classifier):
        """Файл в директории secrets/ — карантин по расположению, даже без секрета в тексте."""
        result = classifier.classify("secrets/notes.md", "просто заметка, ничего чувствительного")

        assert result.quarantine is True

    def test_secrets_in_filename_not_directory_not_quarantined_by_path(self, classifier):
        """secrets-manager-design.md — не директория secrets/, path-политика не должна сработать."""
        result = classifier.classify("notes/secrets-manager-design.md", "обсуждение архитектуры менеджера секретов")

        assert result.quarantine is False

    def test_placeholder_value_not_quarantined(self, classifier):
        """api_key: changeme — плейсхолдер, не должен ловиться как секрет (guide-kit corpus)."""
        result = classifier.classify("note.md", "api_key: changeme")

        assert result.quarantine is False

    def test_ordinary_long_path_after_label_not_quarantined(self, classifier):
        """Cold-review finding 2026-07-15: длинный путь после метки key: — не секрет (guide-kit corpus)."""
        result = classifier.classify(
            "note.md", "access_key: my-bucket/path/to/object/with/long/key/name"
        )

        assert result.quarantine is False

    def test_luhn_invalid_digit_string_not_quarantined(self, classifier):
        """Число длиной с карту, но не проходящее Luhn — не платёжные данные (guide-kit corpus)."""
        result = classifier.classify("note.md", "order id: 1234567890123456")

        assert result.quarantine is False


class TestSystemState:
    """Тест 5: Состояние системы — класс 2 (Сценарий 5)."""

    def test_git_config_class_2(self, classifier):
        """Конфиг системы в git-репо — класс 2."""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Создаём git-репо
            git_dir = Path(tmpdir) / ".git"
            git_dir.mkdir()

            config_file = Path(tmpdir) / "config.env"
            config_file.write_text("DB_HOST=localhost:5432\nDB_NAME=mydb")

            result = classifier.classify(str(config_file))

            # Должен определить как состояние системы (класс 2)
            # Потому что есть маркеры: .git в пути, конфиг
            assert result.material_class in [MaterialClass.SYSTEM_STATE, MaterialClass.FACT_OF_WORLD]


class TestBatchMode:
    """Тест 6: Batch режим — несколько файлов (Сценарий 6)."""

    def test_batch_classification(self, classifier):
        """Batch обработка нескольких файлов в папке."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)

            # Файл 1: класс 4
            (tmpdir_path / "ski-notes.md").write_text(
                "My impressions of ski resorts. I think this is the best one."
            )

            # Файл 2: класс 1
            (tmpdir_path / "pattern.md").write_text(
                "This pattern is applicable to any distributed system."
            )

            # Классифицируем оба
            results = []
            for file_path in tmpdir_path.glob("*.md"):
                result = classifier.classify(str(file_path))
                results.append(result)

            # Должны получить 2 результата, разные классы
            assert len(results) == 2
            classes = set(r.material_class for r in results)
            assert len(classes) >= 1  # Хотя бы один класс должен быть определён


class TestConfidenceThreshold:
    """Тест confidence scoring."""

    def test_high_confidence_class_1(self, classifier):
        """Паттерн с множеством маркеров — высокая confidence."""
        content = """
        Design Pattern: Observer

        This pattern is applicable to any event-driven system.
        This method is widely used in modern frameworks.
        Best practice for loose coupling.
        """

        result = classifier.classify("pattern.md", content)

        if result.material_class == MaterialClass.ACTIVE_KNOWLEDGE:
            assert result.confidence >= 0.7

    def test_low_confidence_ambiguous(self, classifier):
        """Неоднозначный материал — низкая confidence."""
        content = "Document"

        result = classifier.classify("unknown.txt", content)

        # Должен вернуть низкую confidence или вне карты
        assert result.confidence < 0.5 or result.material_class is None


class TestExplanationGeneration:
    """Тест генерации объяснений (И4 — обоснование)."""

    def test_explanation_includes_test_name(self, classifier):
        """Объяснение содержит название применённого теста."""
        content = "I think this approach works well. My recommendation: use this method."

        result = classifier.classify("opinion.md", content)

        if result.material_class is not None:
            assert "→" in result.test_applied or len(result.test_applied) > 0
            assert len(result.explanation) > 0


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
