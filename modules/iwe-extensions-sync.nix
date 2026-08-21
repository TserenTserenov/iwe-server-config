# SPDX-License-Identifier: Apache-2.0
#
# modules/iwe-extensions-sync.nix — копирование IWE extensions/scripts/skills/memory
# на сервер при каждом nixos-rebuild.
#
# Контекст: ~/IWE/.claude/, ~/IWE/extensions/, ~/IWE/scripts/ на Mac хранятся
# как локальные файлы (не в git как отдельный repo). Чтобы tsekh-1 мог запускать
# полный Day Open / extractor / scout — эти файлы должны быть на сервере.
#
# Решение: положить файлы в `server-extensions/` этого репо, при nixos-rebuild
# они копируются в ~/IWE и ~/.claude. Источник истины — Mac пользователя,
# обновление через `bash scripts/sync-extensions.sh` + git push (см. README).
#
# Связь: WP-138 follow-up (29 апр), системное решение тех-долга после ручного rsync.

{ config, lib, pkgs, ... }:

let
  cfg = config.tsekh.extensions;
  src = ../server-extensions;
in
{
  options.tsekh.extensions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Включить синхронизацию IWE extensions/scripts/skills/memory.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "tseren";
      description = "Пользователь-владелец синхронизируемых файлов.";
    };
  };

  config = lib.mkIf cfg.enable {
    # systemd-tmpfiles создаёт нужные директории до activation
    systemd.tmpfiles.rules = [
      "d /home/${cfg.user}/IWE/.claude 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/.claude/skills 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/.claude/hooks 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/.claude/scripts 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/.claude/lib 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/extensions 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/IWE/scripts 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/.claude/projects/-home-${cfg.user}-IWE/memory 0755 ${cfg.user} users -"
    ];

    # Activation script: копирование файлов из nix store в /home/tseren/IWE
    # rsync с --delete: removed-files тоже удаляются (декларативное состояние).
    system.activationScripts.iweExtensionsSync = {
      deps = [ "users" "groups" ];
      text = ''
        echo "[iwe-ext-sync] копирую IWE extensions из nix store..."

        # Root-level CLAUDE.md (slim-ядро инструкций для агента)
        if [ -f ${src}/CLAUDE.md ]; then
          ${pkgs.coreutils}/bin/cp ${src}/CLAUDE.md /home/${cfg.user}/IWE/CLAUDE.md
        fi

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/scripts/ \
          /home/${cfg.user}/IWE/scripts/

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/extensions/ \
          /home/${cfg.user}/IWE/extensions/

        # Все скиллы целиком (был только day-open — audit-installation и др. отсутствовали)
        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/claude-skills/ \
          /home/${cfg.user}/IWE/.claude/skills/

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/claude-hooks/ \
          /home/${cfg.user}/IWE/.claude/hooks/

        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/claude-scripts/ \
          /home/${cfg.user}/IWE/.claude/scripts/

        # WP-7 Ф-Backup-Resilience-Audit (27.07): check-dirty-repos.sh source'ит эту
        # библиотеку — раньше .claude/lib/ вообще не входил в синхронизацию.
        ${pkgs.rsync}/bin/rsync -a --delete \
          ${src}/claude-lib/ \
          /home/${cfg.user}/IWE/.claude/lib/

        # Claude project-key на сервере кодирует Linux-путь (-home-...), не
        # macOS-путь источника (-Users-...) — эти два префикса разные строки,
        # не взаимозаменяемые синонимы одного и того же каталога. rsync сюда
        # с macOS-стилем префикса молча создавал parallel-каталог, который
        # ни один процесс на сервере не читает (WP-484 delivery-version-handshake,
        # peer-session 2026-08-21-01, root cause: protocol-open.md/protocol-close.md
        # отставали на server 26-32 дня без единого сигнала ошибки).
        ${pkgs.rsync}/bin/rsync -a \
          ${src}/memory/ \
          /home/${cfg.user}/.claude/projects/-home-${cfg.user}-IWE/memory/

        # Восстановить права (rsync из nix store даёт root, нужно tseren)
        chown ${cfg.user}:users /home/${cfg.user}/IWE/CLAUDE.md 2>/dev/null || true
        chown -R ${cfg.user}:users \
          /home/${cfg.user}/IWE/scripts \
          /home/${cfg.user}/IWE/extensions \
          /home/${cfg.user}/IWE/.claude \
          /home/${cfg.user}/.claude/projects/-home-${cfg.user}-IWE/memory

        # Скрипты должны быть executable
        find /home/${cfg.user}/IWE/scripts /home/${cfg.user}/IWE/.claude/scripts /home/${cfg.user}/IWE/.claude/hooks \
          -name "*.sh" -exec chmod +x {} \;

        echo "[iwe-ext-sync] sync done"
      '';
    };

    # Post-copy verification: сверяет каждый managed-файл манифеста с копией
    # в живом пути по SHA-256, и удаляет из живого пути managed-файлы,
    # выпавшие из манифеста (rsync выше — БЕЗ --delete намеренно, чтобы не
    # трогать runtime-контент вроде MEMORY.md, лежащий в том же каталоге;
    # точечное удаление здесь ограничено СТАРЫМ manifest'ом, известным этой
    # generation, — новый manifest уже отфильтровал managed-набор).
    #
    # ВАЖНО (найдено cold-context review, peer-session 2026-08-21-01):
    # NixOS activation-скрипты НЕ изолированы через `set -e` — все
    # activationScripts.* конкатенируются в один shell-скрипт, и голый
    # `exit N` внутри снипета обрывает ВСЕ последующие снипеты того же
    # rebuild (secrets, code-server и т.д.), не только этот. Поэтому вся
    # verify-логика — внутри подшелла `( ... )`; наружу выходит только
    # статус в переменной, никогда не process-level exit.
    system.activationScripts.iweExtensionsVerify = {
      deps = [ "iweExtensionsSync" ];
      text = ''
        MANIFEST=${src}/memory/managed-memory-manifest.txt
        LIVE_MEMORY=/home/${cfg.user}/.claude/projects/-home-${cfg.user}-IWE/memory
        RELEASE_JSON=/home/${cfg.user}/IWE/.iwe-runtime/iwe-release.json

        VERIFY_STATUS=$(
          set +e
          if [ ! -f "$MANIFEST" ]; then
            echo "[iwe-ext-verify] WARN: manifest отсутствует ($MANIFEST) — classify-memory.py не запускался, пропускаю проверку" >&2
            echo "no-manifest"
            exit 0
          fi
          # sha256sum -c ищет имя файла из manifest.sha256 (относительное,
          # только "managed-memory-manifest.txt") относительно ТЕКУЩЕГО cwd
          # процесса, не относительно расположения самого .sha256-файла —
          # activation-скрипты NixOS запускаются из непредсказуемого cwd
          # (обычно /), поэтому нужен явный cd в подшелле. Найдено живым
          # тестом на синтетических фикстурах при верификации этого фикса
          # (peer-session 2026-08-21-01), не догадкой по чтению кода.
          if ! (cd ${src}/memory && ${pkgs.coreutils}/bin/sha256sum -c manifest.sha256 --status 2>/dev/null); then
            echo "[iwe-ext-verify] FATAL: manifest.sha256 не совпадает — manifest повреждён или оборван при доставке" >&2
            echo "fatal"
            exit 0
          fi
          FAILED=0
          while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            SRC_FILE="${src}/memory/$rel_path"
            LIVE_FILE="$LIVE_MEMORY/$rel_path"
            if [ ! -f "$LIVE_FILE" ]; then
              echo "[iwe-ext-verify] FATAL: managed-файл отсутствует в живом пути: $LIVE_FILE" >&2
              FAILED=1
              continue
            fi
            SRC_SHA=$(${pkgs.coreutils}/bin/sha256sum "$SRC_FILE" | cut -d' ' -f1)
            LIVE_SHA=$(${pkgs.coreutils}/bin/sha256sum "$LIVE_FILE" | cut -d' ' -f1)
            if [ "$SRC_SHA" != "$LIVE_SHA" ]; then
              echo "[iwe-ext-verify] FATAL: hash mismatch $rel_path (src=$SRC_SHA live=$LIVE_SHA)" >&2
              FAILED=1
            fi
          done < "$MANIFEST"
          # Точечная уборка: managed-файл в живом пути, которого больше нет
          # в текущем манифесте — удалить (не трогаем ничего не из манифеста,
          # runtime-контент типа MEMORY.md в том же каталоге не задет).
          if [ -d "$LIVE_MEMORY" ]; then
            for live_file in "$LIVE_MEMORY"/*.md; do
              [ -e "$live_file" ] || continue
              rel_name=$(${pkgs.coreutils}/bin/basename "$live_file")
              ${pkgs.gnugrep}/bin/grep -qxF "$rel_name" "$MANIFEST" && continue
              ${pkgs.gnugrep}/bin/grep -qxF "$rel_name" /home/${cfg.user}/IWE/.iwe-runtime/last-managed-manifest.txt 2>/dev/null || continue
              echo "[iwe-ext-verify] удаляю managed-файл, выпавший из манифеста: $rel_name" >&2
              rm -f "$live_file"
            done
          fi
          ${pkgs.coreutils}/bin/cp "$MANIFEST" /home/${cfg.user}/IWE/.iwe-runtime/last-managed-manifest.txt 2>/dev/null || true
          if [ "$FAILED" -ne 0 ]; then
            echo "[iwe-ext-verify] доставка managed-memory провалена — см. FATAL выше" >&2
            echo "fatal"
            exit 0
          fi
          echo "[iwe-ext-verify] managed-memory manifest verified: $(${pkgs.coreutils}/bin/wc -l < "$MANIFEST" | tr -d ' ') файлов OK"
          echo "ok"
        )
        VERIFY_STATUS=$(echo "$VERIFY_STATUS" | tail -1)

        # iwe-release.json — короткая квитанция доставки для version-handshake
        # (WP-484, Шаг 3 пилота): session-guard.sh/process-runner.py читают этот
        # файл при open/close, печатают release=<sha12> checkout=... runtime=...
        # memory=... — Day Open сверяет с origin/main. Один атомарный write
        # (mv поверх), не частично видимый файл при конкурентном чтении.
        # memory-статус здесь — единственная честная связь с VERIFY_STATUS выше
        # (см. Critical-находку review): rebuild НЕ падает на верификации, но
        # статус доезжает до Day Open через этот файл — тем же путём, каким
        # его и было решено доставлять (version-handshake, не process exit).
        ${pkgs.coreutils}/bin/mkdir -p /home/${cfg.user}/IWE/.iwe-runtime
        TMP_RELEASE=$(${pkgs.coreutils}/bin/mktemp)
        ${pkgs.coreutils}/bin/cat > "$TMP_RELEASE" <<EOF
        {
          "root_commit": "$(${pkgs.coreutils}/bin/cat ${src}/ROOT_COMMIT_SHA 2>/dev/null || echo unknown)",
          "config_revision": "${config.system.configurationRevision or "unknown"}",
          "deployed_at": "$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)",
          "runtime_scripts_sha": "$(${pkgs.findutils}/bin/find /home/${cfg.user}/IWE/scripts -type f -exec ${pkgs.coreutils}/bin/sha256sum {} \; 2>/dev/null | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/sha256sum | cut -d' ' -f1)",
          "managed_manifest_sha": "$([ -f ${src}/memory/manifest.sha256 ] && ${pkgs.coreutils}/bin/cut -d' ' -f1 ${src}/memory/manifest.sha256 || echo unknown)",
          "memory_verify_status": "$VERIFY_STATUS"
        }
        EOF
        ${pkgs.coreutils}/bin/mv "$TMP_RELEASE" "$RELEASE_JSON"
        ${pkgs.coreutils}/bin/chown ${cfg.user}:users "$RELEASE_JSON"
        echo "[iwe-ext-verify] iwe-release.json written (memory_verify_status=$VERIFY_STATUS)"
      '';
    };
  };
}
