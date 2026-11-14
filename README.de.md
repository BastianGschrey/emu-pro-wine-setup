# EMU PRO + USB2CAN unter Linux (Wine)

🇬🇧 [English](README.md) | 🇩🇪 **Deutsch**

Richtet die Ecumaster-Software **EMU PRO** samt **ECUMASTER USB2CAN**-Adapter unter Wine ein.

## Was das Skript macht

1. Installiert Wine (nur Debian/Ubuntu/Mint via `apt`, sonst vorher selbst installieren)
2. Fügt den Benutzer der Gruppe `dialout` hinzu (Zugriff auf `/dev/ttyACM*`)
3. Legt das Wine-Prefix an
4. Führt den EMU-PRO-Installer aus
5. Patcht `EUSB2CAN.dll` (serielle Read-Timeouts – sonst hängt Wine 9 beim Lesen, Fehler `GET_VER_ERR`).
   Das Original wird als `EUSB2CAN.dll.orig` gesichert.
6. Trägt den Adapter in die Wine-Registry ein (Geräteeintrag + COM-Port-Zuordnung)

## Voraussetzungen

- Linux mit `python3`
- EMU-PRO-Installer (`EMU_PRO_Setup_xxx.exe`) von der Ecumaster-Website – **nicht** in diesem Repo enthalten
- USB2CAN-Adapter (USB-ID `0483:5740`)

## Benutzung

Die Ausgaben des Skripts sind auf Englisch.

```bash
# Installer neben das Skript oder nach ~/Downloads legen, dann:
./emu-pro-wine-setup.sh

# oder Installer direkt angeben:
./emu-pro-wine-setup.sh ~/Downloads/EMU_PRO_Setup_xxx.exe
```

Nicht als root starten – `sudo` wird bei Bedarf selbst aufgerufen.
Nach dem ersten Lauf einmal ab- und wieder anmelden (Gruppe `dialout`).

### Optionen

| Option | Bedeutung |
|---|---|
| `--prefix DIR` | Wine-Prefix (Standard: `$WINEPREFIX` oder `~/.wine`) |
| `--silent` | Installer ohne Dialoge |
| `--reinstall` | Installer auch ausführen, wenn EMU PRO schon installiert ist |
| `--serial NR` | Adapter-Seriennummer vorgeben (sonst automatisch erkannt) |
| `--com N` | erste COM-Nummer (Standard: 33, max. 99) |
| `--skip-install` | nur DLL-Patch + Adapter-Registrierung |

Das Skript kann gefahrlos mehrfach laufen, z. B. nach einem EMU-PRO-Update
(das die gepatchte DLL überschreibt) oder für einen weiteren Adapter.

## Fehlerbehebung

- **„No adapter detected“** – `lsusb` muss `0483:5740` zeigen; ggf. `--serial` angeben.
- **„Patch pattern not found“** – vermutlich eine neuere EMU-PRO-Version mit geänderter DLL.
  Es wurde nichts verändert.

## Hinweis

Inoffizielles Community-Skript, nicht von Ecumaster. Benutzung auf eigene Gefahr.

## Lizenz

MIT – siehe [LICENSE](LICENSE).
