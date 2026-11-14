# EMU PRO + USB2CAN on Linux (Wine)

🇬🇧 **English** | 🇩🇪 [Deutsch](README.de.md)

Sets up the Ecumaster software **EMU PRO** together with the **ECUMASTER USB2CAN** adapter under Wine.

## What the script does

1. Installs Wine (Debian/Ubuntu/Mint via `apt` only – on other distros install it yourself first)
2. Adds the user to the `dialout` group (access to `/dev/ttyACM*`)
3. Creates the Wine prefix
4. Runs the EMU PRO installer
5. Patches `EUSB2CAN.dll` (serial read timeouts – otherwise Wine 9 hangs while reading, error `GET_VER_ERR`).
   The original is backed up as `EUSB2CAN.dll.orig`.
6. Registers the adapter in the Wine registry (device entry + COM port mapping)

## Requirements

- Linux with `python3`
- EMU PRO installer (`EMU_PRO_Setup_xxx.exe`) from the Ecumaster website – **not** included in this repo
- USB2CAN adapter (USB ID `0483:5740`)

## Usage

```bash
# Put the installer next to the script or into ~/Downloads, then:
./emu-pro-wine-setup.sh

# or pass the installer directly:
./emu-pro-wine-setup.sh ~/Downloads/EMU_PRO_Setup_xxx.exe
```

Do not run as root – the script calls `sudo` itself when needed.
After the first run, log out and back in once (`dialout` group).

### Options

| Option | Meaning |
|---|---|
| `--prefix DIR` | Wine prefix (default: `$WINEPREFIX` or `~/.wine`) |
| `--silent` | Run the installer without dialogs |
| `--reinstall` | Run the installer even if EMU PRO is already installed |
| `--serial NR` | Specify the adapter serial number (otherwise detected automatically) |
| `--com N` | First COM port number (default: 33, max. 99) |
| `--skip-install` | Only DLL patch + adapter registration |

The script is safe to run repeatedly, e.g. after an EMU PRO update
(which overwrites the patched DLL) or for an additional adapter.

## Troubleshooting

- **"No adapter detected"** – `lsusb` must show `0483:5740`; otherwise use `--serial`.
- **"Patch pattern not found"** – probably a newer EMU PRO version with a changed DLL.
  Nothing has been modified.

## Disclaimer

Unofficial community script, not affiliated with Ecumaster. Use at your own risk.

## License

MIT – see [LICENSE](LICENSE).
