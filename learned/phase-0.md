# What Phase 0 taught us

**Date:** 2026-08-30 · **Host:** Apple Silicon MacBook, macOS 26.5.2 (build 25F84), `arm64`
**Outcome:** ✅ Phase 0 complete — the Mac can build `aarch64-linux` derivations.

This is the findings log. Everything here was *measured on this machine*, not assumed.
Where something contradicts common documentation, that's called out explicitly — those
are the parts most likely to waste someone's afternoon.

---

## 1. The single most important lesson: our acceptance test was lying

The original Phase 0 acceptance criterion was:

```
nix build nixpkgs#legacyPackages.aarch64-linux.hello
```

**This test passes on a Mac with no Linux builder whatsoever.** `hello` is prebuilt for
`aarch64-linux` and sitting in `cache.nixos.org`, so Nix simply *substitutes* it. Nothing
is compiled, no builder is consulted, and you get a green light for a broken setup.

We only caught it because the output said `copying path ... from 'https://cache.nixos.org'`
rather than `building ...`.

**The correct probe** forces a derivation that cannot exist in any cache (unique name via
timestamp) and therefore *must* be built:

```bash
nix build --impure --no-link --print-out-paths --expr \
  'with import <nixpkgs> { system = "aarch64-linux"; };
   runCommand "probe-'"$(date +%s)"'" {} "uname -m > $out; uname -s >> $out"'
```

Failure mode looks like this:

```
error: Cannot build '/nix/store/...-probe.drv'
       Reason: platform mismatch
       Required system: 'aarch64-linux'
       Current system: 'aarch64-darwin'
```

Success prints `aarch64` / `Linux`.

> **Generalised lesson:** when testing whether a *build capability* works, always use an
> input that cannot be substituted. Any well-known package tests your network, not your
> toolchain.

---

## 2. Graphics: the host QEMU cannot do GPU acceleration, full stop

This is the finding that most shapes v1.

`brew install qemu` gives **QEMU 11.1.1**, and it is built **without OpenGL**:

| Probe | Result |
|---|---|
| `qemu-system-aarch64 -device help \| grep gpu` | only `virtio-gpu-pci`, `virtio-gpu-device` — **no `virtio-gpu-gl-pci`** |
| `qemu-system-aarch64 -display help` | only `none`, `curses`, `cocoa`, `dbus` — no gtk/sdl |
| `qemu-system-aarch64 -display cocoa,gl=es …` | `qemu-system-aarch64: OpenGL support was not enabled in this build of QEMU` |
| `otool -L $(which qemu-system-aarch64)` | no virglrenderer, no epoxy, no ANGLE linked |

**Implication:** Hyprland in the bento VM *must* run on software rendering (llvmpipe) in
v1. This is not a conservative choice we can revisit with a flag — there is no GL to turn
on. Expect the desktop to feel sluggish.

**Getting GL means replacing the host QEMU binary**, not reconfiguring it. See §3.

### Good news: hvf works and is properly entitled

macOS requires the `com.apple.security.hypervisor` entitlement for hardware
virtualization. Homebrew's QEMU already carries it:

```
$ codesign -d --entitlements - /opt/homebrew/bin/qemu-system-aarch64
    [Key] com.apple.security.hypervisor
    [Value] [Bool] true
```

`-accel help` lists `hvf` and `tcg`. So `-machine virt,accel=hvf -cpu host` should work in
Phase 1. **If we ever build our own QEMU (for GL), we must re-sign it with this
entitlement** or it will refuse to use hvf.

### Firmware gotcha: there is no aarch64 vars file

Homebrew ships `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` (64 MiB) but **no
`edk2-aarch64-vars.fd`** — only `edk2-arm-vars.fd`, which is for 32-bit ARM. Phase 1 must
create its own writable vars pflash:

```bash
dd if=/dev/zero of=artifacts/edk2-aarch64-vars.fd bs=1m count=64
```

Both pflash drives must be 64 MiB or EDK2 will not boot.

---

## 3. How try-omarchy actually gets GPU acceleration

We cloned and read [try-omarchy](https://github.com/themartiano/try-omarchy) rather than
trusting its README. It targets the *same* host and guest architecture as us, so it is the
reference implementation for the hard parts.

### Host side — they build QEMU from source

From `macos/build-qemu-gpu-runtime.sh`:

- **QEMU 10.2.50**, built from the `startergo/homebrew-qemu-virgl-kosmickrisp` tap
- pinned dependencies: **virglrenderer 1.0.33**, **ANGLE 1.0.15**, plus epoxy
  - ANGLE is the load-bearing piece: macOS dropped OpenGL, so ANGLE translates the guest's
    GL-ES calls to Metal. Without it there is no GL on modern macOS at all.
- two local patches:
  - `qemu-cocoa-dynamic-display.patch` — *"publish the live backing display through
    virtio-gpu"*. This is what produces their headline "automatic guest resolution and
    HiDPI scale updates" feature.
  - `qemu-cocoa-product-identity.patch`
- configure flags:
  ```
  --target-list=aarch64-softmmu --without-default-features --enable-system
  --enable-hvf --disable-tcg --enable-cocoa --enable-opengl --enable-virglrenderer
  --enable-pixman --enable-slirp --enable-fdt=internal --enable-sdl
  --audio-drv-list=sdl --enable-virtfs
  ```
- the result is code-signed for `com.apple.security.hypervisor`, and they *verify* this at
  launch before starting the VM.

### Runtime flags

```
-device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080
-display cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=on,swap-opt-cmd=off
```

They **hard-fail** if `virtio-gpu-gl-pci` is absent — there is no software-rendering
fallback anywhere in their design. **Ours is deliberately the mirror image:** software is
the v1 baseline, GL is the optional upgrade.

### Guest side — directly portable to our NixOS config

This is the most immediately valuable part, and it **corrected a wrong guess in our plan**.

`guest/factory-overlay/usr/lib/environment.d/90-try-omarchy.conf`:

```
WLR_RENDERER_ALLOW_SOFTWARE=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
MOZ_ENABLE_WAYLAND=1
OZONE_PLATFORM=wayland
QT_QPA_PLATFORM=wayland
```

- The variable is **`WLR_RENDERER_ALLOW_SOFTWARE`**, *not* the older
  `WLR_NO_HARDWARE_CURSORS` our plan had guessed. Our Phase 3 has been corrected.
- Note they set the software-rendering flag **even though VirGL works for them** — cheap
  insurance. We should keep it too.
- The Wayland hints for Electron/Firefox/Qt will be needed by our Phase 5 apps anyway.

Guest GPU packages are just **`mesa` + `vulkan-swrast`** (`guest/packages.txt`). There is
**no separate virgl package to hunt for** — the virgl Gallium driver ships inside mesa.

They pass a kernel argument `omarchy.qemu_virgl=1` and key guest behaviour off it
(`guest/fragments/hypr-monitors-arm-qemu.append.lua`):
- `cursor { invisible = true }` — because Cocoa composes the host cursor *outside* the
  guest scanout, giving zero-lag pointer motion;
- runs a display-sync helper;
- and deliberately **lets virtio-gpu EDID carry the live window size and host refresh
  rate** instead of hardcoding a monitor mode. That is the actual mechanism behind dynamic
  resolution — not magic, just EDID.

**Consequence for us:** without their Cocoa patch we will be on a fixed resolution in v1.

---

## 4. Determinate Nix: what it is and where it differs from stock Nix

Installed with:

```
curl -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate --no-confirm
```

Giving **Determinate Nix 3.22.2 (Nix 2.35.2)**. Installer flags were verified against
`nix-installer install --help` (v3.22.2): `--determinate`, `--prefer-upstream-nix`,
`--no-confirm`, `--extra-conf`, `--force`, `--skip-nix-conf`.

Three differences from stock Nix that **will silently break copy-pasted documentation**:

### 4.1 `/etc/nix/nix.conf` is not yours

It begins:

```
# DETERMINATE NIX CONFIG
# do not modify! this file will be replaced!
# user modification can go in nix.custom.conf
```

and contains `!include nix.custom.conf`. **All user settings must go in
`/etc/nix/nix.custom.conf`**, or they vanish on the next upgrade.

### 4.2 The daemon has a different launchd label

Nixpkgs documentation says to restart `org.nixos.nix-daemon`. **That label does not exist
here.** The installed daemons are:

| Label |
|---|
| `systems.determinate.nix-daemon` |
| `systems.determinate.nix-installer.nix-hook` |
| `systems.determinate.nix-store` |

So the documented restart command is a **silent no-op** — you change config, restart
nothing, and then debug a setting that never loaded. Correct command:

```bash
sudo launchctl kickstart -k system/systems.determinate.nix-daemon
```

### 4.3 `nixpkgs` resolves to FlakeHub, not the NixOS channel

`nix.conf` sets:

```
extra-nix-path = nixpkgs=flake:https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/*.tar.gz
```

So a bare `nixpkgs#...` reference pulls DeterminateSystems' weekly nixpkgs snapshot. Worth
knowing when reasoning about which revision you actually built against. `lazy-trees` is
enabled by default.

Defaults worth remembering: `trusted-users = root` only (so a normal user **cannot**
override settings from the CLI — they are ignored), and `max-jobs = auto`.

---

## 5. The Determinate "native Linux builder" is licence-gated — do not chase it

This looked like the perfect solution: build Linux derivations through macOS's
Virtualization.framework with no VM to manage. We investigated thoroughly before ruling it
out, because the evidence strongly suggested it *should* work:

- `/usr/local/bin/determinate-nixd` is signed by **Determinate Systems (Team `X3JQ4VPJZ6`)**
  and **already carries the `com.apple.security.virtualization` entitlement**;
- a **hidden** `determinate-nixd builder <BUILDER_JSON>` subcommand exists (absent from
  `--help`, but real), with `--memory-size`, `--cpu-count`, `--kernel`, `--initrd`;
- Nix itself knows the `external-builders` setting.

But `determinate-nixd version` reports only `lazy-trees` as enabled, and configuring it
correctly still fails:

```
Error: failed to set up Native Linux Builder
Caused by: HTTP status code 400 Bad Request, reply:
  The Native Linux Builder is not currently available.
  Contact support@determinate.systems for more information.
```

**It phones home and is refused server-side.** The gate is an account/licence check, not a
configuration mistake — the binary is capable, the entitlement is present, the setting
parses. No amount of local configuration will open it. Their docs say to request access by
emailing support with a FlakeHub username.

> **Corollary, and it bit us:** while `external-builders` is configured, it **hijacks all
> Linux builds** and fails, rather than falling through to a remote builder. It must be
> actively *removed*, not merely supplemented, before `darwin.linux-builder` will work.

---

## 6. `darwin.linux-builder`: the path that works

The free, account-free fallback. Authoritative documentation is **not** in the rendered
nixpkgs manual (our fetch of `#sec-darwin-builder` came back empty) but in the source:
[`doc/packages/darwin-builder.section.md`](https://github.com/NixOS/nixpkgs/blob/master/doc/packages/darwin-builder.section.md).

### No chicken-and-egg problem

The obvious worry — *does building the Linux builder require a Linux builder?* — was
checked before committing to the approach:

```
$ nix build --dry-run nixpkgs#darwin.linux-builder
these 664 paths will be fetched (715.3 MiB download, 2.9 GiB unpacked)
```

**664 fetched, 0 built.** Entirely substitutable. Safe.

### How it actually works (read from the scripts, not the docs)

`create-builder` is just:

```
add-keys && run-builder
```

- **`add-keys`** generates an ed25519 keypair in `${KEYS:-./keys}` — note that default is
  **relative to the current directory**. It then compares the public key against
  `/etc/nix/builder_ed25519.pub` and, if they differ, runs `sudo install-credentials`.
- **`install-credentials`** is trivial:
  ```
  install -g nixbld -m 600 "$KEYS/builder_ed25519"     /etc/nix/builder_ed25519
  install -g nixbld -m 644 "$KEYS/builder_ed25519.pub" /etc/nix/builder_ed25519.pub
  ```
- **`run-builder`** does `nix-store --add "$KEYS"` then runs the NixOS VM.
- **`run-nixos-vm`** uses `NIX_DISK_IMAGE` (default `./nixos.qcow2`, again CWD-relative)
  and creates a **20 GB** ext4 image converted to qcow2 on first boot.

**Two consequences we designed around:**

1. Because the key directory is CWD-relative, launching from a different directory
   regenerates keys and **re-prompts for sudo every time**. An agent cannot start the
   builder unattended.
2. The private key must be **readable by the invoking user** — `run-builder` reads it as
   you, not as root. Generating it as root with mode 0600 makes the builder unstartable
   without sudo.

So `scripts/setup-linux-builder.sh` generates a **stable keypair as the user** under
`~/.local/state/bento/builder-keys`, installs it into `/etc/nix` once, and pins
`NIX_DISK_IMAGE` to the same state directory. After that, `scripts/start-linux-builder.sh`
needs **no sudo, ever** — which is what makes Phase 1 runnable end-to-end by an agent.

We reimplement the two `install` lines ourselves rather than calling the store path of
`install-credentials`, so a nixpkgs update cannot break the script with a stale hash.

### Configuration that works

In `/etc/nix/nix.custom.conf`:

```
extra-trusted-users = chime
builders = ssh-ng://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 4 - - - <base64 host key>
builders-use-substitutes = true
```

In `/etc/ssh/ssh_config.d/100-linux-builder.conf` (the builder listens on **31022**, not 22):

```
Host linux-builder
  Hostname localhost
  HostKeyAlias linux-builder
  Port 31022
  User builder
  IdentityFile /etc/nix/builder_ed25519
```

**Security note:** the builder uses a *publicly known* SSH host key, shipped in nixpkgs.
That is acceptable only because it listens on localhost. Do not expose it to other
machines without replacing the key.

### Verified working

```
building '/nix/store/...-bento-probe-....drv'...
copying path '...' from 'ssh-ng://builder@linux-builder'...
```
```
aarch64
Linux
BUILT-ON-REAL-LINUX
```

### Alternative not taken

`darwin.linux-builder-vz` runs the same guest on Apple's Virtualization.framework instead
of QEMU — same port, same host key, drop-in config compatible, and faster for `x86_64`
because it uses Rosetta rather than emulation. **It refuses to start without Rosetta
installed**, so we skipped it; we only need `aarch64-linux`. Worth revisiting if the QEMU
builder proves slow (`softwareupdate --install-rosetta --agree-to-license`).

---

## 7. macOS / shell gotchas that cost us time

| Gotcha | Detail |
|---|---|
| **No `timeout(1)`** | macOS ships no `timeout` / `gtimeout` by default. Use background jobs with an `until` poll loop instead. |
| **BSD `grep` ≠ GNU `grep`** | `\s` and `\b` are GNU extensions and are **not portable** here. Use POSIX classes: `[[:space:]]`. We shipped this bug once and caught it before it mangled `nix.custom.conf`. |
| **`sudo` timestamps are per-TTY** | Caching credentials in one shell does **not** let a separate agent process use sudo. Any root work must be batched into a single script the human runs — hence the one-sudo design. |
| **Verify before you rewrite config** | We dry-ran the config filter against the real `/etc/nix/nix.custom.conf` and confirmed it preserved the header and stripped only our lines, *before* running it as root. |

---

## 8. Confirmed for Phase 1

- `nixos-generators` **1.8.0** is in nixpkgs.
- The **`qcow-efi`** format exists (verified against the upstream `formats/` directory,
  which contains `qcow-efi.nix`, `qcow.nix`, `raw-efi.nix`, `raw.nix`, `vm.nix`, and ~27
  others). Phase 1's plan is valid as written.

---

## 9. Method notes — what worked, for future phases

- **Read the source, not the README.** Cloning try-omarchy and grepping its scripts gave
  exact device flags, dependency versions, and guest env vars. Its README described
  features; the source explained mechanisms.
- **Probe the tool, don't trust the docs.** `-device help`, `-display help`,
  `codesign -d --entitlements`, and `--help` on the installer each corrected an assumption.
- **Prefer failing fast and cheaply.** `nix build --dry-run` answered the chicken-and-egg
  question in seconds before we committed to an approach.
- **Distrust green tests.** See §1. A passing test that exercises the wrong mechanism is
  worse than no test.
