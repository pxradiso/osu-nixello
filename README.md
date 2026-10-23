# osu!nixello

osu!nixello is the NixOS-specific version of
[osu-winello](https://github.com/NelloKudo/osu-winello): the same installer and
launcher, adapted to run on NixOS. It handles the parts osu-winello expects
from an FHS distro (wine-osu, the Steam Runtime, yawl) without patching
anything upstream, so the built-in updater keeps working like it does on every
other distro.

There are two ways to get there:

- **`install.sh`** does everything in one pass and touches nothing in
  `/etc/nixos`.
- **`osu-nixello.nix`** is a NixOS module, for people who would rather keep
  their config declarative. It pulls in the same dependencies and adds an
  `osu-winello-install` helper.

Both end up with the same installation, so pick whichever one matches how you
manage your machine.

---

## Requirements

You'll need NixOS with flakes turned on:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

Steam has to be enabled too, since it's what provides `steam-run` and osu!
won't start without it:

```nix
programs.steam.enable = true;
```

And you need to be online the first time, because wine-osu, the Steam Linux
Runtime and the osu! installer all get downloaded.

---

## Installing with the script

```bash
git clone https://github.com/pxradiso/osu-nixello.git
cd osu-nixello
./install.sh
```

Then just run:

```bash
osu-wine
```

The first launch opens the usual osu! installer, so click through it once.

If your shell can't find `osu-wine`, `~/.local/bin` is probably not in your
`PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

It's fine to run `./install.sh` again whenever you want. It doesn't duplicate
anything; it repairs the wrappers, refreshes the dependencies and pulls the
latest upstream changes.

## Installing as a module

```bash
sudo cp osu-nixello.nix /etc/nixos/
```

```nix
# /etc/nixos/configuration.nix
imports = [
  ./hardware-configuration.nix
  ./osu-nixello.nix
];
```

```bash
sudo nixos-rebuild switch
osu-nixello-install
```

---

## Usage

```
osu-wine                    play osu!
osu-wine --help             list every launcher feature
osu-wine --update           update the launcher and wine-osu
osu-wine --fixprefix        rebuild/repair the wineprefix
osu-wine --fix-yawl         re-download the Steam Runtime
osu-wine --fixfolders       repair .osz/.osk/osu:// integration
osu-wine --changedir        move the osu! folder
osu-wine --osuhandler FILE  hand a beatmap/skin/link to osu!
```

File associations are set up for `.osz`, `.osk`, `.osr` files and `osu://`
links, so double-clicking a beatmap or a skin in your file manager imports it
into a running osu!, or starts osu! if it isn't running yet.

---

## How it works

osu-winello is written for FHS distros, and two things it relies on don't
exist on NixOS.

**The helper tools.** The installer calls things like `zenity`, `unzip`,
`ping`, `update-mime-database` and `cabextract`. `install.sh` checks which of
them are missing, takes those from nixpkgs and puts their store paths on `PATH`
via `~/.local/share/osuconfig/configs/00-nixos.cfg`, which `osu-wine` sources
on every start.

**An FHS root for pressure-vessel.** yawl launches osu! inside a Steam Runtime
container, and pressure-vessel needs to see `/usr/bin/true`,
`/etc/ld.so.cache` and friends. A stock NixOS doesn't have those, but
`steam-run` does. So `WINE`, `WINESERVER` and `YAWL_INSTALL_PATH` point at
small wrappers that call yawl through `steam-run`.

There's one exception. yawl's `enter=<pid>` verb joins the container of an
already running osu!, which is how a `.osz`, `.osk` or `osu://` link gets
handed over to the running game. `steam-run` puts everything in its own
bubblewrap user namespace, and from in there `/proc/<pid>/ns/user` isn't
reachable:

```
yawl: cannot open /proc/57903/ns/user: Permission denied
```

The import then fails silently. That's why the wrapper calls yawl **directly**
when it sees `enter=`, on the host user namespace, where no FHS root is needed.
Every other call still goes through `steam-run`.

All the wine state (wine-osu, the prefix, osu!, your maps and skins) lives
under `~/.local/share`, outside the Nix store, so osu-winello's own updater can
keep doing its job.

### Files it creates

```
~/.local/bin/osu-wine                        launcher
~/.local/share/osuconfig/steamrun-yawl       yawl wrapper
~/.local/share/osuconfig/wine-wrap           WINE wrapper
~/.local/share/osuconfig/wineserver-wrap     WINESERVER wrapper
~/.local/share/osuconfig/configs/00-nixos.cfg  environment for osu-wine
~/.local/share/osu-winello/src/              upstream clone
~/.local/share/osuconfig/wine-osu/           wine-osu build
~/.local/share/wineprefixes/osu-wineprefix/  wineprefix
~/.local/share/osu-wine/osu!/                osu! itself
~/.local/share/yawl/                         Steam Linux Runtime
```

---

## Troubleshooting

**Opening a beatmap or skin does nothing.**
Imports go through the running instance, so check that osu! is actually open,
then repair the associations:

```bash
osu-wine --fixfolders
```

You can verify the handler with:

```bash
xdg-mime query default application/x-osu-beatmap-archive
# should print: osuwinello-file-extensions-handler.desktop
```

**`Runtime Platform missing or download incomplete`.**
The Steam Runtime is incomplete or gone, download it again:

```bash
osu-wine --fix-yawl
```

**`--fixprefix` fails inside winetricks.**
That usually means `cabextract` isn't on `PATH`. The module provides it; if
you installed with the script, re-run `./install.sh`.

**After `nix-collect-garbage`, the folder picker or `--fixprefix` breaks.**
`00-nixos.cfg` points at store paths that the garbage collector may have
removed. Run `./install.sh` (or `osu-winello-install`) again to refresh them.
If this bothers you, the module avoids the problem entirely.

**Audio crackles or there's no sound.**
Use PipeWire with `pipewire-libjack` (or `pipewire.jack`) enabled. Wine picks
up the host sound server through `PULSE_SERVER` from inside the FHS container.

---

## Reporting a problem

Not every bug belongs in the same place:

- **It's osu!nixello.** The installer, the module, the wrappers, a path that
  should exist on NixOS but doesn't: open an issue here, where the NixOS side
  is maintained: <https://github.com/pxradiso/osu-nixello/issues>
- **It's osu-winello.** The launcher, wine-osu, yawl, an option that misbehaves
  on other distros too: report it upstream, where the people who write that
  code can actually fix it: <https://github.com/NelloKudo/osu-winello/issues>

If you're not sure which one it is, open it here and say what you did and what
happened. Moving an issue later is easy; a report that never gets filed isn't.

---

## Uninstalling

```bash
rm -f ~/.local/bin/osu-wine
rm -rf ~/.local/share/osuconfig ~/.local/share/osu-winello \
       ~/.local/share/wineprefixes/osu-wineprefix ~/.local/share/osu-wine \
       ~/.local/share/yawl
rm -f ~/.local/share/applications/osuwinello-*.desktop
rm -f ~/.local/share/mime/packages/osuwinello-file-extensions.xml
update-mime-database ~/.local/share/mime
update-desktop-database ~/.local/share/applications
```

That last `rm -rf` already takes your maps and skins (`~/.local/share/osu-wine/osu!`)
with it, which is fine unless you'd rather keep them. In that case copy the
folder somewhere else first.

---

## Credits

- [NelloKudo/osu-winello](https://github.com/NelloKudo/osu-winello) for the
  installer and launcher this wraps
- [whrvt/yawl](https://github.com/whrvt/yawl) for the Wine launcher that runs
  on the Steam Runtime
- Valve, for the Steam Linux Runtime and pressure-vessel
