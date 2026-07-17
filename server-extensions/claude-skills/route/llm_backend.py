"""LLM backend для deep-inspect классификации (Phase B)."""

import json
from typing import Optional
from anthropic import Anthropic
from models import ClassificationResult, MaterialClass, Mode, ModeDetail, QuarantineReason


class LLMClassifier:
    """LLM-based глубокая классификация при сомнении (confidence < threshold)."""

    def __init__(self, model: str = "sonnet"):
        self.client = Anthropic()
        self.model = model
        self.system_prompt = self._build_system_prompt()

    def _build_system_prompt(self) -> str:
        return """Ты — классификатор материала пользователя по модели DP.KR.002.

Твоя задача: классифицировать материал в один из 4 классов:
1. Активное знание (паттерн/метод/концепт, применимо к другим системам)
2. Состояние системы (про конкретную систему пользователя, current state)
3. Факт мира (иммутабельный, внешний факт — юридический, физический)
4. Субъективная оценка (моя позиция, мнение, revisable)

Также проверяй карантин: если материал содержит чужие PII, секреты, платёжные данные — это карантин.

Ответ — JSON:
{
  "class": 1 | 2 | 3 | 4 | null,
  "class_name": "string",
  "home": "string (где хранить)",
  "mode": "index" | "pointer" | "external",
  "mode_detail": "sync" | "static" | "candidate" | null,
  "test_applied": "string (какой тест прошёл)",
  "confidence": 0.0-1.0,
  "explanation": "string (почему этот класс)",
  "quarantine": boolean,
  "quarantine_reason": "string | null"
}

Используй русский язык в ответах."""

    def classify_with_llm(self, material_path: str, content: str, model: Optional[str] = None) -> ClassificationResult:
        """Классифицировать через LLM (медленнее, но точнее)."""
        if not model:
            model = self.model

        user_message = f"""Классифицируй материал:

Имя: {material_path}
Первые 500 символов содержимого:
{content[:500]}

Ответ — только JSON без markdown-блока."""

        try:
            message = self.client.messages.create(
                model=model,
                max_tokens=1024,
                system=self.system_prompt,
                messages=[{"role": "user", "content": user_message}],
            )

            response_text = message.content[0].text.strip()

            # Попытка парсить JSON
            if response_text.startswith("```"):
                response_text = response_text.split("```")[1]
                if response_text.startswith("json"):
                    response_text = response_text[4:]
                response_text = response_text.strip()

            result_dict = json.loads(response_text)

            # Конвертируем в ClassificationResult
            return self._dict_to_result(material_path, result_dict)

        except Exception as e:
            # Fallback: вернуть пусто результат с ошибкой
            return ClassificationResult(
                material_name=material_path,
                confidence=0.0,
                explanation=f"LLM classification failed: {str(e)}",
                test_applied="LLM (failed)",
            )

    def _dict_to_result(self, material_path: str, data: dict) -> ClassificationResult:
        """Конвертировать LLM JSON response в ClassificationResult."""
        class_num = data.get("class")
        material_class = None
        if class_num:
            material_class = MaterialClass(class_num)

        mode = None
        if data.get("mode"):
            try:
                mode = Mode(data["mode"])
            except ValueError:
                pass

        mode_detail = None
        if data.get("mode_detail"):
            try:
                mode_detail = ModeDetail(data["mode_detail"])
            except ValueError:
                pass

        quarantine_reason = None
        if data.get("quarantine_reason"):
            try:
                quarantine_reason = QuarantineReason(data["quarantine_reason"])
            except ValueError:
                pass

        return ClassificationResult(
            material_name=material_path,
            material_class=material_class,
            home=data.get("home", ""),
            mode=mode,
            mode_detail=mode_detail,
            test_applied=data.get("test_applied", "LLM classification"),
            confidence=float(data.get("confidence", 0.0)),
            explanation=data.get("explanation", ""),
            quarantine=data.get("quarantine", False),
            quarantine_reason=quarantine_reason,
        )
