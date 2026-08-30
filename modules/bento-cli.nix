# `bento` — the command a bento machine uses to rewrite itself.
#
# Phase 2's deliverable. The whole premise of this OS is that changing it means editing
# a flake and applying it *in place*, not rebuilding a disk image, so the three verbs
# that loop belongs to are part of the OS rather than a shell alias someone has to
# remember: `bento rebuild`, `bento update`, `bento gc`.
#
# It is deliberately thin. Everything it does could be typed out by hand; what it buys
# is that the flake path, the configuration name and the untracked-files trap (below)
# are decided once, here, instead of in every command an agent constructs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.bento.cli;

  # Absolute paths for anything that runs under sudo — sudo need not preserve PATH, and a
  # `command not found` in the middle of a garbage collection is a bad way to find out.
  # `config.nix.package`, not `pkgs.nix`, so the CLI always drives the same Nix the system
  # is configured with.
  nix = config.nix.package;

  bento = pkgs.writeShellApplication {
    name = "bento";

    # `nixos-rebuild` is deliberately absent: it comes from the system profile, and
    # nixos-rebuild-ng re-execs itself out of the target flake anyway, so pinning a copy
    # here would only be a copy that gets ignored.
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      # `bento doctor` only. systemd for failed units, util-linux for uptime, and the
      # rest of coreutils for df/stat — all of them present on any NixOS anyway, but
      # writeShellApplication runs shellcheck against a PATH built from exactly this list.
      pkgs.systemd
      pkgs.util-linux
      nix
    ];

    text = ''
      usage() {
        cat <<'EOF'
      bento — apply this machine's own NixOS configuration.

        bento rebuild [ACTION] [-- ARGS...]
            Build ${cfg.configuration} from the flake and make it the running system.
            ACTION defaults to `switch`; `boot`, `test`, `dry-activate` and `build` are
            the other useful ones. Anything after `--` is passed to nixos-rebuild.

        bento update [INPUT...]
            Update flake.lock — every input, or only the ones named. Applies nothing;
            follow it with `bento rebuild`.

        bento gc [--older-than PERIOD | --all]
            Drop old generations and sweep the store. PERIOD defaults to 30d.
            `--all` keeps only the running generation — on this VM that also throws
            away every entry you could boot back to, so prefer a period.

        bento doctor
            What this machine is running, and whether anything is wrong with it:
            flake revision against the running system, last rebuild, failed units,
            disk. Cheap context to hand an agent before it changes anything.

        bento help

      Environment:
        BENTO_FLAKE    where the flake lives            (default: $HOME/bento)
        BENTO_CONFIG   nixosConfigurations attribute    (default: ${cfg.configuration})
      EOF
      }

      CONFIG="''${BENTO_CONFIG:-${cfg.configuration}}"
      FLAKE_DIR=""

      # Sets FLAKE_DIR. Not a `$(...)` helper on purpose: a failed lookup has to be able to
      # exit the script, and an exit inside a command substitution only kills the subshell.
      resolve_flake() {
        FLAKE_DIR="''${BENTO_FLAKE:-$HOME/bento}"
        if [ ! -e "$FLAKE_DIR/flake.nix" ]; then
          echo "bento: no flake.nix under $FLAKE_DIR" >&2
          echo "       clone the bento repo there, or point BENTO_FLAKE at it" >&2
          exit 1
        fi
      }

      # A flake only ever sees files git is tracking, so a freshly created module is
      # silently invisible to the rebuild that is supposed to apply it — the failure looks
      # like "my change did nothing", which is far more expensive to debug than it is to
      # prevent. `git add -N` records the path without staging content, and is undone with
      # `git rm --cached`.
      stage_untracked() {
        git -C "$FLAKE_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0

        local untracked=()
        mapfile -t untracked < <(git -C "$FLAKE_DIR" ls-files --others --exclude-standard)
        [ ''${#untracked[@]} -gt 0 ] || return 0

        echo "bento: these files are untracked, and a flake cannot see untracked files:" >&2
        printf '         %s\n' "''${untracked[@]}" >&2
        git -C "$FLAKE_DIR" add --intent-to-add -- "''${untracked[@]}"
        echo "bento: recorded them with 'git add -N' so this rebuild picks them up." >&2
        echo >&2
      }

      cmd_rebuild() {
        resolve_flake

        local action="switch"
        if [ $# -gt 0 ] && [ "''${1#-}" = "$1" ]; then
          action="$1"
          shift
        fi
        if [ "''${1:-}" = "--" ]; then shift; fi

        stage_untracked

        echo "bento: nixos-rebuild $action --flake $FLAKE_DIR#$CONFIG" >&2
        # `--sudo` (nixos-rebuild-ng's --elevate=sudo), not `sudo nixos-rebuild`: the build
        # and the flake evaluation stay as the invoking user, and only activation is
        # elevated. wheel has passwordless sudo here, so it never prompts.
        nixos-rebuild "$action" --sudo --flake "$FLAKE_DIR#$CONFIG" "$@"

        case "$action" in
          switch | boot | test)
            echo >&2
            nixos-rebuild list-generations 2>/dev/null | head -3 >&2 || true
            ;;
          *) ;;
        esac
      }

      cmd_update() {
        resolve_flake
        ( cd "$FLAKE_DIR" && ${nix}/bin/nix flake update "$@" )
        echo >&2
        echo "bento: flake.lock updated — apply it with 'bento rebuild'" >&2
      }

      cmd_gc() {
        local period="30d"
        local all=0

        while [ $# -gt 0 ]; do
          case "$1" in
            --older-than)
              period="''${2:?--older-than needs a period, e.g. 7d}"
              shift 2
              ;;
            --all) all=1; shift ;;
            *)
              echo "bento gc: unknown argument: $1" >&2
              exit 2
              ;;
          esac
        done

        local -a delete
        if [ "$all" -eq 1 ]; then
          delete=(--delete-old)
        else
          delete=(--delete-older-than "$period")
        fi

        # User profiles first, then the system profile: the root sweep is the one that
        # actually frees store paths, so it should run once everything is unreferenced.
        ${nix}/bin/nix-collect-garbage "''${delete[@]}"
        sudo ${nix}/bin/nix-collect-garbage "''${delete[@]}"

        # Generations just deleted are still in the boot menu until the loader is rewritten,
        # and this machine boots off the removable-media fallback with no NVRAM to correct a
        # stale entry from (learned/phase-1.md §4).
        echo >&2
        echo "bento: rewriting boot entries to match what survived" >&2
        sudo /run/current-system/bin/switch-to-configuration boot

        echo >&2
        df -h /
      }

      # `bento doctor` — PLAN-v1 §5 step 4's "prints flake status, last rebuild, disk
      # space — cheap context for the agent".
      #
      # It lives here rather than in modules/agent.nix, where the plan puts it, because it
      # is a verb of `bento` and this file owns the subcommand dispatch
      # (learned/phase-2.md §6 named this as the seam). A separate `bento-doctor` binary
      # would give the machine two CLIs that both answer questions about it.
      #
      # Everything printed is read, never computed: the point is to be safe to run at any
      # moment, including as the first thing an agent does. It changes nothing, and it is
      # deliberately not `set -e`-fragile — a machine with something wrong with it is
      # exactly when this has to still produce output.
      cmd_doctor() {
        local flake_dir="''${BENTO_FLAKE:-$HOME/bento}"
        local field="%-15s %s\n"

        echo "── this machine ──────────────────────────────────────────────"
        printf "$field" "host" "$(uname -n) ($(uname -m), $(uname -r))"
        printf "$field" "nixos" "$(nixos-version 2>/dev/null || echo unknown)"

        # The commit the *running* system was built from — flake.nix stamps it into
        # `system.configurationRevision` (learned/phase-2.md §7). Compared against the
        # flake's HEAD below, this is the answer to "is what I am reading what I am
        # running?", which is the first question after anything breaks here.
        local running_rev
        running_rev="$(nixos-version --configuration-revision 2>/dev/null || true)"
        printf "$field" "built from" "''${running_rev:-unknown}"

        local generation
        generation="$(readlink /nix/var/nix/profiles/system 2>/dev/null || true)"
        generation="''${generation#system-}"
        generation="''${generation%-link}"
        printf "$field" "generation" "''${generation:-unknown}"

        # `stat` does not dereference by default, so this is the symlink's own mtime —
        # when switch-to-configuration last pointed it somewhere. The store path behind it
        # would report the epoch, since Nix normalises timestamps.
        printf "$field" "activated" "$(stat -c %y /run/current-system 2>/dev/null | cut -d. -f1 || true)"
        echo

        echo "── the flake ─────────────────────────────────────────────────"
        printf "$field" "path" "$flake_dir"
        printf "$field" "configuration" "$CONFIG"

        if [ ! -e "$flake_dir/flake.nix" ]; then
          printf "$field" "state" "MISSING — no flake.nix here, 'bento rebuild' cannot run"
        elif ! git -C "$flake_dir" rev-parse --git-dir >/dev/null 2>&1; then
          printf "$field" "state" "not a git repository — Nix will see only the working tree"
        else
          local head dirty
          head="$(git -C "$flake_dir" rev-parse HEAD 2>/dev/null || true)"
          dirty="$(git -C "$flake_dir" status --porcelain 2>/dev/null || true)"

          printf "$field" "HEAD" "$head $(git -C "$flake_dir" log -1 --format=%s 2>/dev/null || true)"

          if [ -z "$dirty" ]; then
            printf "$field" "working tree" "clean"
          else
            printf "$field" "working tree" "dirty"
            printf '                %s\n' "$dirty"
          fi

          # A flake only ever sees what git tracks, so an untracked file is invisible to
          # the rebuild that is supposed to apply it — silently, if nothing imports it yet
          # (learned/phase-2.md §3). `bento rebuild` stages these for you; `doctor` says so
          # before you wonder why an edit did nothing.
          local untracked
          untracked="$(git -C "$flake_dir" ls-files --others --exclude-standard 2>/dev/null || true)"
          if [ -n "$untracked" ]; then
            printf "$field" "untracked" "invisible to Nix until added:"
            printf '                %s\n' "$untracked"
          fi

          if [ -n "$head" ] && [ "$head" = "$running_rev" ] && [ -z "$dirty" ]; then
            printf "$field" "in sync" "yes — the running system is this commit"
          else
            printf "$field" "in sync" "no — 'bento rebuild' would change this machine"
          fi
        fi
        echo

        echo "── health ────────────────────────────────────────────────────"
        local failed
        failed="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | cut -d' ' -f1 || true)"
        printf "$field" "failed units" "''${failed:-none}"

        # The user bus carries most of this desktop — waybar, walker, elephant, mako,
        # swaybg, hypridle — and none of them is a system unit, so a system-only check
        # reports a healthy machine with no bar on it (learned/phase-4.md §7).
        local failed_user
        failed_user="$(systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null | cut -d' ' -f1 || true)"
        printf "$field" "failed (user)" "''${failed_user:-none}"

        printf "$field" "disk" "$(df -h --output=used,avail,pcent / 2>/dev/null | tail -1 | tr -s ' ' || true) used/avail on /"
      }

      case "''${1:-help}" in
        rebuild) shift; cmd_rebuild "$@" ;;
        update)  shift; cmd_update "$@" ;;
        gc)      shift; cmd_gc "$@" ;;
        doctor)  shift; cmd_doctor "$@" ;;
        help | -h | --help) usage ;;
        *)
          echo "bento: unknown subcommand: $1" >&2
          echo >&2
          usage >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.bento.cli = {
    configuration = lib.mkOption {
      type = lib.types.str;
      default = "bento-vm";
      description = ''
        Which `nixosConfigurations.<name>` in the flake describes this machine. It is not
        derivable from {option}`networking.hostName` — the hostname is `bento` on every
        bento machine, while the configuration name identifies the *host* (`bento-vm`
        today, something else on bare metal).
      '';
    };
  };

  config.environment.systemPackages = [ bento ];
}
