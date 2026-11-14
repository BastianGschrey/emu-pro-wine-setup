#!/usr/bin/env bash
# =============================================================================
#  Set up EMU PRO (Ecumaster) + USB2CAN adapter under Wine
#
#  Steps:
#    1. Install Wine (Debian/Ubuntu via apt, if not present)
#    2. Add user to group "dialout" (access to /dev/ttyACM*)
#    3. Create Wine prefix
#    4. Install EMU PRO (installer EXE)
#    5. Patch EUSB2CAN.dll (serial read timeouts, otherwise Wine 9 hangs on read)
#    6. Register USB2CAN adapter in the Wine registry (fake device entry + COM port)
#
#  Usage:
#    ./emu-pro-wine-setup.sh [options] [EMU_PRO_Setup_xxx.exe]
#
#  Options:
#    --prefix DIR      Wine prefix (default: $WINEPREFIX or ~/.wine)
#    --silent          run installer without dialogs
#    --reinstall       run an auto-detected installer even if EMU PRO is
#                      already installed (an installer passed as argument
#                      is ALWAYS run -> update)
#    --serial NR       adapter serial number (otherwise detected automatically)
#    --com N           first COM port number (default: 33, max. 99)
#    --skip-install    skip steps 1-4 (patch + adapter only)
#    -h, --help        show this help
#
#  Idempotent: can be re-run any number of times (e.g. after an EMU PRO
#  update that overwrites the patched DLL, or for an additional adapter).
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

usage() { sed -n '3,/^# ====/p' "$0" | sed '$d; s/^#\s\{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)       PREFIX="$2"; shift 2 ;;
    --silent)       SILENT=1; shift ;;
    --reinstall)    REINSTALL=1; shift ;;
    --serial)       SERIALS+=("$2"); shift 2 ;;
    --com)          COM_START="$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    -h|--help)      usage ;;
    -*)             die "Unknown option: $1" ;;
    *)              INSTALLER="$1"; REINSTALL=1; shift ;;
  esac
done

[[ $EUID -eq 0 ]] && die "Do NOT run as root (sudo is invoked automatically when needed)."
command -v python3 >/dev/null || die "python3 is required."

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
    c_ok "Wine found: $(wine --version 2>/dev/null)"
    return
  fi
  c_info "Wine is not installed."
  if command -v apt-get >/dev/null; then
    c_info "Installing Wine via apt (you will be asked for your sudo password) ..."
    sudo dpkg --add-architecture i386
    sudo apt-get update
    sudo apt-get install -y wine wine64 wine32:i386
    c_ok "Wine installed: $(wine --version)"
  else
    die "apt not found. Please install Wine (incl. 32-bit support) manually and run the script again."
  fi
}

# -----------------------------------------------------------------------------
# 2. dialout group
# -----------------------------------------------------------------------------
NEED_RELOGIN=0
ensure_dialout() {
  if id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
    c_ok "User is in group 'dialout'."
  else
    c_info "Adding $USER to group 'dialout' (for access to /dev/ttyACM*) ..."
    sudo usermod -aG dialout "$USER"
    NEED_RELOGIN=1
    c_warn "Group added - takes effect only after logging out/in (or reboot)."
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
    c_info "Creating Wine prefix: $PREFIX"
    wineboot --init >/dev/null 2>&1 || true
    wineserver -w
  fi
  c_ok "Wine prefix: $PREFIX"

  if [[ -f "$EMU_DIR/EMU_PRO.exe" && $REINSTALL -eq 0 ]]; then
    c_ok "EMU PRO is already installed (to update: pass the installer EXE as argument)."
    return
  fi
  find_installer
  [[ -n "$INSTALLER" && -f "$INSTALLER" ]] || die "EMU PRO installer not found. Specify path: $0 /path/EMU_PRO_Setup_xxx.exe"
  c_info "Starting EMU PRO installer: $(basename "$INSTALLER")"
  if [[ $SILENT -eq 1 ]]; then
    wine "$INSTALLER" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- >/dev/null 2>&1 || true
  else
    c_warn "Please click through the installer. You can skip the offered USB driver - it is not used under Wine."
    wine "$INSTALLER" >/dev/null 2>&1 || true
  fi
  wineserver -w
  [[ -f "$EMU_DIR/EMU_PRO.exe" ]] || die "Installation failed: $EMU_DIR/EMU_PRO.exe is missing."
  c_ok "EMU PRO installed."
}

# -----------------------------------------------------------------------------
# 5. Patch EUSB2CAN.dll
#    Original:  SetCommTimeouts(ReadInterval=MAXDWORD, ReadMult=MAXDWORD, ReadConst=100)
#    Patched:   SetCommTimeouts(ReadInterval=MAXDWORD, ReadMult=0,        ReadConst=0)
#    With the original combination Wine 9 completes ReadFileEx() only once the
#    buffer is full -> adapter version query times out (GET_VER_ERR).
# -----------------------------------------------------------------------------
patch_dll() {
  [[ -f "$DLL" ]] || die "$DLL not found."
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
# 6. Adapter in registry
# -----------------------------------------------------------------------------
detect_serials() {
  [[ ${#SERIALS[@]} -gt 0 ]] && return
  local i
  for i in $(seq 1 60); do
    mapfile -t SERIALS < <(ls /dev/serial/by-id/ 2>/dev/null | sed -nE 's/^usb-ECUMASTER_ECUMASTER_USB2CAN_([^-]+)-if00$/\1/p')
    [[ ${#SERIALS[@]} -gt 0 ]] && return
    [[ $i -eq 1 ]] && c_warn "No USB2CAN adapter found - please plug it in now (waiting 60 s) ..."
    sleep 1
  done
  die "No adapter detected. Check: 'lsusb' must show '0483:5740'. Alternatively pass --serial NR."
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
      [[ $com -le 99 ]] || die "COM port number > 99 is not supported by the DLL."
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
 # DEVPKEY_Device_DevNodeStatus / ProblemCode (DEVPROP_TYPE_UINT32 = 7) - size is fixed below
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

  # regedit appends a terminator to type-7 values (6 instead of 4 bytes) ->
  # SetupDiGetDevicePropertyW then returns ERROR_MORE_DATA. Fix directly in system.reg.
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
  c_ok "Registry entries written."
}

# -----------------------------------------------------------------------------
main() {
  echo
  c_info "Setting up EMU PRO + USB2CAN under Wine"
  if [[ $SKIP_INSTALL -eq 0 ]]; then
    install_wine
    ensure_dialout
    install_emu_pro
  else
    command -v wine >/dev/null || die "Wine is missing."
    [[ -f "$DLL" ]] || die "EMU PRO not found in $EMU_DIR"
  fi

  c_info "Patching EUSB2CAN.dll ..."
  case "$(patch_dll)" in
    PATCHED)  c_ok "DLL patched (original: EUSB2CAN.dll.orig)." ;;
    ALREADY)  c_ok "DLL is already patched." ;;
    *)        die "Patch pattern not found in EUSB2CAN.dll (different EMU PRO version?). Aborting." ;;
  esac

  c_info "Looking for USB2CAN adapter ..."
  detect_serials
  register_adapters

  echo
  c_ok "Done. Start EMU PRO as usual."
  [[ $NEED_RELOGIN -eq 1 ]] && c_warn "IMPORTANT: Log out and back in once (dialout group), otherwise no access to the adapter."
  return 0
}
main
