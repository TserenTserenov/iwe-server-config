#!/usr/bin/env python3
"""
integration-gate-classifier.py — AR.013 субагент-классификатор фазы IntegrationGate.

Принимает JSON-контекст из env _IG_CTX.
Возвращает JSON: {"phase": "sc|role|impl|unknown", "skip_detected": bool, "reason": str, "missing": [str]}

Логика:
- Если file_path указывает на impl-артефакт (DS-*/src/*.ts, hooks/, scripts/) без SC/Role в Pack → skip=True
- Если file_path указывает на SC-артефакт (08-service-clauses/) → phase=sc, skip=False
- Если file_path указывает на Role-артефакт (02-domain-entities/DP.ROLE.*) → phase=role, skip=False
- Иначе → phase=unknown, fallback к explicit ref-check в rule-engine.sh

WP-272 Ф5.4 (2026-04-29)
"""
import json, os, re, sys

ctx_str = os.environ.get("_IG_CTX", "{}")
try:
    ctx = json.loads(ctx_str)
except Exception:
    ctx = {}

file_path     = ctx.get("file_path", "")
sc_ref        = ctx.get("sc_ref", "")
role_ref      = ctx.get("role_ref", "")
scenarios     = ctx.get("scenarios_defined", False)
task_text     = ctx.get("task_description", "")
creation_type = ctx.get("creation_type", "")

# Детектируем SC/Role по содержимому файла
if file_path and os.path.isfile(file_path):
    try:
        content = open(file_path).read(8192)
        if re.search(r'DP\.SC\.\d+', content):
            sc_ref = "found_in_file"
        if re.search(r'DP\.ROLE\.\d+', content):
            role_ref = "found_in_file"
    except Exception:
        pass

# Определяем наличие SC/Role
sc_in_pack = bool(sc_ref) or (
    "PACK" in file_path and "service-clauses" in file_path
)
role_in_pack = bool(role_ref) or (
    "PACK" in file_path and "domain-entities" in file_path and "DP.ROLE" in file_path
)

# Определяем фазу по file_path
is_impl_artifact = bool(re.search(
    r'\.(py|ts|sh|js|go|rb)$'
    r'|\bDS-[A-Z]'
    r'|\bhooks/'
    r'|\bscripts/'
    r'|\bsrc/'
    r'|\blib/',
    file_path
))
is_sc_artifact   = bool(re.search(r'08-service-clauses|DP\.SC\.\d+', file_path))
is_role_artifact = bool(re.search(r'02-domain-entities.*DP\.ROLE|DP\.ROLE\.\d+', file_path))

# Определяем фазу по task_description
task_lower    = task_text.lower()
task_is_impl  = bool(re.search(r'реализа|кодирова|deploy|hook|script|создай скрипт|напиши код', task_lower))
task_is_sc    = bool(re.search(r'обещание|service clause|sc\.\d+|сценарий', task_lower))
task_is_role  = bool(re.search(r'роль|dp\.role', task_lower))

# Итоговая фаза
if is_sc_artifact or task_is_sc:
    phase = "sc"
elif is_role_artifact or task_is_role:
    phase = "role"
elif is_impl_artifact or task_is_impl:
    phase = "impl"
else:
    phase = "unknown"

# Skip detection: impl без SC+Role
skip_detected = (phase == "impl") and (not sc_in_pack) and (not role_in_pack)

# Собираем missing
missing = []
if not sc_in_pack:
    missing.append("DP.SC.NNN (обещание)")
if not bool(scenarios) and not sc_in_pack:
    missing.append("сценарии")
if not role_in_pack:
    missing.append("DP.ROLE.NNN (роль)")

reason = f"phase={phase}, skip={skip_detected}"
if missing:
    reason += f", missing=[{', '.join(missing)}]"

print(json.dumps({
    "phase": phase,
    "skip_detected": skip_detected,
    "reason": reason,
    "missing": missing
}))
