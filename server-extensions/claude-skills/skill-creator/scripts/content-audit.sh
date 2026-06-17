#!/usr/bin/env bash
# content-audit.sh — minimal content check for IWE skills (WP-422 Ф9)
# Checks 5 structural+content criteria for each skill in .claude/skills/
# Outputs: RED (>=2 issues), YELLOW (1 issue), GREEN (0 issues)
set -euo pipefail

SKILLS_DIR="${IWE_DIR:-$HOME/IWE}/.claude/skills"
SKIP_SKILLS="${SKIP_SKILLS:-agent-fault apply-captures skill-creator}"

RED=0; YELLOW=0; GREEN=0
declare -a RED_LIST YELLOW_LIST

audit_skill() {
  local name="$1"
  local skill_md="$SKILLS_DIR/$name/SKILL.md"
  local issues=0
  local issue_list=""

  if [[ ! -f "$skill_md" ]]; then
    return
  fi

  # C1: gates_rationale non-empty when gates_required or gates_enforced are non-empty
  local gates_req gates_enf gates_rat
  gates_req=$(grep -E '^gates_required:' "$skill_md" | sed 's/gates_required:[[:space:]]*//' | tr -d '[]' | tr -d ' ' || true)
  gates_enf=$(grep -E '^gates_enforced:' "$skill_md" | sed 's/gates_enforced:[[:space:]]*//' | tr -d '[]' | tr -d ' ' || true)
  gates_rat=$(grep -E '^gates_rationale:' "$skill_md" | sed 's/gates_rationale:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)

  local has_gates=false
  [[ -n "$gates_req" && "$gates_req" != "" ]] && has_gates=true
  [[ -n "$gates_enf" && "$gates_enf" != "" ]] && has_gates=true

  if $has_gates && [[ -z "$gates_rat" || "$gates_rat" == "\"\"" || "$gates_rat" == "''" ]]; then
    issues=$((issues + 1))
    issue_list+=" C1:gates_rationale_missing"
  fi

  # C2: "## Algorithm" section present
  if ! grep -q '^## Algorithm' "$skill_md"; then
    issues=$((issues + 1))
    issue_list+=" C2:no_algorithm_section"
  fi

  # C3: >= 3 step-like headings (##/### level) anywhere in file
  # Accepts: "## Шаг N", "## Step N", "### N.", "### Фn", "### n —", etc.
  local step_count
  step_count=$(grep -cE '^#{2,3} (Step|Шаг|Phase) [0-9]|^#{2,3} Ф[0-9]|^#{2,3} [0-9]+[а-яa-z]?\. |^#{2,3} [0-9]+[а-яa-z]? (—|-)' "$skill_md" || true)
  if [[ "$step_count" -lt 3 ]]; then
    issues=$((issues + 1))
    issue_list+=" C3:steps_lt_3(found:${step_count})"
  fi

  # C4: each "### Step N" has >= 2 non-empty lines after it
  local step_fail=0
  local in_step=false
  local step_content_count=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^###\ Step\ [0-9] ]]; then
      # check previous step
      if $in_step && [[ "$step_content_count" -lt 2 ]]; then
        step_fail=$((step_fail + 1))
      fi
      in_step=true
      step_content_count=0
    elif $in_step; then
      if [[ "$line" =~ ^## ]]; then
        # new top-level section, close current step
        if [[ "$step_content_count" -lt 2 ]]; then
          step_fail=$((step_fail + 1))
        fi
        in_step=false
      elif [[ -n "$line" && ! "$line" =~ ^#+ ]]; then
        step_content_count=$((step_content_count + 1))
      fi
    fi
  done < "$skill_md"
  # check last step
  if $in_step && [[ "$step_content_count" -lt 2 ]]; then
    step_fail=$((step_fail + 1))
  fi
  if [[ "$step_fail" -gt 0 ]]; then
    issues=$((issues + 1))
    issue_list+=" C4:empty_steps(${step_fail})"
  fi

  # C5: "## When to use" section present
  if ! grep -q '^## When to use' "$skill_md"; then
    issues=$((issues + 1))
    issue_list+=" C5:no_when_to_use"
  fi

  # Classify
  if [[ "$issues" -ge 2 ]]; then
    RED=$((RED + 1))
    RED_LIST+=("$name$issue_list")
    printf "  RED    %-30s %s\n" "$name" "$issue_list"
  elif [[ "$issues" -eq 1 ]]; then
    YELLOW=$((YELLOW + 1))
    YELLOW_LIST+=("$name$issue_list")
    printf "  YELLOW %-30s %s\n" "$name" "$issue_list"
  else
    GREEN=$((GREEN + 1))
    printf "  GREEN  %-30s\n" "$name"
  fi
}

echo "=== content-audit.sh — WP-422 Ф9 ==="
echo "Skills dir: $SKILLS_DIR"
echo "Skipping:   $SKIP_SKILLS"
echo ""

for skill_path in "$SKILLS_DIR"/*/; do
  skill_name=$(basename "$skill_path")
  if echo "$SKIP_SKILLS" | grep -qw "$skill_name"; then
    continue
  fi
  audit_skill "$skill_name"
done

TOTAL=$((RED + YELLOW + GREEN))
echo ""
echo "=== Summary: $TOTAL skills audited ==="
echo "  GREEN  (0 issues, minimal-content gate): $GREEN"
echo "  YELLOW (1 issue, fix by type):           $YELLOW"
echo "  RED    (2+ issues, needs VDV audit):     $RED"
echo ""
echo "NOTE: GREEN = minimal structural+content barrier, not 'perfect skill'."
echo "      Logic errors in GREEN skills are possible — this audit checks structure only."
echo ""
if [[ ${#RED_LIST[@]} -gt 0 ]]; then
  echo "=== RED skills (need VDV audit) ==="
  for s in "${RED_LIST[@]}"; do
    echo "  $s"
  done
fi
if [[ ${#YELLOW_LIST[@]} -gt 0 ]]; then
  echo "=== YELLOW skills (single fix) ==="
  for s in "${YELLOW_LIST[@]}"; do
    echo "  $s"
  done
fi
