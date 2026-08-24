"""Route quarantine regression and guide-kit parity tests.

The guide-kit comparison remains optional. Canonical-corpus and fail-closed
tests always run because /route now shares vendor patterns with hook guards.
"""
import importlib.util
import os
import sys
from pathlib import Path

import pytest

_ROUTE_DIR = str(Path(__file__).parent.parent)
if _ROUTE_DIR not in sys.path:
    sys.path.insert(0, _ROUTE_DIR)
import quarantine_detectors as detectors  # noqa: E402

detect_payment = detectors.detect_payment
detect_secret = detectors.detect_secret

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

PARITY_SKIP = pytest.mark.skipif(
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

CANONICAL_SECRET_CORPUS = [
    ("openai: sk-proj-" + "P" * 28, "known-vendor-format"),
    ("github: github_pat_" + "F" * 30, "known-vendor-format"),
    (
        "installation: ghs_12345_eyJ"
        + "A" * 12
        + "."
        + "B" * 12
        + "."
        + "C" * 12,
        "known-vendor-format",
    ),
    ("sk-proj-short", None),
    ("github_pat_example", None),
]


@pytest.mark.parametrize("text, expected_detected_by", SECRET_CORPUS)
@PARITY_SKIP
def test_secret_detector_parity(text, expected_detected_by):
    ours = detect_secret(text)
    theirs_result = guide_kit_quarantine._detect_secret(text)
    assert ours == expected_detected_by
    assert ours == theirs_result


@pytest.mark.parametrize("text, expected_detected_by", PAYMENT_CORPUS)
@PARITY_SKIP
def test_payment_detector_parity(text, expected_detected_by):
    ours = detect_payment(text)
    theirs_result = guide_kit_quarantine._detect_payment(text)
    assert ours == expected_detected_by
    assert ours == theirs_result


@pytest.mark.parametrize("text, expected_detected_by", CANONICAL_SECRET_CORPUS)
def test_canonical_secret_corpus(text, expected_detected_by):
    assert detect_secret(text) == expected_detected_by


def test_secret_detector_fails_closed_when_helper_is_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(
        detectors,
        "_CANONICAL_SECRET_HELPER",
        tmp_path / "missing-secret-helper.sh",
    )

    assert detect_secret("ordinary text") == "canonical-detector-unavailable"


def test_secret_detector_fails_closed_on_unsafe_helper_output(monkeypatch, tmp_path):
    helper = tmp_path / "unsafe-secret-helper.sh"
    helper.write_text(
        "secret_pattern_process() { "
        "printf '%s\\n' "
        "'{\"pattern_ids\":[],\"match_count\":0,\"patterns\":[],"
        "\"matched_text\":\"must-not-be-trusted\"}'; "
        "}\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(detectors, "_CANONICAL_SECRET_HELPER", helper)

    assert detect_secret("ordinary text") == "canonical-detector-unavailable"


def test_secret_detector_does_not_echo_input(capsys):
    synthetic = "sk-proj-" + "N" * 28

    assert detect_secret(synthetic) == "known-vendor-format"
    captured = capsys.readouterr()
    assert synthetic not in captured.out
    assert synthetic not in captured.err
