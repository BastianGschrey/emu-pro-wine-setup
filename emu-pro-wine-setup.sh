#!/usr/bin/env bash
# =============================================================================
#  EMU PRO (Ecumaster) + USB2CAN-Adapter unter Wine einrichten
#
#  Schritte:
#    1. Wine installieren (Debian/Ubuntu via apt, falls nicht vorhanden)
#    2. Benutzer in Gruppe "dialout" (Zugriff auf /dev/ttyACM*)
#    3. Wine-Prefix anlegen
#    4. EMU PRO installieren (Installer-EXE)
#    5. EUSB2CAN.dll patchen (serielle Read-Timeouts, sonst haengt Wine 9 beim Lesen)
#    6. USB2CAN-Adapter in der Wine-Registry anlegen (Fake-Geraeteeintrag + COM-Port)
#
#  Aufruf:
#    ./emu-pro-wine-setup.sh [Optionen] [EMU_PRO_Setup_xxx.exe]
#
#  Optionen:
#    --prefix DIR      Wine-Prefix (Standard: $WINEPREFIX oder ~/.wine)
#    --silent          Installer ohne Dialoge ausfuehren
#    --reinstall       automatisch gefundenen Installer auch ausfuehren, wenn
#                      EMU PRO schon installiert ist (ein als Parameter
#                      angegebener Installer wird IMMER ausgefuehrt -> Update)
#    --serial NR       Adapter-Seriennummer vorgeben (sonst automatisch erkannt)
#    --com N           erste COM-Nummer (Standard: 33, max. 99)
#    --skip-install    Schritte 1-4 ueberspringen (nur Patch + Adapter)
#    -h, --help        Hilfe
#
#  Idempotent: kann beliebig oft erneut ausgefuehrt werden (z.B. nach einem
#  EMU-PRO-Update, das die gepatchte DLL ueberschreibt, oder fuer einen
#  weiteren Adapter).
# =============================================================================
set -euo pipefail

PREFIX="${WINEPREFIX:-$HOME/.wine}"
INSTALLER=""
SILENT=0
REINSTALL=0
SKIP_INSTALL=0
SERIALS=()
COM_START=33

c_info()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
c_ok()    { printf '\e[1;32m ✔\e[0m  %s\n' "$*"; }
c_warn()  { printf '\e[1;33m !\e[0m  %s\n' "$*"; }
die()     { printf '\e[1;31m ✘  %s\e[0m\n' "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "$0" | sed 's/^#\s\{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)       PREFIX="$2"; shift 2 ;;
    --silent)       SILENT=1; shift ;;
    --reinstall)    REINSTALL=1; shift ;;
    --serial)       SERIALS+=("$2"); shift 2 ;;
    --com)          COM_START="$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    -h|--help)      usage ;;
    -*)             die "Unbekannte Option: $1" ;;
    *)              INSTALLER="$1"; REINSTALL=1; shift ;;
  esac
done

[[ $EUID -eq 0 ]] && die "Bitte NICHT als root ausfuehren (sudo wird bei Bedarf selbst aufgerufen)."
command -v python3 >/dev/null || die "python3 wird benoetigt."

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG=-all
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EMU_DIR="$PREFIX/drive_c/Program Files (x86)/Ecumaster/EMU PRO"
DLL="$EMU_DIR/EUSB2CAN.dll"

# -----------------------------------------------------------------------------
# 1. Wine
# -----------------------------------------------------------------------------
install_wine() {
  if command -v wine >/dev/null; then
    c_ok "Wine vorhanden: $(wine --version 2>/dev/null)"
    return
  fi
  c_info "Wine ist nicht installiert."
  if command -v apt-get >/dev/null; then
    c_info "Installiere Wine via apt (sudo-Passwort wird abgefragt) ..."
    sudo dpkg --add-architecture i386
    sudo apt-get update
    sudo apt-get install -y wine wine64 wine32:i386
    c_ok "Wine installiert: $(wine --version)"
  else
    die "Kein apt gefunden. Bitte Wine (inkl. 32-bit-Unterstuetzung) manuell installieren und Skript erneut starten."
  fi
}

# -----------------------------------------------------------------------------
# 2. dialout-Gruppe
# -----------------------------------------------------------------------------
NEED_RELOGIN=0
ensure_dialout() {
  if id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
    c_ok "Benutzer ist in Gruppe 'dialout'."
  else
    c_info "Fuege $USER zur Gruppe 'dialout' hinzu (fuer Zugriff auf /dev/ttyACM*) ..."
    sudo usermod -aG dialout "$USER"
    NEED_RELOGIN=1
    c_warn "Gruppe hinzugefuegt - wird erst nach Ab-/Anmelden (oder Neustart) wirksam."
  fi
}

# -----------------------------------------------------------------------------
# 3./4. Prefix + EMU PRO
# -----------------------------------------------------------------------------
find_installer() {
  [[ -n "$INSTALLER" ]] && return
  local cand
  cand=$(ls -1t "$SCRIPT_DIR"/EMU_PRO_Setup*.exe "$HOME"/Downloads/EMU_PRO_Setup*.exe 2>/dev/null | head -1 || true)
  [[ -n "$cand" ]] && INSTALLER="$cand"
}

install_emu_pro() {
  if [[ ! -d "$PREFIX/drive_c" ]]; then
    c_info "Lege Wine-Prefix an: $PREFIX"
    wineboot --init >/dev/null 2>&1 || true
    wineserver -w
  fi
  c_ok "Wine-Prefix: $PREFIX"

  if [[ -f "$EMU_DIR/EMU_PRO.exe" && $REINSTALL -eq 0 ]]; then
    c_ok "EMU PRO ist bereits installiert (fuer Update: Installer-EXE als Parameter angeben)."
    return
  fi
  find_installer
  [[ -n "$INSTALLER" && -f "$INSTALLER" ]] || die "EMU-PRO-Installer nicht gefunden. Pfad angeben: $0 /pfad/EMU_PRO_Setup_xxx.exe"
  c_info "Starte EMU-PRO-Installer: $(basename "$INSTALLER")"
  if [[ $SILENT -eq 1 ]]; then
    wine "$INSTALLER" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- >/dev/null 2>&1 || true
  else
    c_warn "Bitte den Installer durchklicken. Einen angebotenen USB-Treiber kannst du ueberspringen - unter Wine wird er nicht benutzt."
    wine "$INSTALLER" >/dev/null 2>&1 || true
  fi
  wineserver -w
  [[ -f "$EMU_DIR/EMU_PRO.exe" ]] || die "Installation fehlgeschlagen: $EMU_DIR/EMU_PRO.exe fehlt."
  c_ok "EMU PRO installiert."
}

# -----------------------------------------------------------------------------
# 5. EUSB2CAN.dll patchen
#    Original:  SetCommTimeouts(ReadInterval=MAXDWORD, ReadMult=MAXDWORD, ReadConst=100)
#    Gepatcht:  SetCommTimeouts(ReadInterval=MAXDWORD, ReadMult=0,        ReadConst=0)
#    Wine 9 schliesst ReadFileEx() bei der Original-Kombination erst nach vollem
#    Puffer ab -> Versionsabfrage des Adapters laeuft in Timeout (GET_VER_ERR).
# -----------------------------------------------------------------------------
patch_dll() {
  [[ -f "$DLL" ]] || die "$DLL nicht gefunden."
  wineserver -k >/dev/null 2>&1 || true
  python3 -I - "$DLL" <<'PY'
import re, sys, shutil, os
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
# mov [ebp+a],-1 ; (<=16 B) ; mov [ebp+a+4],M ; (<=16 B) ; mov [ebp+a+8],C
pat = re.compile(rb'\xc7\x45(.)\xff\xff\xff\xff.{0,16}?\xc7\x45(.)(....).{0,16}?\xc7\x45(.)(....)', re.S)
orig, done = [], []
for m in pat.finditer(bytes(d)):
    a, b, mult, c, const = m.group(1)[0], m.group(2)[0], m.group(3), m.group(4)[0], m.group(5)
    if b != (a + 4) & 0xff or c != (a + 8) & 0xff:
        continue
    if mult == b'\xff\xff\xff\xff' and const == b'\x64\x00\x00\x00':
        orig.append((m.start(3), m.start(5)))
    elif mult == b'\0\0\0\0' and const == b'\0\0\0\0':
        done.append(m)
if len(orig) == 1:
    bak = p + '.orig'
    if not os.path.exists(bak):
        shutil.copy2(p, bak)
    m_off, c_off = orig[0]
    d[m_off:m_off + 4] = b'\0\0\0\0'
    d[c_off:c_off + 4] = b'\0\0\0\0'
    open(p, 'wb').write(d)
    print('PATCHED')
elif not orig and done:
    print('ALREADY')
else:
    print('NOTFOUND %d %d' % (len(orig), len(done)))
PY
}

# -----------------------------------------------------------------------------
# 6. Adapter in Registry
# -----------------------------------------------------------------------------
detect_serials() {
  [[ ${#SERIALS[@]} -gt 0 ]] && return
  local i
  for i in $(seq 1 60); do
    mapfile -t SERIALS < <(ls /dev/serial/by-id/ 2>/dev/null | sed -nE 's/^usb-ECUMASTER_ECUMASTER_USB2CAN_([^-]+)-if00$/\1/p')
    [[ ${#SERIALS[@]} -gt 0 ]] && return
    [[ $i -eq 1 ]] && c_warn "Kein USB2CAN-Adapter gefunden - bitte jetzt anstecken (warte 60 s) ..."
    sleep 1
  done
  die "Kein Adapter erkannt. Pruefen: 'lsusb' muss '0483:5740' zeigen. Alternativ --serial NR angeben."
}

register_adapters() {
  local scratch reg com serial byid key
  scratch=$(mktemp -d)
  reg="$scratch/usb2can.reg"
  com=$COM_START

  wineserver -k >/dev/null 2>&1 || true; wineserver -w
  cp "$PREFIX/system.reg" "$PREFIX/system.reg.bak-usb2can-$(date +%Y%m%d%H%M%S)"

  {
    printf 'Windows Registry Editor Version 5.00\r\n\r\n'
    for serial in "${SERIALS[@]}"; do
      [[ $com -le 99 ]] || die "COM-Nummer > 99 wird von der DLL nicht unterstuetzt."
      byid="/dev/serial/by-id/usb-ECUMASTER_ECUMASTER_USB2CAN_${serial}-if00"
      key="HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Enum\\USB\\VID_0483&PID_5740\\${serial}"
      python3 -I - "$key" "COM$com" "$byid" <<'PY'
import sys
key, port, byid = sys.argv[1:4]
def hexs(s, t):
    return 'hex(%x):' % t + ','.join('%02x' % c for c in (s + '\0').encode('utf-16-le'))
L = [
 r'[HKEY_LOCAL_MACHINE\Software\Wine\Ports]',
 '"%s"="%s"' % (port, byid), '',
 '[%s]' % key,
 '"ClassGUID"="{4d36e978-e325-11ce-bfc1-08002be10318}"',
 '"Class"="Ports"',
 '"DeviceDesc"="STMicroelectronics Virtual COM Port"',
 '"FriendlyName"="STMicroelectronics Virtual COM Port (%s)"' % port,
 '"Mfg"="STMicroelectronics"',
 '"HardwareID"=hex(7):' + ','.join('%02x' % c for c in 'USB\\VID_0483&PID_5740\0\0'.encode('utf-16-le')),
 '"Service"="usbser"', '',
 r'[%s\Device Parameters]' % key,
 '"PortName"="%s"' % port, '',
 # DEVPKEY_Device_BusReportedDeviceDesc (DEVPROP_TYPE_STRING = 0x12)
 r'[%s\Properties\{540b947e-8b40-45bc-a8a2-6a0b894cbda2}\0004]' % key,
 '@=' + hexs('ECUMASTER USB2CAN', 0x12), '',
 # DEVPKEY_Device_DevNodeStatus / ProblemCode (DEVPROP_TYPE_UINT32 = 7) - Groesse wird unten korrigiert
 r'[%s\Properties\{4340a6c5-93fa-4706-972c-7b648008a5a7}\0002]' % key,
 '@=hex(7):0a,20,80,01', '',
 r'[%s\Properties\{4340a6c5-93fa-4706-972c-7b648008a5a7}\0003]' % key,
 '@=hex(7):00,00,00,00', '',
]
sys.stdout.write('\r\n'.join(L) + '\r\n')
PY
      c_ok "Adapter $serial -> COM$com" >&2
      com=$((com + 1))
    done
  } | iconv -t UTF-16 > "$reg"

  wine regedit /S "$reg" >/dev/null 2>&1
  wineserver -k >/dev/null 2>&1 || true; wineserver -w

  # regedit haengt an Typ-7-Werte einen Terminator an (6 statt 4 Byte) ->
  # SetupDiGetDevicePropertyW liefert dann ERROR_MORE_DATA. Direkt in system.reg korrigieren.
  python3 -I - "$PREFIX/system.reg" <<'PY'
import re, sys
p = sys.argv[1]
txt = open(p, encoding='utf-8', errors='surrogateescape').read()
fix = {'0002': '@=hex(7):0a,20,80,01', '0003': '@=hex(7):00,00,00,00'}
out, cur, n = [], None, 0
for line in txt.split('\n'):
    if line.startswith('['):
        m = re.search(r'VID_0483&PID_5740\\\\[^\\]+\\\\Properties\\\\\{4340a6c5-93fa-4706-972c-7b648008a5a7\}\\\\(000[23])\]', line, re.I)
        cur = m.group(1) if m else None
    elif cur and line.startswith('@='):
        if line != fix[cur]:
            line = fix[cur]; n += 1
    out.append(line)
open(p, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))

PY
  rm -rf "$scratch"
  c_ok "Registry-Eintraege gesetzt."
}

# -----------------------------------------------------------------------------
main() {
  echo
  c_info "EMU PRO + USB2CAN unter Wine einrichten"
  if [[ $SKIP_INSTALL -eq 0 ]]; then
    install_wine
    ensure_dialout
    install_emu_pro
  else
    command -v wine >/dev/null || die "Wine fehlt."
    [[ -f "$DLL" ]] || die "EMU PRO nicht gefunden in $EMU_DIR"
  fi

  c_info "Patche EUSB2CAN.dll ..."
  case "$(patch_dll)" in
    PATCHED)  c_ok "DLL gepatcht (Original: EUSB2CAN.dll.orig)." ;;
    ALREADY)  c_ok "DLL ist bereits gepatcht." ;;
    *)        die "Patch-Muster in EUSB2CAN.dll nicht gefunden (andere EMU-PRO-Version?). Abbruch." ;;
  esac

  c_info "Suche USB2CAN-Adapter ..."
  detect_serials
  register_adapters

  echo
  c_ok "Fertig. EMU PRO ganz normal starten."
  [[ $NEED_RELOGIN -eq 1 ]] && c_warn "WICHTIG: Einmal ab- und wieder anmelden (dialout-Gruppe), sonst kein Zugriff auf den Adapter."
  return 0
}
main
