"""Models и тесты классификации по DP.KR.002."""

from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

from quarantine_detectors import detect_payment, detect_secret


class MaterialClass(Enum):
    ACTIVE_KNOWLEDGE = 1
    SYSTEM_STATE = 2
    FACT_OF_WORLD = 3
    SUBJECTIVE_EVAL = 4


class Mode(Enum):
    INDEX = "index"
    POINTER = "pointer"
    EXTERNAL = "external"


class ModeDetail(Enum):
    SYNC = "sync"
    STATIC = "static"
    CANDIDATE = "candidate"


class QuarantineReason(Enum):
    FOREIGN_PII = "foreign_pii"
    SECRETS = "secrets"
    PAYMENT_DATA = "payment_data"


@dataclass
class ClassificationResult:
    material_name: str
    material_class: Optional[MaterialClass] = None
    home: str = ""
    mode: Optional[Mode] = None
    mode_detail: Optional[ModeDetail] = None
    test_applied: str = ""
    confidence: float = 0.0
    explanation: str = ""
    alternative: Optional['ClassificationResult'] = None
    quarantine: bool = False
    quarantine_reason: Optional[QuarantineReason] = None

    def to_json(self) -> dict:
        return {
            "input": self.material_name,
            "class": self.material_class.value if self.material_class else None,
            "class_name": self.material_class.name.replace("_", " ") if self.material_class else None,
            "home": self.home,
            "mode": self.mode.value if self.mode else None,
            "mode_detail": self.mode_detail.value if self.mode_detail else None,
            "test_applied": self.test_applied,
            "confidence": self.confidence,
            "explanation": self.explanation,
            "alternative": self.alternative.to_json() if self.alternative else None,
            "quarantine": self.quarantine,
            "quarantine_reason": self.quarantine_reason.value if self.quarantine_reason else None,
        }


class ClassificationTests:
    @staticmethod
    def test_class_1(content: str, metadata: dict) -> tuple:
        keywords_class_1 = ["pattern", "method", "principle", "approach", "framework", "algorithm", "design"]
        content_lower = content.lower()
        matches = sum(1 for kw in keywords_class_1 if kw in content_lower)
        is_universal = matches >= 2
        confidence = 0.85 if matches >= 2 else 0.0
        test_text = f"Применимо к другим системам? {'→ ДА' if is_universal else '→ НЕТ'}"
        return is_universal, confidence, test_text

    @staticmethod
    def test_class_2(filepath: str, metadata: dict) -> tuple:
        is_concrete = bool(filepath) and ("DS-" in filepath or ".git" in filepath or metadata.get("has_git_history", False))
        confidence = 0.9 if is_concrete else 0.0
        test_text = f"Про конкретную систему? {'→ ДА' if is_concrete else '→ НЕТ'}"
        return is_concrete, confidence, test_text

    @staticmethod
    def test_class_3(content: str, filepath: str, metadata: dict) -> tuple:
        keywords_class_3 = ["закон", "договор", "декларация", "свидетельство", "law", "contract"]
        is_legal_doc = any(kw in content.lower() or kw in filepath.lower() for kw in keywords_class_3)
        confidence = 0.95 if is_legal_doc else 0.0
        test_text = f"Могу изменить? {'→ НЕТ (факт)' if is_legal_doc else '→ ДА'}"
        return is_legal_doc, confidence, test_text

    @staticmethod
    def test_class_4(content: str, filepath: str, metadata: dict) -> tuple:
        keywords_class_4 = ["я думаю", "мне кажется", "мое мнение", "оценка", "i think", "i recommend"]
        is_subjective = any(kw in content.lower() for kw in keywords_class_4)
        confidence = 0.85 if is_subjective else 0.0
        test_text = f"Это моя позиция? {'→ ДА' if is_subjective else '→ НЕТ'}"
        return is_subjective, confidence, test_text

    # Собственная политика /route — карантин по расположению файла, независимо от
    # содержимого. В guide-kit такой проверки нет (там rel_path участвует только в
    # forced-flag/логировании), поэтому это не часть detector-core и не входит в
    # parity-тест. Матчится по компонентам пути (директории), не по всей строке —
    # иначе "notes/secrets-manager-design.md" стал бы ложным срабатыванием.
    PATH_QUARANTINE_KEYWORDS = frozenset({"secrets", "secret", "credentials", "private"})

    @staticmethod
    def test_quarantine(content: str, filepath: str) -> tuple:
        if ClassificationTests.PATH_QUARANTINE_KEYWORDS & {p.lower() for p in Path(filepath).parts}:
            return True, QuarantineReason.SECRETS

        if detect_secret(content) is not None:
            return True, QuarantineReason.SECRETS

        if detect_payment(content) is not None:
            return True, QuarantineReason.PAYMENT_DATA

        return False, None
