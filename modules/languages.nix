# Language toolchains this machine carries for every user.
#
# System-wide rather than in chime's home-manager profile, for the reason modules/agent.nix
# gives about its own list: the agent is part of this OS, and a toolchain it cannot see is
# a toolchain that does not exist as far as rewriting this machine goes.
#
# This is the *default* half of the story. The per-project half is direnv
# (home/chime/direnv.nix): a repository with its own flake.nix gets its own pinned
# toolchain on `cd`, which is where a project that needs a different Elixir than this one
# should say so. What lands here is only what is worth having on a bare shell.
{ pkgs, ... }:
let
  # **One Erlang, named once.** Elixir is not independent of the VM it runs on — it is
  # compiled against a specific OTP and reports it (`Elixir 1.20.3 (compiled with
  # Erlang/OTP 29)`). Taking `pkgs.erlang_29` and `pkgs.elixir_1_20` as two top-level
  # packages would work by coincidence and silently stop working the day nixpkgs points
  # them at different OTPs, with two Erlangs in the closure and mix running against
  # whichever won the PATH. `beam.packages.<otp>` exists precisely to make the pairing
  # explicit, so it is used here even though it is the longer spelling.
  otp = pkgs.beam.interpreters.erlang_29;
  beam = pkgs.beam.packages.erlang_29;
in
{
  environment.systemPackages = [
    # OTP 29. Not `pkgs.erlang`, which is 28: nixpkgs' `latestVersion` in
    # pkgs/top-level/beam-packages.nix still reads "erlang_28", so the bare alias lags a
    # major release behind what the tree actually carries. `erlang_29` is not a top-level
    # attribute at all — `nix eval nixpkgs#erlang_29` fails with "did you mean erlang_26,
    # erlang_27 or erlang_28?", which reads exactly like OTP 29 being absent. It is not;
    # it lives under `beam.interpreters` and is fully cached for aarch64-linux.
    otp

    # Elixir 1.20, likewise: the bare `elixir` in this nixpkgs is 1.18.4.
    beam.elixir_1_20

    # mix reaches for rebar3 the moment a dependency carries Erlang sources, and having
    # it install its own copy into ~/.mix is the kind of mutable state this machine is
    # built to avoid.
    beam.rebar3
  ];
}
