{ pkgs, lib, ... }:

let
  deps = with pkgs; [
    bash
    coreutils
    procps
    gnugrep
    gnused
    gawk
    findutils
    iputils
    gnutar
    xz
    wget
    curl
    git
    unzip
    zenity
    xdg-utils
    desktop-file-utils
    shared-mime-info
    cabextract
    p7zip
    steam-run
  ];

  osu-winello-install = pkgs.writeShellScriptBin "osu-winello-install" ''
    set -euo pipefail

    export PATH="${lib.makeBinPath deps}:$PATH"

    xdg="''${XDG_DATA_HOME:-$HOME/.local/share}"
    src="$xdg/osu-winello/src"
    conf="$xdg/osuconfig"
    steam_run="/run/current-system/sw/bin/steam-run"

    if [ ! -x "$steam_run" ]; then
      echo "osu!nixello: steam-run not found. Enable Steam first:" >&2
      echo "" >&2
      echo "    { programs.steam.enable = true; }" >&2
      echo "" >&2
      echo "then run: sudo nixos-rebuild switch" >&2
      exit 1
    fi

    mkdir -p "$(dirname "$src")"
    if [ ! -d "$src/.git" ]; then
      git clone https://github.com/NelloKudo/osu-winello.git "$src"
    else
      git -C "$src" pull --ff-only || true
    fi

    mkdir -p "$conf/configs" "$xdg/applications" "$xdg/mime/packages"

    cat > "$conf/steamrun-yawl" <<'WRAP'
#!/bin/sh
[ -x "@CONF@/yawl" ] || chmod +x "@CONF@/yawl" 2>/dev/null || true
case "''${YAWL_VERBS:-}" in
    *enter=*) exec "@CONF@/yawl" "$@" ;;
esac
exec @STEAM_RUN@ "@CONF@/yawl" "$@"
WRAP

    cat > "$conf/wine-wrap" <<'WRAP'
#!/bin/sh
export YAWL_VERBS="config=winello''${YAWL_VERBS:+;$YAWL_VERBS}"
exec "@CONF@/steamrun-yawl" "$@"
WRAP

    cat > "$conf/wineserver-wrap" <<'WRAP'
#!/bin/sh
export YAWL_VERBS="config=winelloserver''${YAWL_VERBS:+;$YAWL_VERBS}"
exec "@CONF@/steamrun-yawl" "$@"
WRAP

    sed -i \
      -e "s|@STEAM_RUN@|$steam_run|g" \
      -e "s|@CONF@|$conf|g" \
      "$conf/steamrun-yawl" "$conf/wine-wrap" "$conf/wineserver-wrap"

    chmod +x "$conf/steamrun-yawl" "$conf/wine-wrap" "$conf/wineserver-wrap"

    cat > "$conf/configs/00-nixos.cfg" <<'CFG'
WINE="$XDG_DATA_HOME/osuconfig/wine-wrap"
WINESERVER="$XDG_DATA_HOME/osuconfig/wineserver-wrap"
YAWL_INSTALL_PATH="$XDG_DATA_HOME/osuconfig/steamrun-yawl"
CFG

    cd "$src"

    export WINE="$conf/wine-wrap"
    export WINESERVER="$conf/wineserver-wrap"
    export YAWL_INSTALL_PATH="$conf/steamrun-yawl"

    exec bash ./osu-winello.sh "$@"
  '';
in
{
  environment.systemPackages = deps ++ [ osu-winello-install ];
}
