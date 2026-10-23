#!/usr/bin/env bash
#
#  osu!nixello installer
#
#  Usage:
#    ./install.sh                 install or repair everything
#    ./install.sh --setup-only    only (re)create the NixOS glue
#    ./install.sh --help          show this help
#    ./install.sh -- <args>       forward <args> to the upstream installer
#
#  Requirements:
#    * NixOS with flakes enabled (nix.settings.experimental-features)
#    * programs.steam.enable = true   (provides `steam-run`)
#    * an internet connection (first run downloads wine-osu + osu!)
#
#
set -euo pipefail

VERSION="1.0.0"
REPO_URL="https://github.com/NelloKudo/osu-winello.git"

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="$XDG_DATA_HOME/osuconfig"
SRC="$XDG_DATA_HOME/osu-winello/src"
BINDIR="${BINDIR:-$HOME/.local/bin}"

# ---------------------------------------------------------------------------
# pretty output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
osu!nixello ${VERSION} - run osu! on NixOS with osu-winello

Usage:
  install.sh                 install or repair everything (recommended)
  install.sh --setup-only    only (re)create the NixOS glue, do not run
                             the upstream installer
  install.sh --help          this message
  install.sh -- <args>       forward <args> to osu-winello.sh

After installing:
  osu-wine                   play osu!
  osu-wine --help            list every launcher feature
  osu-wine --fixprefix       repair the wineprefix
  osu-wine --fixfolders      repair .osz/.osk/file-manager integration
  osu-wine --fix-yawl        repair the Steam Runtime (yawl)

Files created under \${XDG_DATA_HOME:-\$HOME/.local/share}:
  osuconfig/steamrun-yawl         yawl wrapper (steam-run + enter= handling)
  osuconfig/wine-wrap             WINE wrapper (yawl config "winello")
  osuconfig/wineserver-wrap       WINESERVER wrapper
  osuconfig/configs/00-nixos.cfg  environment used by osu-wine
  osu-winello/src                 pristine upstream clone
EOF
}

# ---------------------------------------------------------------------------
# nixpkgs helpers
# ---------------------------------------------------------------------------
# Tools the installer and the launcher expect to find in PATH, mapped to the
# nixpkgs attribute that provides them.
declare -A PKG_FOR=(
    [bash]=bash
    [realpath]=coreutils
    [chmod]=coreutils
    [pgrep]=procps
    [pkill]=procps
    [grep]=gnugrep
    [sed]=gnused
    [awk]=gawk
    [find]=findutils
    [tar]=gnutar
    [xz]=xz
    [wget]=wget
    [curl]=curl
    [git]=git
    [unzip]=unzip
    [ping]=iputils
    [zenity]=zenity
    [xdg-open]=xdg-utils
    [update-desktop-database]=desktop-file-utils
    [update-mime-database]=shared-mime-info
    [cabextract]=cabextract
    [7z]=p7zip
)

REQUIRED_CMDS=(
    bash realpath chmod pgrep pkill grep sed awk find tar xz
    wget curl git unzip ping zenity xdg-open
    update-desktop-database update-mime-database cabextract 7z
)

DEPS_PATH=""

nix_build() {
    # shellcheck disable=SC2086
    nix build --no-link --print-out-paths "$@" 2>/dev/null
}

resolve_deps() {
    local cmd pkg
    local -a missing_pkgs=()
    local -A seen=()

    for cmd in "${REQUIRED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 && continue
        pkg="${PKG_FOR[$cmd]:-}"
        [ -n "$pkg" ] || continue
        [ -n "${seen[$pkg]:-}" ] && continue
        seen[$pkg]=1
        missing_pkgs+=("$pkg")
    done

    if [ "${#missing_pkgs[@]}" -eq 0 ]; then
        ok "all dependencies already available"
        return 0
    fi

    command -v nix >/dev/null 2>&1 ||
        die "nix is not in PATH; this script only works on NixOS with flakes enabled"

    info "fetching missing tools from nixpkgs: ${missing_pkgs[*]}"
    local attrs=()
    for pkg in "${missing_pkgs[@]}"; do attrs+=("nixpkgs#$pkg"); done

    local outs
    if ! outs="$(nix_build "${attrs[@]}")"; then
        die "could not fetch ${missing_pkgs[*]} from nixpkgs.

  Either enable flakes:
      nix.settings.experimental-features = [ \"nix-command\" \"flakes\" ];

  or install these packages yourself, then re-run this script:
      ${missing_pkgs[*]}"
    fi

    local dir
    local -a dirs=()
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [ -d "$dir/bin" ] && dirs+=("$dir/bin")
    done <<<"$outs"

    if [ "${#dirs[@]}" -gt 0 ]; then
        DEPS_PATH="$(IFS=:; printf '%s' "${dirs[*]}")"
        export PATH="$DEPS_PATH:$PATH"
        if [ "${#dirs[@]}" -eq 1 ]; then
            ok "added 1 nix store path to PATH"
        else
            ok "added ${#dirs[@]} nix store paths to PATH"
        fi
    fi
}

find_steam_run() {
    local candidate
    for candidate in \
        "${STEAM_RUN:-}" \
        "$(command -v steam-run 2>/dev/null || true)" \
        /run/current-system/sw/bin/steam-run
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            STEAM_RUN="$candidate"
            ok "steam-run: $STEAM_RUN"
            return 0
        fi
    done
    die "steam-run not found. Enable Steam first:

    { programs.steam.enable = true; }

  then run: sudo nixos-rebuild switch"
}

# ---------------------------------------------------------------------------
# NixOS glue
# ---------------------------------------------------------------------------
write_glue() {
    info "writing NixOS wrappers to $CONF"
    mkdir -p "$CONF/configs" "$XDG_DATA_HOME/applications" \
             "$XDG_DATA_HOME/mime/packages" "$BINDIR" "$(dirname "$SRC")"

    # yawl itself: steam-run normally, host namespace for enter=<pid>.
    cat >"$CONF/steamrun-yawl" <<EOF
#!/bin/sh
# Generated by osu!nixello install.sh - do not edit, re-run the script.
#
# pressure-vessel (used by yawl) needs an FHS root: /usr/bin/true,
# /etc/ld.so.cache, ... On NixOS that only exists inside steam-run.
#
# 'enter=<pid>' joins the container of an already running osu!. That has to
# happen from the host user namespace: steam-run's bubblewrap puts us in a
# sibling namespace where /proc/<pid>/ns/user is not accessible, which is why
# .osz/.osk files and osu:// links would silently do nothing.
[ -x "$CONF/yawl" ] || chmod +x "$CONF/yawl" 2>/dev/null || true
case "\${YAWL_VERBS:-}" in
    *enter=*) exec "$CONF/yawl" "\$@" ;;
esac
exec "$STEAM_RUN" "$CONF/yawl" "\$@"
EOF

    cat >"$CONF/wine-wrap" <<EOF
#!/bin/sh
# Generated by osu!nixello install.sh - do not edit.
# WINE (yawl config "winello").
export YAWL_VERBS="config=winello\${YAWL_VERBS:+;\$YAWL_VERBS}"
exec "$CONF/steamrun-yawl" "\$@"
EOF

    cat >"$CONF/wineserver-wrap" <<EOF
#!/bin/sh
# Generated by osu!nixello install.sh - do not edit.
# WINESERVER (yawl config "winelloserver").
export YAWL_VERBS="config=winelloserver\${YAWL_VERBS:+;\$YAWL_VERBS}"
exec "$CONF/steamrun-yawl" "\$@"
EOF

    chmod +x "$CONF/steamrun-yawl" "$CONF/wine-wrap" "$CONF/wineserver-wrap"

    # Sourced by osu-wine before anything else, so launcher, updater and all
    # helper scripts inherit the same environment. Kept in configs/ because
    # upstream never touches that directory on update.
    {
        echo "# Generated by osu!nixello install.sh - do not edit."
        echo "# Re-run install.sh after changing your system or GC'ing the store."
        echo "WINE=\"$CONF/wine-wrap\""
        echo "WINESERVER=\"$CONF/wineserver-wrap\""
        echo "YAWL_INSTALL_PATH=\"$CONF/steamrun-yawl\""
        if [ -n "$DEPS_PATH" ]; then
            echo "PATH=\"$DEPS_PATH:\$PATH\""
        fi
    } >"$CONF/configs/00-nixos.cfg"

    ok "wrappers + 00-nixos.cfg written"
}

fetch_upstream() {
    info "upstream source: $SRC"
    if [ -d "$SRC/.git" ]; then
        git -C "$SRC" pull --ff-only >/dev/null 2>&1 \
            && ok "updated" \
            || warn "could not update (offline or local changes), using existing copy"
    else
        mkdir -p "$(dirname "$SRC")"
        git clone --depth 1 "$REPO_URL" "$SRC" >/dev/null 2>&1 \
            || die "could not clone $REPO_URL"
        ok "cloned"
    fi
}

print_summary() {
    local osu_path
    osu_path="$(cat "$CONF/osupath" 2>/dev/null || true)"

    echo
    printf '%s────────────────────────────────────────────────────────%s\n' "$C_GREEN" "$C_OFF"
    printf '%s osu!nixello is ready %s\n' "$C_GREEN" "$C_OFF"
    printf '%s────────────────────────────────────────────────────────%s\n' "$C_GREEN" "$C_OFF"
    echo "  launch      : osu-wine"
    [ -n "$osu_path" ] && echo "  osu! folder : $osu_path"
    echo "  launcher    : $BINDIR/osu-wine"
    echo "  prefix      : $XDG_DATA_HOME/wineprefixes/osu-wineprefix"
    echo
    echo "  If 'osu-wine' is not found, add this to your shell config:"
    echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo
    echo "  File associations (.osz/.osk/osu://) are registered in"
    echo "  ~/.config/mimeapps.list by the installer. If opening a beatmap"
    echo "  or skin still does nothing, run:"
    echo "      osu-wine --fixfolders"
    echo
    echo "  First launch starts the osu! installer."
    echo
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local setup_only=0
    local -a upstream_args=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)      usage; exit 0 ;;
            --version)      echo "$VERSION"; exit 0 ;;
            --setup-only)   setup_only=1 ;;
            --)             shift; upstream_args+=("$@"); break ;;
            *)              upstream_args+=("$1") ;;
        esac
        shift
    done

    info "osu!nixello ${VERSION}"

    [ -e /etc/NIXOS ] || warn "this does not look like NixOS; continuing anyway"

    resolve_deps
    find_steam_run
    write_glue
    fetch_upstream

    if [ "$setup_only" -eq 1 ]; then
        ok "setup only, upstream installer not run"
        print_summary
        exit 0
    fi

    info "running the upstream installer"
    cd "$SRC"
    export WINE="$CONF/wine-wrap"
    export WINESERVER="$CONF/wineserver-wrap"
    export YAWL_INSTALL_PATH="$CONF/steamrun-yawl"
    bash ./osu-winello.sh "${upstream_args[@]+"${upstream_args[@]}"}" || {
        warn "the upstream installer reported an error"
        warn "re-run this script, or check its output above"
        exit 1
    }

    print_summary
}

main "$@"
