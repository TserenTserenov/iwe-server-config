"""Поведенческий parity-тест против guide-kit/structurer/quarantine.py
(peer-session 2026-07-15-04, РП449 Ф4.2). Test-time-only importlib-загрузка —
без runtime cross-repo зависимости у /route. Если оригинал недалеко (другая
машина, guide-kit ещё не клонирован) — тест скипается с предупреждением, а не
падает CI.
"""
import importlib.util
import os
import sys
from pathlib import Path

import pytest

_ROUTE_DIR = str(Path(__file__).parent.parent)
if _ROUTE_DIR not in sys.path:
    sys.path.insert(0, _ROUTE_DIR)
from quarantine_detectors import detect_payment, detect_secret  # noqa: E402

GUIDE_KIT_STRUCTURER = Path(
    os.environ.get("IWE_GUIDE_KIT_PATH", os.path.expanduser("~/IWE/guide-kit"))
) / "structurer"


def _load_guide_kit_quarantine():
    module_path = GUIDE_KIT_STRUCTURER / "quarantine.py"
    if not module_path.exists():
        return None
    sys.path.insert(0, str(GUIDE_KIT_STRUCTURER))
    try:
        spec = importlib.util.spec_from_file_location("guide_kit_quarantine", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(str(GUIDE_KIT_STRUCTURER))


guide_kit_quarantine = _load_guide_kit_quarantine()

pytestmark = pytest.mark.skipif(
    guide_kit_quarantine is None,
    reason=f"guide-kit не найден по пути {GUIDE_KIT_STRUCTURER} — parity-проверка пропущена",
)

# Adversarial-корпус, портированный из guide-kit/structurer/test_quarantine.py +
# один синтетический пробник на каждый vendor-паттерн /route.
SECRET_CORPUS = [
    ("just a regular note about my day", None),
    ("aws key: AKIAABCDEFGHIJ12345K", "known-vendor-format"),
    ("-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----", "known-vendor-format"),
    ('api_key: "aB3xQ9zL2mK7pR4tY8wN"', "labeled-high-entropy-assignment"),
    ("api_key: changeme", None),
    ("access_key: my-bucket/path/to/object/with/long/key/name", None),
    ("secret: this-is-a-fairly-long-dashed-phrase-not-a-real-secret", None),
    ("anthropic: sk-ant-api03-" + "A" * 30, "known-vendor-format"),
    ("github: ghp_" + "B" * 30, "known-vendor-format"),
    ("slack: xoxb-1111111111-aaaaaaaaaa", "known-vendor-format"),
    ("google: AIza" + "C" * 35, "known-vendor-format"),
]

PAYMENT_CORPUS = [
    ("card on file: 4111 1111 1111 1111", "luhn-valid-card-number"),
    ("order id: 1234567890123456", None),
    ("wire to GB29NWBK60161331926819", "iban-checksum"),
    ("ref code AB12CDEFGHIJKLMNOP", None),
]


@pytest.mark.parametrize("text, expected_detected_by", SECRET_CORPUS)
def test_secret_detector_parity(text, expected_detected_by):
    ours = detect_secret(text)
    theirs_result = guide_kit_quarantine._detect_secret(text)
    assert ours == expected_detected_by
    assert ours == theirs_result


@pytest.mark.parametrize("text, expected_detected_by", PAYMENT_CORPUS)
def test_payment_detector_parity(text, expected_detected_by):
    ours = detect_payment(text)
    theirs_result = guide_kit_quarantine._detect_payment(text)
    assert ours == expected_detected_by
    assert ours == theirs_result
