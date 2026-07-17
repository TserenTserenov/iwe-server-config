"""Классификатор материала по DP.KR.002."""

import os
from pathlib import Path
from typing import Optional
from models import ClassificationResult, ClassificationTests, MaterialClass, Mode, ModeDetail


class MaterialClassifier:
    def __init__(self, llm_model: Optional[str] = None):
        self.tests = ClassificationTests()
        self.llm_model = llm_model
        self.llm_classifier = None
        if llm_model:
            try:
                from llm_backend import LLMClassifier
                self.llm_classifier = LLMClassifier(model=llm_model)
            except ImportError:
                pass

    def classify(self, material_path: str, material_description: str = "", use_llm_fallback: bool = True) -> ClassificationResult:
        metadata = self._extract_metadata(material_path)
        content = material_description if material_description else self._read_content(material_path)

        is_quarantine, quarantine_reason = self.tests.test_quarantine(content, material_path)
        if is_quarantine:
            return ClassificationResult(
                material_name=material_path,
                home="QUARANTINE",
                quarantine=True,
                quarantine_reason=quarantine_reason,
                test_applied=f"Карантин: {quarantine_reason.value if quarantine_reason else 'unknown'}",
                confidence=1.0,
            )

        results = self._run_all_tests(content, material_path, metadata)
        best_class, best_confidence, best_test = self._pick_best_class(results)

        # LLM fallback при низкой confidence (Phase B)
        if use_llm_fallback and best_confidence < 0.7 and self.llm_classifier:
            return self.llm_classifier.classify_with_llm(material_path, content)

        if best_class is None:
            return ClassificationResult(
                material_name=material_path,
                home="OUT_OF_MAP",
                test_applied="Ни один тест не прошёл",
                confidence=0.0,
                explanation="Материал вне карты классов 1-4",
            )

        home, mode, mode_detail = self._determine_home_and_mode(best_class, content, material_path, metadata)

        return ClassificationResult(
            material_name=material_path,
            material_class=best_class,
            home=home,
            mode=mode,
            mode_detail=mode_detail,
            test_applied=best_test,
            confidence=best_confidence,
            explanation=self._build_explanation(best_class, best_test, home),
        )

    def _extract_metadata(self, material_path: str) -> dict:
        metadata = {"has_git_history": False, "has_config": False, "is_archive": False}
        if os.path.exists(material_path):
            path_obj = Path(material_path)
            metadata["has_git_history"] = bool((path_obj.parent / ".git").exists())
        return metadata

    def _read_content(self, material_path: str, max_lines: int = 100) -> str:
        if not os.path.exists(material_path):
            return material_path
        try:
            with open(material_path, "r", encoding="utf-8", errors="ignore") as f:
                return "".join(f.readlines()[:max_lines])
        except Exception:
            return ""

    def _run_all_tests(self, content: str, filepath: str, metadata: dict) -> dict:
        results = {}
        is_class1, conf1, test1 = self.tests.test_class_1(content, metadata)
        results[MaterialClass.ACTIVE_KNOWLEDGE] = (is_class1, conf1, test1)
        is_class2, conf2, test2 = self.tests.test_class_2(filepath, metadata)
        results[MaterialClass.SYSTEM_STATE] = (is_class2, conf2, test2)
        is_class3, conf3, test3 = self.tests.test_class_3(content, filepath, metadata)
        results[MaterialClass.FACT_OF_WORLD] = (is_class3, conf3, test3)
        is_class4, conf4, test4 = self.tests.test_class_4(content, filepath, metadata)
        results[MaterialClass.SUBJECTIVE_EVAL] = (is_class4, conf4, test4)
        return results

    def _pick_best_class(self, results: dict) -> tuple:
        candidates = [(klass, conf, test) for klass, (matched, conf, test) in results.items() if matched]
        if not candidates:
            return None, 0.0, ""
        best = max(candidates, key=lambda x: x[1])
        return best[0], best[1], best[2]

    def _determine_home_and_mode(self, klass, content: str, filepath: str, metadata: dict) -> tuple:
        if klass == MaterialClass.ACTIVE_KNOWLEDGE:
            return "PACK-<домен>", Mode.INDEX, None
        elif klass == MaterialClass.SYSTEM_STATE:
            return "DS-<system>", Mode.POINTER, ModeDetail.SYNC
        elif klass == MaterialClass.FACT_OF_WORLD:
            return "Vault/внешний", Mode.POINTER, ModeDetail.STATIC
        elif klass == MaterialClass.SUBJECTIVE_EVAL:
            return "внешний + карточка", Mode.POINTER, ModeDetail.CANDIDATE
        else:
            return "UNKNOWN", Mode.EXTERNAL, None

    def _build_explanation(self, klass, test: str, home: str) -> str:
        class_names = {
            MaterialClass.ACTIVE_KNOWLEDGE: "Активное знание",
            MaterialClass.SYSTEM_STATE: "Состояние системы",
            MaterialClass.FACT_OF_WORLD: "Факт мира",
            MaterialClass.SUBJECTIVE_EVAL: "Субъективная оценка",
        }
        return f"{class_names.get(klass, 'Unknown')}. Тест: {test}. Дом: {home}."
