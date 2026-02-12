#!/usr/bin/env bash
# Disk Health Check — компактная таблица SMART + (опционально) fio 4k тест по каждому диску
# Опции:
#   --fio        добавить короткий 4k randrw (50/50) тест по каждому диску (по /dev/nvmeXnY, /dev/sdX и т.п.)
#   --seconds N  длительность fio теста (по умолчанию 8 сек)
#   --jobs N     numjobs для fio (по умолчанию 4)
#   --iodepth N  iodepth для fio (по умолчанию 32)

set -u
export LC_ALL=C

DO_FIO=0
FIO_SECONDS=8
FIO_JOBS=4
FIO_IODEPTH=32

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fio) DO_FIO=1; shift ;;
    --seconds) FIO_SECONDS="${2:-8}"; shift 2 ;;
    --jobs) FIO_JOBS="${2:-4}"; shift 2 ;;
    --iodepth) FIO_IODEPTH="${2:-32}"; shift 2 ;;
    *) shift ;;
  esac
done

need(){ command -v "$1" >/dev/null 2>&1; }
trim(){ sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'; }

if [[ $EUID -ne 0 ]]; then
  echo "Запусти: sudo $0 [--fio] [--seconds N] [--jobs N] [--iodepth N]"
  exit 1
fi

# deps
if ! need smartctl; then
  echo "[*] smartctl не найден. Устанавливаю smartmontools..."
  if need apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y smartmontools >/dev/null 2>&1 || true
  fi
fi
if ! need smartctl; then
  echo "[!] smartctl не найден (нужен пакет smartmontools)."
  exit 1
fi

if [[ $DO_FIO -eq 1 ]] && ! need fio; then
  echo "[*] fio не найден. Устанавливаю fio..."
  if need apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y fio >/dev/null 2>&1 || true
  fi
fi
if [[ $DO_FIO -eq 1 ]] && ! need fio; then
  echo "[!] fio не найден. Установи пакет fio или запусти без --fio."
  exit 1
fi

# NVMe field helper (smartctl -a output)
nvme_field(){ echo "$1" | awk -F: -v r="$2" '$0 ~ r {print $2; exit}' | trim; }

# disks list (all physical disks)
mapfile -t DISKS < <(
  lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -Ev '^(loop|ram|sr|fd)$'
)

echo "===================="
echo "DISK INVENTORY (lsblk)"
echo "===================="
lsblk -d -o NAME,TYPE,MODEL,SERIAL,SIZE,ROTA,TRAN | awk 'NR==1{print} NR>1 && $2=="disk"{print}'
echo
echo "Найдено дисков: ${#DISKS[@]}"
echo

fio_4k_line() {
  # Outputs: rdMB wrMB rdIOPS wrIOPS (one line)
  local devpath="$1"
  local out
  out="$(fio --name=sol4k \
    --filename="$devpath" \
    --ioengine=libaio --direct=1 --randrepeat=0 --norandommap=1 \
    --rw=randrw --rwmixread=50 --bs=4k \
    --iodepth="$FIO_IODEPTH" --numjobs="$FIO_JOBS" \
    --time_based=1 --runtime="$FIO_SECONDS" \
    --group_reporting=1 \
    --output-format=json 2>/dev/null || true)"

  python3 - <<'PY' "$out"
import json, sys
s = sys.argv[1]
if not s.strip():
    print("— — — —"); sys.exit(0)
try:
    j = json.loads(s)
except Exception:
    print("— — — —"); sys.exit(0)

jobs = j.get("jobs", [])
rd_bw = wr_bw = rd_iops = wr_iops = 0.0
for jb in jobs:
    r = jb.get("read", {})
    w = jb.get("write", {})
    rd_bw += float(r.get("bw_bytes", 0.0))
    wr_bw += float(w.get("bw_bytes", 0.0))
    rd_iops += float(r.get("iops", 0.0))
    wr_iops += float(w.get("iops", 0.0))

rd_mb = rd_bw / 1_000_000
wr_mb = wr_bw / 1_000_000

def fmt_mb(x): return "—" if x <= 0 else f"{x:.0f}"
def fmt_iops(x): return "—" if x <= 0 else (f"{x/1000:.1f}k" if x >= 1000 else f"{x:.0f}")

print(fmt_mb(rd_mb), fmt_mb(wr_mb), fmt_iops(rd_iops), fmt_iops(wr_iops))
PY
}

# headers
if [[ $DO_FIO -eq 1 ]]; then
  printf "%-10s %-6s %-22s %-16s %-6s %-5s %-5s %-5s %-6s %-6s %-6s %-7s %-7s\n" \
    "DEV" "TRAN" "MODEL" "SERIAL" "SIZE" "TEMP" "WEAR" "REM" "SPARE" "4K_RD" "4K_WR" "RD_IOPS" "WR_IOPS"
else
  printf "%-10s %-6s %-28s %-18s %-6s %-5s %-5s %-5s %-5s %-8s %-7s %-6s %-6s %-6s\n" \
    "DEV" "TRAN" "MODEL" "SERIAL" "SIZE" "TEMP" "WEAR" "REM" "SPARE" "HEALTH" "POH" "UNSAFE" "MDIE" "ELOG"
fi
echo "--------------------------------------------------------------------------------------------------------------------------------"

for d in "${DISKS[@]}"; do
  dev="/dev/$d"
  tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null | head -n1 | trim || true)"
  model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | head -n1 | trim || true)"
  serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null | head -n1 | trim || true)"
  size="$(lsblk -dn -o SIZE "$dev" 2>/dev/null | head -n1 | trim || true)"

  out="$(smartctl -a "$dev" 2>&1 || true)"

  health="$(echo "$out" | awk -F: '
    /SMART overall-health self-assessment test result/ {print $2; exit}
    /SMART Health Status/ {print $2; exit}
  ' | trim)"
  [[ -z "$health" ]] && health="unknown"

  temp="—"; wear="—"; rem="—"; spare="—"
  poh="—"; unsafe="—"; mdie="—"; elog="—"

  if [[ "$tran" == "nvme" || "$d" == nvme* ]]; then
    t0="$(nvme_field "$out" "^Temperature")"
    [[ -n "$t0" ]] && temp="$(echo "$t0" | sed 's/ Celsius//; s/$/C/')"

    wear_raw="$(nvme_field "$out" "Percentage Used")"
    wear="$(echo "${wear_raw:-—}" | tr -d ' ')"
    if [[ "$wear" =~ ^[0-9]+%$ ]]; then
      w="${wear%\%}"
      rem="$((100 - w))%"
    fi

    spare_raw="$(nvme_field "$out" "Available Spare")"
    spare="$(echo "${spare_raw:-—}" | tr -d ' ')"

    poh="$(nvme_field "$out" "Power On Hours")"
    unsafe="$(nvme_field "$out" "Unsafe Shutdowns")"
    mdie="$(nvme_field "$out" "Media and Data Integrity Errors")"
    elog="$(nvme_field "$out" "Error Information Log Entries")"
  fi

  if [[ $DO_FIO -eq 1 ]]; then
    read -r rdMB wrMB rdIOPS wrIOPS < <(fio_4k_line "$dev")
    printf "%-10s %-6s %-22s %-16s %-6s %-5s %-5s %-5s %-6s %-6s %-6s %-7s %-7s\n" \
      "$dev" "${tran:-—}" "$(echo "${model:-—}" | cut -c1-22)" "$(echo "${serial:-—}" | cut -c1-16)" "${size:-—}" \
      "${temp:-—}" "${wear:-—}" "${rem:-—}" "${spare:-—}" \
      "${rdMB:-—}" "${wrMB:-—}" "${rdIOPS:-—}" "${wrIOPS:-—}"
  else
    printf "%-10s %-6s %-28s %-18s %-6s %-5s %-5s %-5s %-5s %-8s %-7s %-6s %-6s %-6s\n" \
      "$dev" "${tran:-—}" "$(echo "${model:-—}" | cut -c1-28)" "$(echo "${serial:-—}" | cut -c1-18)" "${size:-—}" \
      "${temp:-—}" "${wear:-—}" "${rem:-—}" "${spare:-—}" \
      "${health:-—}" "${poh:-—}" "${unsafe:-—}" "${mdie:-—}" "${elog:-—}"
  fi
done

echo
if [[ $DO_FIO -eq 0 ]]; then
  echo "Добавить короткий 4k fio-тест (без YABS простыни):"
  echo "  sudo $0 --fio"
fi
