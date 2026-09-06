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

  # How Claude Code's release manifest names a build for this machine. Derived from the
  # same stdenv attributes nixpkgs' own claude-code derivation uses to index `.platforms`,
  # so `bento update claude-code` validates against the entry the build will actually read.
  platformKey = "${pkgs.stdenv.hostPlatform.node.platform}-${pkgs.stdenv.hostPlatform.node.arch}";

  bento = pkgs.writeShellApplication {
    name = "bento";

    # `nixos-rebuild` is deliberately absent: it comes from the system profile, and
    # nixos-rebuild-ng re-execs itself out of the target flake anyway, so pinning a copy
    # here would only be a copy that gets ignored.
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      # `bento doctor`'s `systemctl list-units --state=failed`. Present on any NixOS
      # anyway, but writeShellApplication builds the script's PATH from exactly this
      # list, so anything not named here is only found by falling through to the
      # caller's PATH — which is fine for `nixos-rebuild` and `nixos-version` (they come
      # from the system profile by design) and not fine for a dependency.
      pkgs.systemd
      # `bento update`'s pinned-package half (modules/pins.nix) and `bento doctor`'s
      # report of it: curl fetches a release manifest, jq reads and validates it.
      pkgs.curl
      pkgs.jq
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

        bento update [NAME...]
            Bring this machine's sources up to date. With no argument: every flake
            input, then every pinned package. With arguments: only those, where a NAME
            is either a flake input (`nixpkgs`) or a pin under pkgs/ (`claude-code`).
            Applies nothing; follow it with `bento rebuild`.

            A pin may be given an explicit version: `bento update claude-code@2.1.245`.

        bento gc [--older-than PERIOD | --all]
            Drop old generations and sweep the store. PERIOD defaults to 30d.
            `--all` keeps only the running generation — on this VM that also throws
            away every entry you could boot back to, so prefer a period.

        bento doctor
            What this machine is running, and whether anything is wrong with it:
            flake revision against the running system, last rebuild, pinned package
            versions, failed units, disk. Reads only, never asks the network — cheap
            context to hand an agent before it changes anything.

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

      # ── pinned packages ─────────────────────────────────────────────────────────────
      #
      # A few tools move faster than nixpkgs follows, so this repo carries their version
      # itself as pkgs/<name>/manifest.json and overrides nixpkgs' derivation with it —
      # see modules/pins.nix for why that is a supported seam rather than a fork.
      #
      # `bento update` owns refreshing those manifests for the same reason it owns
      # flake.lock: from where you sit, "update my machine's sources" is one intention,
      # and having to remember that one source is a flake input and another is a JSON
      # file under pkgs/ is exactly the kind of detail this CLI exists to absorb.

      # A NAME is a pin if pkgs/NAME/manifest.json exists; anything else is a flake input.
      is_pin() {
        [ -e "$FLAKE_DIR/pkgs/$1/manifest.json" ]
      }

      # Every pin this repo carries, in directory order.
      list_pins() {
        local d
        for d in "$FLAKE_DIR"/pkgs/*/; do
          [ -e "$d/manifest.json" ] || continue
          d="''${d%/}"
          printf '%s\n' "''${d##*/}"
        done
      }

      # Rewrite pkgs/claude-code/manifest.json from Anthropic's release channel.
      #
      # The whole update procedure is two unauthenticated GETs — `.../latest` names the
      # current version, and a per-version manifest carries a SHA-256 for every platform.
      # nixpkgs' own maintainer script does precisely this; we run it against this repo
      # instead of against a nixpkgs checkout.
      #
      # **Upstream publishes two manifests, and which one is correct depends on the
      # nixpkgs you are locked to.** Anthropic now ships the binary zstd-compressed:
      # `manifest.zst.json` describes `claude.zst`, `manifest.json` the uncompressed
      # `claude`, and the checksums are of different bytes. nixpkgs' derivation switched
      # to the compressed one — it defaults to `./manifest.zst.json`, takes the filename
      # from `.platforms.<key>.binary`, and runs `unzstd` in its install phase.
      #
      # We found this the way the design intends: pinning the uncompressed manifest
      # against the newer derivation failed the build with
      #
      #   zstd: /nix/store/...-claude: unsupported format
      #
      # rather than silently installing something wrong. Worth keeping in mind when the
      # next `bento update nixpkgs` moves this derivation again.
      #
      # The file we write stays `manifest.json` regardless of what upstream calls it:
      # that name is *bento's* pin convention, the one `is_pin`, `list_pins` and
      # `bento doctor` all walk, and it should not churn every time a vendor renames a
      # file. Which upstream manifest fills it is this function's business alone.
      update_pin_claude_code() {
        local base="https://downloads.claude.ai/claude-code-releases"
        local remote="manifest.zst.json"
        local file="$FLAKE_DIR/pkgs/claude-code/manifest.json"
        local want="''${1:-}" have="" tmp

        mkdir -p "$(dirname "$file")"
        have="$(jq -r '.version // ""' "$file" 2>/dev/null || true)"
        [ -n "$want" ] || want="$(curl -fsSL "$base/latest")"

        if [ "$want" = "$have" ]; then
          echo "bento: claude-code already pinned at $have" >&2
          return 0
        fi

        # Into a temporary file first: a manifest half-written by an interrupted download
        # would still be valid input to `lib.importJSON` right up until it wasn't, and the
        # failure would surface as a rebuild error rather than as a failed update.
        #
        # Cleaned up explicitly on every path rather than through `trap ... RETURN`, which
        # looks tidier and does not work: bash runs the RETURN trap after the function's
        # locals have gone out of scope, so `rm -f "$tmp"` fires `unbound variable` under
        # `set -u` — after a *successful* update, which is the worst time to print an
        # error.
        tmp="$(mktemp)"
        if ! curl -fsSL "$base/$want/$remote" -o "$tmp"; then
          rm -f "$tmp"
          echo "bento: no release manifest for claude-code $want" >&2
          return 1
        fi

        # Two things worth checking before this becomes part of the build: that it parses,
        # and that it describes the release we asked for. The second is not paranoia — a
        # typo'd version in `bento update claude-code@...` otherwise pins whatever the CDN
        # served for it.
        if ! jq -e --arg v "$want" '.version == $v' "$tmp" >/dev/null 2>&1; then
          rm -f "$tmp"
          echo "bento: $base/$want/$remote is not a manifest for $want" >&2
          return 1
        fi
        # This machine's platform has to actually be in it, or the next rebuild fails on a
        # missing attribute deep inside the derivation instead of here. The key is the one
        # nixpkgs' own derivation indexes `.platforms` by, interpolated from the same
        # stdenv, so a bento built for anything else checks for its own build. `binary` is
        # checked alongside `checksum` because the derivation builds its download URL from
        # it — an entry missing it fails at fetch time with a 404 and no explanation.
        if ! jq -e '.platforms["${platformKey}"] | .checksum and .binary' "$tmp" >/dev/null 2>&1; then
          rm -f "$tmp"
          echo "bento: manifest for $want carries no usable ${platformKey} build" >&2
          return 1
        fi

        cp "$tmp" "$file"
        rm -f "$tmp"
        echo "bento: claude-code ''${have:-none} → $want" >&2
      }

      # Dispatch for the above. Per-package rather than generic on purpose: see the
      # closing paragraph of modules/pins.nix.
      update_pin() {
        local name="$1"
        case "$name" in
          claude-code) shift; update_pin_claude_code "$@" ;;
          *)
            echo "bento update: '$name' is pinned but has no updater in bento-cli.nix" >&2
            return 2
            ;;
        esac
      }

      cmd_update() {
        resolve_flake

        local -a inputs=() pins=() pin_versions=()
        local touch_lock=0

        if [ $# -eq 0 ]; then
          # No argument means everything: all flake inputs, and every pin.
          touch_lock=1
          mapfile -t pins < <(list_pins)
          pin_versions=()
        else
          local arg name version
          for arg in "$@"; do
            # `name@version` pins an explicit release; a bare name takes the latest.
            name="''${arg%%@*}"
            version=""
            if [ "$arg" != "$name" ]; then version="''${arg#*@}"; fi

            if is_pin "$name"; then
              pins+=("$name")
              pin_versions+=("$version")
            elif [ -n "$version" ]; then
              echo "bento update: '@version' only applies to pinned packages, and" >&2
              echo "               there is no pkgs/$name/manifest.json" >&2
              exit 2
            else
              inputs+=("$arg")
            fi
          done
          if [ ''${#inputs[@]} -gt 0 ]; then touch_lock=1; fi
        fi

        local i
        for i in "''${!pins[@]}"; do
          update_pin "''${pins[i]}" "''${pin_versions[i]:-}"
        done

        # An empty `inputs` array makes this `nix flake update`, which updates every
        # input — which is what the no-argument case wants.
        if [ "$touch_lock" -eq 1 ]; then
          ( cd "$FLAKE_DIR" && ${nix}/bin/nix flake update "''${inputs[@]}" )
        fi

        echo >&2
        echo "bento: sources updated — apply them with 'bento rebuild'" >&2
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

        echo "── this machine ──────────────────────────────────────────────"
        printf '%-15s %s\n' "host" "$(uname -n) ($(uname -m), $(uname -r))"
        printf '%-15s %s\n' "nixos" "$(nixos-version 2>/dev/null || echo unknown)"

        # The commit the *running* system was built from — flake.nix stamps it into
        # `system.configurationRevision` (learned/phase-2.md §7). Compared against the
        # flake's HEAD below, this is the answer to "is what I am reading what I am
        # running?", which is the first question after anything breaks here.
        local running_rev
        running_rev="$(nixos-version --configuration-revision 2>/dev/null || true)"
        printf '%-15s %s\n' "built from" "''${running_rev:-unknown}"

        local generation
        generation="$(readlink /nix/var/nix/profiles/system 2>/dev/null || true)"
        generation="''${generation#system-}"
        generation="''${generation%-link}"
        printf '%-15s %s\n' "generation" "''${generation:-unknown}"

        # `stat` does not dereference by default, so this is the symlink's own mtime —
        # when switch-to-configuration last pointed it somewhere. The store path behind it
        # would report the epoch, since Nix normalises timestamps.
        printf '%-15s %s\n' "activated" "$(stat -c %y /run/current-system 2>/dev/null | cut -d. -f1 || true)"
        echo

        echo "── the flake ─────────────────────────────────────────────────"
        printf '%-15s %s\n' "path" "$flake_dir"
        printf '%-15s %s\n' "configuration" "$CONFIG"

        if [ ! -e "$flake_dir/flake.nix" ]; then
          printf '%-15s %s\n' "state" "MISSING — no flake.nix here, 'bento rebuild' cannot run"
        elif ! git -C "$flake_dir" rev-parse --git-dir >/dev/null 2>&1; then
          printf '%-15s %s\n' "state" "not a git repository — Nix will see only the working tree"
        else
          local head dirty
          head="$(git -C "$flake_dir" rev-parse HEAD 2>/dev/null || true)"
          dirty="$(git -C "$flake_dir" status --porcelain 2>/dev/null || true)"

          printf '%-15s %s\n' "HEAD" "$head $(git -C "$flake_dir" log -1 --format=%s 2>/dev/null || true)"

          if [ -z "$dirty" ]; then
            printf '%-15s %s\n' "working tree" "clean"
          else
            printf '%-15s %s\n' "working tree" "dirty"
            printf '                %s\n' "$dirty"
          fi

          # A flake only ever sees what git tracks, so an untracked file is invisible to
          # the rebuild that is supposed to apply it — silently, if nothing imports it yet
          # (learned/phase-2.md §3). `bento rebuild` stages these for you; `doctor` says so
          # before you wonder why an edit did nothing.
          local untracked
          untracked="$(git -C "$flake_dir" ls-files --others --exclude-standard 2>/dev/null || true)"
          if [ -n "$untracked" ]; then
            printf '%-15s %s\n' "untracked" "invisible to Nix until added:"
            printf '                %s\n' "$untracked"
          fi

          if [ -n "$head" ] && [ "$head" = "$running_rev" ] && [ -z "$dirty" ]; then
            printf '%-15s %s\n' "in sync" "yes — the running system is this commit"
          else
            printf '%-15s %s\n' "in sync" "no — 'bento rebuild' would change this machine"
          fi
        fi

        # Packages whose version this repo pins itself rather than taking from nixpkgs
        # (modules/pins.nix). Read off the manifests on disk, deliberately: `doctor` is
        # the first thing an agent runs and has to work on a machine with no network and
        # something already wrong with it, so it reports what is *pinned* and never asks
        # upstream what is current. `bento update` is the verb that talks to the network.
        local pin_dir pin_name pin_version
        for pin_dir in "$flake_dir"/pkgs/*/; do
          [ -e "$pin_dir/manifest.json" ] || continue
          pin_name="''${pin_dir%/}"
          pin_name="''${pin_name##*/}"
          pin_version="$(jq -r '.version // "unreadable"' "$pin_dir/manifest.json" 2>/dev/null || echo unreadable)"
          printf '%-15s %s\n' "pinned" "$pin_name $pin_version"
        done
        echo

        echo "── health ────────────────────────────────────────────────────"
        local failed
        failed="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | cut -d' ' -f1 || true)"
        printf '%-15s %s\n' "failed units" "''${failed:-none}"

        # The user bus carries most of this desktop — waybar, walker, elephant, mako,
        # swaybg, hypridle — and none of them is a system unit, so a system-only check
        # reports a healthy machine with no bar on it (learned/phase-4.md §7).
        local failed_user
        failed_user="$(systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null | cut -d' ' -f1 || true)"
        printf '%-15s %s\n' "failed (user)" "''${failed_user:-none}"

        printf '%-15s %s\n' "disk" "$(df -h --output=used,avail,pcent / 2>/dev/null | tail -1 | tr -s ' ' || true) used/avail on /"
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
