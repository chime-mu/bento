# What Phase 2 taught us

**Date:** 2026-08-30 · **Host:** Apple Silicon MacBook (M4), macOS 26.5.2 · **Guest:** NixOS
`26.11.20260828.83199d0`, Nix 2.34.8, kernel 6.18.47, `aarch64`
**Outcome:** ✅ Phase 2 complete — the VM rewrites itself from its own copy of the flake,
and commits move both ways between this repo and the guest's.

Findings log for Phase 2: the fast iteration loop. Everything here was measured inside the
running VM. Where it contradicts `PLAN-v1.md`, `learned/phase-1.md` or upstream
documentation, that is called out.

## Acceptance — verified

| Criterion | Result |
|---|---|
| Edit `modules/core.nix` in the VM, `bento rebuild`, package available | ✅ `tree` went from *not found* to `/run/current-system/sw/bin/tree` |
| …without re-imaging | ✅ `artifacts/bento.qcow2` was never rebuilt; the builder VM was never started |
| Revert the edit, rebuild | ✅ `tree` gone again — the loop is symmetric, not additive |
| `bento rebuild` / `update` / `gc` all work | ✅ each exercised, see §6 |
| `nix flake check` still green | ✅ exit 0, run natively inside the guest |

**The numbers that justify the phase:**

| Operation | Time |
|---|---|
| `bento rebuild` — no-op reapply | **1.3 s** |
| `bento rebuild` — add one cached package | **6.4 s** |
| `bento rebuild` — first switch onto a new flake revision | **9.3 s** |
| `./scripts/build-image.sh` — the clean loop | **~25 min** |

---

## 1. The premise held on the first try

`learned/HANDOFF.md` left a free probe lying around: the committed config set the git
identity to `chime@mu.dk`, but the image predated that commit and still carried
`ma@goodmonday.io`. One `nixos-rebuild switch --flake ~/bento#bento-vm` inside the VM
flipped it, in 9.3 seconds, having fetched 12 small paths from `cache.nixos.org`.

Nothing in Phase 1's structure had to be renegotiated to make this work. In particular
`hosts/bento-vm/hardware.nix` kept the disk layout it duplicates on purpose
(`learned/phase-1.md` §2) and the standalone evaluation found its root filesystem exactly
as predicted. **That duplication is now load-bearing in production, not just in theory —
it is what every rebuild from here on depends on.**

Confirmed in passing: `phase-1.md` §8's prediction that the image module's
`system.nixos.tags` would disappear at the first in-VM switch. Generation 1 still lists as
`efi-qcow2-26.11.20260828.83199d0`; every generation after it is plain
`26.11.20260828.83199d0`.

## 2. Two git repositories, not one 9p share — and 9p *was* available

`HANDOFF.md` asked Phase 2 to settle the transport question before committing to `scp`,
and explicitly floated a 9p/virtfs mount of the host repo as a third option that "would
avoid two diverging copies entirely".

**9p is genuinely available on this host, contrary to what one might assume from QEMU's
Linux-centric virtfs code.** Measured against Homebrew QEMU 11.1.1:

```
$ qemu-system-aarch64 -device help | grep 9p
name "virtio-9p-device", bus virtio-bus
name "virtio-9p-pci", bus PCI, alias "virtio-9p"
...
$ qemu-system-aarch64 -machine virt -fsdev local,id=probe,path=/tmp,security_model=none ...
(initialises and runs)
```

So it was a real choice, and it was **rejected**. Three reasons, in order of weight:

1. **It couples the guest's configuration to a macOS path.** The point of bento is a
   declarative machine that later moves to bare metal. A NixOS config that expects
   `/Users/chime/Workspace/Bento` to appear over a mount tag is exactly the coupling that
   has to be unpicked at that point.
2. **uid mapping has no good answer.** `security_model=none` passes host uids through
   unmapped: the repo arrives owned by uid 501, which is nobody in the guest, and anything
   the guest writes lands on the Mac owned by uid 1000. `mapped-xattr` fixes ownership by
   storing metadata in extended attributes, at the cost of making the files look strange
   from the macOS side — where they are also edited.
3. **Every rebuild would drag the tree across 9p** into the store, on a transport already
   known to be slow.

**The decision: two real git repositories, and history is what moves between them.**
`scripts/vm-sync.sh init | push | pull | status`.

### The direction is a choice, not a constraint — this was nearly recorded wrongly

The obvious rationale for driving both directions from the host is "the guest can't reach
the Mac". **That is false on this machine, and it was worth measuring before asserting.**
QEMU slirp maps the host to `10.0.2.2`, this Mac has Remote Login enabled, and an ssh from
the guest got all the way to authentication:

```
debug1: Connecting to 10.0.2.2 [10.0.2.2] port 22.
debug1: Remote protocol version 2.0, remote software version OpenSSH_10.2
debug1: Authenticating to 10.0.2.2:22 as 'chime'
chime@10.0.2.2: Permission denied (publickey,password,keyboard-interactive).
```

So guest→host git *would* work if the guest held a credential for the Mac account. It is
still not the design, for two reasons that survive the correction: it depends on Remote
Login, a system-wide macOS setting this repo should not require, and it means putting a
host credential inside a disposable VM. The 2222 forward needs neither.

> Generalised lesson, and the same one as `phase-0.md` §1: an unmeasured "X is impossible"
> in a findings log is worse than no note at all, because the next agent will build on it.

### Mechanics worth keeping

- **Seed with `git bundle`, never `tar`.** The first attempt piped `tar czf -` over ssh
  and produced **24 AppleDouble `._*` files** in the guest — `._flake.nix`, `._modules`,
  `._.git` and so on. macOS bsdtar serialises extended attributes as companion files, and
  every file in this repo carries `com.apple.provenance`. A bundle is one binary blob with
  the full history, unpacked by the guest's own git, and cannot express the problem.
- **`push` works into a checked-out branch** because `init` sets
  `receive.denyCurrentBranch = updateInstead` in the guest repo. The guest's working tree
  updates in place; if it is dirty, the push is **refused**, not merged.
- **`pull` is fast-forward only.** A divergence means the same OS definition was edited on
  both sides, and inventing a merge commit for that silently is not a favour.
- **The port belongs in the remote URL** (`ssh://chime@localhost:2222/home/chime/bento`),
  not only in `GIT_SSH_COMMAND`. The first version put it only in the latter, which works
  for the script and then sends a hand-typed `git push vm` to port 22 on the Mac.
- **Host keys are deliberately not pinned.** The guest regenerates its ssh host keys every
  time the image is rebuilt, so pinning would mean teaching the user to clear a
  `REMOTE HOST IDENTIFICATION HAS CHANGED` warning after each clean loop. Same posture
  Phase 0 accepted for the linux-builder's publicly-known key, and for the same reason: it
  is loopback-only.

## 3. What a rebuild can and cannot see in a dirty tree

This is the trap most likely to waste time in Phases 3–5, where a lot of *new files* get
created. Measured precisely, because the two halves behave differently:

| Situation | Does the rebuild see it? |
|---|---|
| Tracked file, edited, **not committed** | ✅ yes — `warning: Git tree is dirty`, then it uses the working-tree contents |
| **Untracked** new file, imported by something | ❌ no — hard error naming the file |
| **Untracked** new file, nothing imports it yet | ❌ no, and **silently** |

So the acceptance test itself ran against an uncommitted edit and worked. It is only *new*
files that vanish.

Credit where due: current nixos-rebuild-ng has improved on what `phase-1.md` §8 recorded
for `nix flake lock`. It no longer just fails obscurely — it names the fix:

```
       To make it visible to Nix, run:
       git -C "/home/chime/bento" add "modules/probe-untracked.nix"
```

That covers the middle row. It does **not** cover the third: a file nothing imports yet —
a wallpaper under `home/chime/theme/`, a config fragment referenced by
`home.file.source` — is simply not there, with no error at all, and the symptom is "my
change did nothing".

`bento rebuild` therefore runs `git ls-files --others --exclude-standard` first and
`git add --intent-to-add`s whatever it finds, printing each path. `-N` records the path
without staging content and is undone with `git rm --cached`, so it cannot surprise a
later commit.

## 4. `nixos-rebuild --sudo`, not `sudo nixos-rebuild`

`PLAN-v1.md` Phase 2 step 1 says `sudo nixos-rebuild switch --flake ~/bento#bento-vm`.
The guest ships **nixos-rebuild-ng 26.11**, which takes
`--elevate {none,sudo,run0}` (with `--sudo` as an alias). `bento rebuild` uses that
instead: flake evaluation and the build run as `chime`, and only activation is elevated.

Both work. The `--sudo` form is preferred because it keeps root out of a user-owned git
repo and out of the user's Nix caches. Since `wheel` has passwordless sudo here
(`modules/core.nix`), neither form prompts.

## 5. Nix's git fetcher does not do owner validation — no `safe.directory` needed

Worth writing down because it is the failure everyone expects and it does not happen.
Running git as root against a repo owned by another user normally trips
`detected dubious ownership in repository`. Root evaluating `chime`'s flake does not:

```
$ sudo nix flake metadata ~/bento
Resolved URL:  git+file:///home/chime/bento
Revision:      befce844981747aeb81a2267e0eca06bd069d0c8
```

No `safe.directory` entry is required anywhere, and none was added. (This is why `sudo
nixos-rebuild` also works — see §4. The preference there is about hygiene, not necessity.)

## 6. `bento` — what it is and what each verb actually does

`modules/bento-cli.nix`, built with `pkgs.writeShellApplication`, installed via
`environment.systemPackages`. **A NixOS module, not the shell alias the plan suggested**,
so that the OS the command rebuilds also ships the command, and so shellcheck runs over it
during that rebuild. `hosts/bento-vm/default.nix` sets `bento.cli.configuration =
"bento-vm"` — the one fact only the host knows, and one *not* derivable from
`networking.hostName`, which is `bento` on every bento machine.

- **`bento rebuild [ACTION]`** — staging guard (§3), then `nixos-rebuild ACTION --sudo
  --flake $FLAKE#$CONFIG`, then the top of `nixos-rebuild list-generations`. `ACTION`
  defaults to `switch`. `BENTO_FLAKE` (default `$HOME/bento`) and `BENTO_CONFIG` override.
- **`bento update [INPUT...]`** — `nix flake update` in the flake directory. Verified
  properly by rewinding the locked `nixpkgs` rev to a fake one and watching it resolve
  back; a bare `bento update` produced **no diff**, because `nixos-unstable` genuinely had
  not moved past `83199d0` in two days. *A green no-change result here is not evidence the
  command works — force a change and watch it come back.*
- **`bento gc [--older-than PERIOD | --all]`** — user profiles, then system profiles, then
  `switch-to-configuration boot`. Measured: `--all` collapsed 5 generations to 1, freed
  4.4 MiB, and left `/boot/loader/entries/` holding exactly one `.conf`.

Nix binaries are called through `${config.nix.package}/bin/...` rather than by name,
because half of them run under `sudo`, which need not preserve `PATH`.
`nixos-rebuild` deliberately is *not* pinned — nixos-rebuild-ng re-execs itself out of the
target flake anyway, so a pinned copy would only be one that gets ignored.

**`bento doctor` was deliberately not added.** `PLAN-v1.md` puts it in Phase 5's
`modules/agent.nix`; the subcommand dispatch in `bento-cli.nix` is the seam it should hang
off.

### The one sharp edge

`bento gc --all` keeps only the running generation. On this machine that also deletes
every entry you could boot back to, and there is no NVRAM and no disk snapshot behind it —
the qcow2 on the host *is* the live disk. The default is `--older-than 30d` for that
reason, and the help text says so.

## 7. Run `nix flake check` inside the VM, not on the Mac

Phase 1 ran it on macOS, where it needs the linux-builder up. Inside the guest it is a
native `aarch64-linux` evaluation: no builder, no nesting, and it finishes in seconds.
It omits `aarch64-darwin` (the `linux-builder` package), which the Mac still has to cover
with `--all-systems` — but for everything Phases 3–5 will touch, the guest is the right
place to run it.

## 8. Settled for later phases — do not re-litigate

- **The repo lives at `~/bento` in the guest, and it is a real git repo with no `origin`.**
  Its only relationship to the host is that the host has it as a remote named `vm`.
- **Transport is git. 9p was measured, considered, and rejected (§2).** Do not re-open it
  without a reason that outweighs coupling the guest to a macOS path.
- **The clean loop destroys the guest**, `~/bento` included. `build-image.sh` replaces
  `artifacts/bento.qcow2` outright. Run `./scripts/vm-sync.sh pull` before ever running it,
  and `./scripts/vm-sync.sh init` after.
- **New files need to be tracked** (§3). In Phases 3–5, which add many, either commit as
  you go or let `bento rebuild` stage them for you — but never conclude "the option didn't
  take effect" without checking `git status` first.
- **Phases 3–5 can now run entirely inside the VM.** They need no linux-builder, no image
  build, and no macOS-side Nix at all. The host is only needed to boot the VM and to
  receive commits.
