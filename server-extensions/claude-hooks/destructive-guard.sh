#!/usr/bin/env bash
# PreToolUse:Bash guard — blocks irreversible operations: git (staging, history,
# push/reset/clean), filesystem (rm -rf outside temp paths), prod DB (psql
# DROP/TRUNCATE/DELETE without WHERE), GitHub repo deletion. Exit 2 = block.
set -euo pipefail

# Read stdin once: a pipe/redirected fd is fully drained by the first jq call,
# so a second `jq` reading raw stdin always sees EOF and returns empty — this
# silently zeroed out $CWD on every invocation (found WP-547, 03.09, while
# verifying the stash-pop/apply check below, which depends on the real cwd).
HOOK_INPUT=$(cat 2>/dev/null || true)
CMD=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0
CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null || true)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE_ROOT="$(cd "$HOOK_DIR/../.." && pwd -P)"

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# Bypass: только из реального шелла пилота (тот же контракт, что secret-leak-block.sh —
# хук читает свой процессный env, не текст команды, агент не может выставить это сам себе).
# Строгое сравнение с "1" (не -n) — та же несогласованность в secret-leak-block.sh
# (там -n) допустима для существующего кода, но не стоит копировать её в новый
# (пир-ревью Codex, WP-544 Ф1, 20.08): -n пропустил бы CC_ALLOW_DESTRUCTIVE_INPUT=0 как bypass.
[ "${CC_ALLOW_DESTRUCTIVE_INPUT:-}" = "1" ] && exit 0

# #362: a top-level `cd` persists between Bash calls in Claude Code. Strip
# quoted spans before detecting command segments; `(cd ... && ...)` remains
# allowed because the opening parenthesis is not a top-level separator.
if CMD_SCAN="$CMD" perl -e '
  my $s=$ENV{"CMD_SCAN"};
  $s =~ s/'"'"'[^'"'"']*'"'"'/ Q /g;
  $s =~ s/"(?:\\.|[^"\\])*"/ Q /g;
  exit($s =~ /(?:^|[;&|]\s*)cd\s+/ ? 0 : 1);
'; then
  block "верхнеуровневый cd запрещён: используй git -C <path>, абсолютный путь или (cd <path> && ...)."
fi

if [ -n "$CWD" ]; then
  CWD_PHYSICAL=$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")
  if [ "$CWD_PHYSICAL" != "$WORKSPACE_ROOT" ] && \
     echo "$CMD" | grep -qE "(^|[[:space:]\"'])(\\.claude/|scripts/|memory/)"; then
    block "root-relative path вызван из cwd=$CWD_PHYSICAL; используй абсолютный путь от $WORKSPACE_ROOT."
  fi
fi

git_segment() {
  # Return a normalised shell segment only when `git <global-opts> <subcmd>`
  # is the command being executed. A regex over the raw command saw `git reset`
  # inside a quoted argument of another program as an actual Git command.
  local subcmd="$1"
  SUBCMD="$subcmd" CMD_SCAN="$CMD" perl -e '
    sub words {
      my ($text) = @_;
      my (@out, $word, $quote) = ();
      for (my $i = 0; $i < length($text); $i++) {
        my $char = substr($text, $i, 1);
        if (defined $quote) {
          if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
            $word .= substr($text, ++$i, 1);
          } elsif ($char eq $quote) {
            undef $quote;
          } else {
            $word .= $char;
          }
        } elsif ($char eq q{"} || $char eq chr(39)) {
          $quote = $char;
        } elsif ($char eq "\\" && $i + 1 < length($text)) {
          $word .= substr($text, ++$i, 1);
        } elsif ($char =~ /\s/) {
          push @out, $word if length $word;
          $word = q{};
        } else {
          $word .= $char;
        }
      }
      push @out, $word if length $word;
      return @out;
    }

    sub inspect_segment {
      my ($segment) = @_;
      my @tokens = words($segment);
      return unless @tokens;
      my $i = 0;
      while ($i < @tokens) {
        if ($tokens[$i] =~ /^[A-Za-z_][A-Za-z0-9_]*=/ ||
            $tokens[$i] =~ /^(?:command|env|nohup|time|sudo)$/) {
          $i++;
        } else {
          last;
        }
      }
      return unless $i < @tokens && $tokens[$i] eq "git";
      my $start = $i++;
      while ($i < @tokens) {
        if ($tokens[$i] =~ /^-C$/ || $tokens[$i] =~ /^--(?:git-dir|work-tree)$/ || $tokens[$i] =~ /^-c$/) {
          $i += 2;
        } elsif ($tokens[$i] =~ /^--(?:git-dir|work-tree)=/ || $tokens[$i] =~ /^-c/) {
          $i++;
        } else {
          last;
        }
      }
      return unless $i < @tokens && $tokens[$i] eq $ENV{"SUBCMD"};
      # Print and keep scanning — a compound command can chain more than one
      # `git <subcmd>` invocation (`git push origin main && git push origin
      # +:refs/heads/x`); exiting after the first match here used to hide
      # every later one from every check that reads $PUSH_SEGMENT/etc, since
      # they all share this one function (cold review, WP-544 Ф8, 04.09).
      print join(" ", @tokens[$start .. $#tokens]), "\n";
    }

    my $text = $ENV{"CMD_SCAN"};
    my ($segment, $quote) = (q{}, undef);
    for (my $i = 0; $i < length($text); $i++) {
      my $char = substr($text, $i, 1);
      if (defined $quote) {
        $segment .= $char;
        if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
          $segment .= substr($text, ++$i, 1);
        } elsif ($char eq $quote) {
          undef $quote;
        }
      } elsif ($char eq q{"} || $char eq chr(39)) {
        $quote = $char;
        $segment .= $char;
      } elsif ($char =~ /[;&|(){}]/ || $char eq q{`}) {
        inspect_segment($segment);
        $segment = q{};
      } else {
        $segment .= $char;
      }
    }
    inspect_segment($segment);
  '
}

is_git_subcmd() {
  [ -n "$(git_segment "$1")" ]
}

# git push --force / -f (allow the safe --force-with-lease)
PUSH_SEGMENT=$(git_segment push)
if [ -n "$PUSH_SEGMENT" ]; then
  PUSH_FORCE_SCAN=$(echo "$PUSH_SEGMENT" | sed -E 's/--force-with-lease(=[^[:space:]]*)?//g')
  if echo "$PUSH_FORCE_SCAN" | grep -qE -- '(^|[[:space:]])(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --force запрещён. Используй --force-with-lease или согласуй с владельцем (CLAUDE.md §2)."
  fi

  # git push --delete / -d and refspec deletion (:<ref>, or +:<ref> force-form)
  # — same irreversible class as --force (WP-544 Д28). `-d` really is git's
  # short form of --delete (verified: `git push --help` lists `[-f | --force]
  # [-d | --delete]`; short form for --dry-run is `-n`, unrelated letter).
  # `--del`/`--delet`/... also match: git's own prefix matching accepts any
  # unambiguous abbreviation of a long option, and confirmed live that
  # `--delet` executes as `--delete` (no other push option starts with "de").
  # Matched only inside $PUSH_SEGMENT, never the raw $CMD — a same-day live
  # incident in this session
  # (bug-2026-09-04-destructive-guard-rm-rf-false-positive-cross-command.md)
  # showed whole-command matching false-triggers on unrelated flags in other
  # commands of the same compound Bash call. Known residual: variable
  # obfuscation (REF=":main"; git push origin $REF) is not caught — the hook
  # only sees literal command text, the same limit already documented for the
  # neighbouring secret hooks (Д6.3).
  if echo "$PUSH_SEGMENT" | grep -qE -- '(^|[[:space:]])(--de[a-zA-Z]*([[:space:]]|=|$)|-[a-zA-Z]*d[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --delete запрещён — удаление удалённой ветки/тега необратимо. Согласуй с владельцем (CLAUDE.md §2)."
  fi
  if echo "$PUSH_SEGMENT" | grep -qE -- '(^|[[:space:]])\+?:[^[:space:]]+'; then
    block "git push с refspec-удалением (:<ref> или +:<ref>) запрещён — удаление удалённой ветки/тега необратимо. Согласуй с владельцем (CLAUDE.md §2)."
  fi

  # git push --mirror — same class again (found in peer review, WP-544 Ф8,
  # 04.09): syncs the remote to exactly the local ref set, silently deleting
  # any remote branch/tag that doesn't exist locally. Not named in the
  # original Д28 report but closed alongside it — same failure mode, cheap
  # to cover while already here. `--mi`/`--mir`/... also match — confirmed
  # live that `--mir` executes as `--mirror` (no other push option starts
  # with "mi").
  if echo "$PUSH_SEGMENT" | grep -qE -- '(^|[[:space:]])--mi[a-zA-Z]*([[:space:]]|=|$)'; then
    block "git push --mirror запрещён — синхронизирует remote с локальными ссылками, удаляя отсутствующие локально ветки/теги. Согласуй с владельцем (CLAUDE.md §2)."
  fi
fi

# A hard reset is safe only when it cannot discard tracked work or local history:
# the tree must be clean and the target must contain the current HEAD. This still
# blocks resets that rewind a branch or erase uncommitted changes, while allowing
# a no-loss fast-forward reset used to repair a stale mirror.
reset_is_non_destructive() {
  local segment="$1" repo="${CWD:-$PWD}" target="" hard=false
  set -- $segment
  [ "${1:-}" = "git" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="${2:-}"; shift 2 ;;
      --git-dir|--work-tree|-c) shift 2 ;;
      --git-dir=*|--work-tree=*|-c*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "reset" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --hard) hard=true ;;
      --) shift; [ $# -eq 1 ] || return 1; target="$1"; break ;;
      -*) ;;
      *) [ -z "$target" ] || return 1; target="$1" ;;
    esac
    shift
  done
  [ "$hard" = true ] && [ -n "$target" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$repo" diff --quiet || return 1
  git -C "$repo" diff --cached --quiet || return 1
  git -C "$repo" merge-base --is-ancestor HEAD "$target" 2>/dev/null
}

# git reset --hard — one $RESET_SEGMENT line per chained `git reset` in the
# command (WP-544 Ф8, 04.09: git_segment now returns every match, not just
# the first — a compound `git reset --hard a && git reset --hard b` used to
# hide the second call from this same check). reset_is_non_destructive()
# parses token positions for exactly one invocation, so each line is checked
# on its own, not concatenated.
RESET_SEGMENT=$(git_segment reset)
if [ -n "$RESET_SEGMENT" ]; then
  while IFS= read -r one_reset; do
    [ -n "$one_reset" ] || continue
    if echo "$one_reset" | grep -qE -- '(^|[[:space:]])--hard([[:space:]]|$)' && ! reset_is_non_destructive "$one_reset"; then
      block "git reset --hard запрещён (теряет незакоммиченное). Используй git stash."
    fi
  done <<< "$RESET_SEGMENT"
fi

# git clean with delete flags (-f/-d/-x)
CLEAN_SEGMENT=$(git_segment clean)
if [ -n "$CLEAN_SEGMENT" ] && echo "$CLEAN_SEGMENT" | grep -qE -- '(^|[[:space:]])-[a-zA-Z]*[dfx]'; then
  block "git clean -fdx запрещён (удаляет неотслеживаемые файлы). Согласуй с владельцем."
fi

# git add -A/--all/-u/--update/bare-dot (I7, WP-458: AR.216 жил только в rule-engine.sh
# check_git_staged_only(), которая никогда не диспатчилась ни на одно живое событие —
# реальная защита срабатывала только на commit (install-hooks.sh Check 8), уже после
# стейджа. Здесь — фактический PreToolUse барьер, до того как чужие файлы попадут в индекс.
# WP-544 Ф1 Д5, 21.08: перенесено из личной установки, где было с 17.07 — устраняет
# расхождение версий хука между личной установкой и этим шаблоном.)
ADD_SEGMENT=$(git_segment add)
if [ -n "$ADD_SEGMENT" ]; then
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])(-A|--all|-u|--update)([[:space:]]|$)'; then
    block "git add -A/--all/-u/--update запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])\.([[:space:]]|$)'; then
    block "git add . запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
fi

# git stash pop/apply возвращает содержимое чужой заначки целиком, без разбора по
# файлам — слепой pop/apply молча теряет уже закоммиченные/задеплоенные артефакты,
# если заначка содержит удаления (WP-547, 03.09: именно так был утерян файл уже
# применённой к проду миграции — агент увидел "deleted: ..." в списке файлов чужого
# автостэша вперемешку с легитимной работой и вернул всё разом). Non-pop/apply
# stash-подкоманды (show/list/drop/...) короткозамыкаются на "безопасно" — функция
# только решает судьбу pop/apply. При неопределённости (не распарсили, не смогли
# посмотреть содержимое) — тоже "небезопасно", как reset_is_non_destructive.
stash_pop_apply_is_safe() {
  local segment="$1" repo="${CWD:-$PWD}" ref=""
  set -- $segment
  [ "${1:-}" = "git" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="${2:-}"; shift 2 ;;
      --git-dir|--work-tree|-c) shift 2 ;;
      --git-dir=*|--work-tree=*|-c*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "stash" ] || return 0
  shift
  case "${1:-}" in
    pop|apply) shift ;;
    *) return 0 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --index|--quiet|-q) shift ;;
      --) shift; [ $# -eq 1 ] || return 1; ref="$1"; break ;;
      -*) return 1 ;;
      *) [ -z "$ref" ] || return 1; ref="$1" ;;
    esac
    shift
  done
  [ -n "$ref" ] || ref="stash@{0}"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local status
  status=$(git -C "$repo" stash show --name-status -- "$ref" 2>/dev/null) || return 1
  ! echo "$status" | grep -qE '^D[[:space:]]'
}

# Same one-line-per-invocation reasoning as the reset check above — each
# chained `git stash ...` gets its own token-position parse.
STASH_SEGMENT=$(git_segment stash)
if [ -n "$STASH_SEGMENT" ]; then
  while IFS= read -r one_stash; do
    [ -n "$one_stash" ] || continue
    if ! stash_pop_apply_is_safe "$one_stash"; then
      block "git stash pop/apply запрещён: заначка содержит удаления файлов (или их не удалось проверить). Слепой возврат может стереть уже закоммиченные/задеплоенные артефакты (прецедент WP-547, 03.09). Сначала 'git stash show --name-status <ref>' и разбери каждое удаление вручную; разовая необходимость — CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
    fi
  done <<< "$STASH_SEGMENT"
fi

# rm с одновременным recursive (-r/-R/--recursive) и force (-f/--force), в любом
# сочетании флагов (слитных или раздельных) — вне временных/scratch-путей, где это
# штатная уборка (пир-сессия с Codex, WP-544 Ф1, 20.08).
if echo "$CMD" | grep -qE '(^|[[:space:]])rm([[:space:]]|$)' \
  && echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*[rR][^[:space:]]*|--recursive)([[:space:]]|$)' \
  && echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*f[^[:space:]]*|--force)([[:space:]]|$)' \
  && ! echo "$CMD" | grep -qE '(/tmp/|/scratchpad/|\.claude/worktrees/)'; then
  block "rm -r -f (в любом сочетании флагов) вне /tmp, scratchpad или worktree запрещён — удаление необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DROP/TRUNCATE — необратимая потеря структуры/данных.
if echo "$CMD" | grep -qiE '\bpsql\b' && echo "$CMD" | grep -qiE '\b(DROP[[:space:]]+(TABLE|SCHEMA|DATABASE)|TRUNCATE)\b'; then
  block "DROP/TRUNCATE через psql запрещён — необратимая потеря данных. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DELETE FROM без WHERE в том же операторе (эвристика: сегмент до ближайшего
# ';' или конца строки — не защищает от WHERE в другом statement той же команды).
if echo "$CMD" | grep -qiE '\bpsql\b' \
  && echo "$CMD" | grep -qiE 'DELETE[[:space:]]+FROM' \
  && ! echo "$CMD" | grep -qiE 'DELETE[[:space:]]+FROM[^;]*[[:space:]]WHERE([[:space:]]|$)'; then
  block "DELETE FROM без WHERE через psql запрещён — удалит всю таблицу. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# удаление репозитория на GitHub — необратимо.
if echo "$CMD" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
  block "gh repo delete запрещён — необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# gh repo deploy-key add с правом записи (-w/--allow-write) — расширяет ACL
# репозитория на внешнем сервисе без второго слоя проверки (WP-544, пир-сессия
# 2026-09-04-16-wp544-permission-type-auto-approve, Claude + Kimi). По умолчанию
# (без флага) ключ read-only — эта ветка не трогает `gh repo deploy-key add`
# без -w/--allow-write, тот случай остаётся обычным interactive-approve.
# Тот же residual, что у push --delete выше: whole-command grep, не
# git_segment-изолированный per-invocation — variable-obfuscation не ловит.
if echo "$CMD" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+deploy-key[[:space:]]+add\b' \
  && echo "$CMD" | grep -qE -- '(^|[[:space:]"'"'"'])(-w|--allow-write)([[:space:]"'"'"'=]|$)'; then
  block "gh repo deploy-key add с -w/--allow-write запрещён — добавляет ключ с правом записи в репозиторий (необратимое расширение доступа). Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# iwe-commit-isolated.sh обязан быть единственной командой в Bash-вызове.
# Разрешающее правило в settings.json матчит по префиксу пути к этому скрипту
# с завершающим `:*` — без такого хвоста правило не переиспользуешь (разные
# WP, разные пути worktree на каждый вызов), но с ним оно так же охотно
# матчит и `&& что-угодно-ещё`, потому что permission-matcher — текстовый
# префикс, не парсер shell-грамматики (WP-544, пир-сессия
# 2026-09-04-16-wp544-permission-type-auto-approve, Claude + Kimi; тот же
# класс ограничения, ради которого выше существует git_segment()). Проверка
# ниже — тот же посегментный сплиттер, что использует git_segment() (текст
# между `;&|(){}`/backtick вне кавычек — отдельный сегмент), но самостоятельная
# копия, не общий рефакторинг: git_segment() уже несёт несколько проверок
# (push/reset/clean/add/stash) и трогать её ради одного нового вызова —
# больше риска регресса, чем пользы от устранения дублирования.
ISOLATED_COMMIT_ANALYSIS=$(CMD_SCAN="$CMD" perl -e '
  my $text = $ENV{"CMD_SCAN"};
  my (@segments, $segment, $quote) = ((), q{}, undef);
  for (my $i = 0; $i < length($text); $i++) {
    my $char = substr($text, $i, 1);
    if (defined $quote) {
      $segment .= $char;
      if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
        $segment .= substr($text, ++$i, 1);
      } elsif ($char eq $quote) {
        undef $quote;
      }
    } elsif ($char eq q{"} || $char eq chr(39)) {
      $quote = $char;
      $segment .= $char;
    } elsif ($char eq q{&} && length($segment) && substr($segment, -1, 1) eq q{>}) {
      # `>&` fd-dup (`2>&1`, `>&2`, ...) — part of a redirect on the CURRENT
      # command, not a separator. Found live during code review (WP-544,
      # 2026-09-04): without this guard, any single command ending in
      # `2>&1` — including ones that merely mention the wrapper filename
      # in an unrelated argument (`cat .../iwe-commit-isolated.sh 2>&1`) —
      # was mis-split into two segments and falsely blocked.
      $segment .= $char;
    } elsif ($char eq q{&} && $i + 1 < length($text) && substr($text, $i + 1, 1) eq q{>}) {
      # `&>` (redirect both stdout+stderr) — same reasoning, other order.
      $segment .= $char;
    } elsif ($char =~ /[;&|(){}]/ || $char eq q{`}) {
      push @segments, $segment;
      $segment = q{};
    } else {
      $segment .= $char;
    }
  }
  push @segments, $segment;
  my @nonempty = grep { /\S/ } @segments;
  my $total = scalar @nonempty;
  my $wrapper_hits = grep { /iwe-commit-isolated\.sh/ } @nonempty;
  print "$total $wrapper_hits\n";
')
ISOLATED_COMMIT_TOTAL_SEGMENTS=$(echo "$ISOLATED_COMMIT_ANALYSIS" | awk '{print $1}')
ISOLATED_COMMIT_WRAPPER_HITS=$(echo "$ISOLATED_COMMIT_ANALYSIS" | awk '{print $2}')
if [ "${ISOLATED_COMMIT_WRAPPER_HITS:-0}" -gt 0 ] && [ "${ISOLATED_COMMIT_TOTAL_SEGMENTS:-0}" -gt 1 ]; then
  block "iwe-commit-isolated.sh обязан быть единственной командой в вызове — обнаружены другие сегменты той же compound-команды (после ; & | или в скобках/backtick). Раздели на отдельные Bash-вызовы."
fi

exit 0
