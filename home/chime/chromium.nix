# Chromium — the browser, on Super+B and behind `xdg-open`.
#
# PLAN-v1 §5 step 2 pre-authorises substituting Firefox "if the aarch64 binary cache is
# missing". It is not: `nix build --dry-run nixpkgs#chromium` on this guest reports 8
# paths *fetched* (200 MiB) and zero built, so chromium 152 is in the aarch64-linux binary
# cache and risk #2 does not fire. Firefox stays unused.
#
# Chromium is not GTK 4, so `GSK_RENDERER=cairo` (learned/phase-4.md §2) does nothing for
# it either way — it brings its own compositor and its own software fallback. The flags
# below are what that fallback needs to be *chosen* rather than discovered after a crash.
{ pkgs, ... }:
{
  programs.chromium = {
    enable = true;

    commandLineArgs = [
      # There is no GPU behind this machine's virtio-gpu (learned/phase-0.md §2). Left to
      # itself Chromium starts a GPU process, fails to get a usable GL context, and
      # restarts it — the same shape of loop `LIBGL_ALWAYS_SOFTWARE` produced in aquamarine
      # (learned/phase-3.md §2), and just as invisible from a screenshot. Saying so up
      # front skips the process entirely and goes straight to the software rasteriser.
      "--disable-gpu"

      # Without this Chromium looks for gnome-keyring or kwallet to store passwords in,
      # finds neither on a Hyprland-only session, and blocks on the lookup at startup. The
      # `basic` store keeps them in the profile, obfuscated — which is the honest state of
      # affairs on a disposable dev VM anyway.
      "--password-store=basic"

      # `OZONE_PLATFORM=wayland` is already in the session environment
      # (modules/desktop.nix), but that variable reaches a process only through PAM, and
      # `environment.sessionVariables` needs a *reboot* rather than a rebuild to take
      # (learned/phase-4.md §7). A flag on the command line cannot be out of date.
      "--ozone-platform=wayland"
    ];
  };

  # `xdg-open https://…` and every application that shells out to it. Without an explicit
  # default, xdg-open falls back to scanning the desktop-entry database in an order nobody
  # controls, and on a machine with exactly one browser that is a coin toss it happens to
  # win — until something else registers a scheme handler.
  #
  # `chromium-browser.desktop` is the name nixpkgs installs, not `chromium.desktop`.
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      let
        browser = [ "chromium-browser.desktop" ];
      in
      {
        "text/html" = browser;
        "application/xhtml+xml" = browser;
        "x-scheme-handler/http" = browser;
        "x-scheme-handler/https" = browser;
        "x-scheme-handler/about" = browser;
        "x-scheme-handler/unknown" = browser;
      };
  };

  # `xdg-open` itself, which is in xdg-utils and is not otherwise pulled in by anything on
  # this machine — the portals provide the *Wayland* open-uri path, not the CLI.
  home.packages = [ pkgs.xdg-utils ];
}
