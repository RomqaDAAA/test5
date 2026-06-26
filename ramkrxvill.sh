#!/usr/bin/env bash
# Keryx miner launcher — OPTIMIZED kernel (~+15% hashrate vs stock).
#
# Downloads the prebuilt miner + an optimized libkeryxcuda.so (register-resident
# Keccak-f1600 with explicit EOR3/BCAX), installs missing CUDA runtime libs,
# asks for your wallet, and runs mining in a tmux session.
#
# The optimized .so is ALWAYS enforced — even over a pre-existing stock install.
#
#   sudo bash keryx_menu.sh           # install/refresh + start mining (optimized)
#   sudo bash keryx_menu.sh stop      # stop mining
#   sudo bash keryx_menu.sh logs      # follow miner log
#   sudo bash keryx_menu.sh doctor    # diagnostics (.so size, driver, CUDA libs)
#
# Requires: Linux (Ubuntu) + NVIDIA driver >= 570.
set -u

REPO_RAW="https://raw.githubusercontent.com/VaniaHilkovets/keryx-menu/main"
MINER_VER="v0.3.3-OPoI"
MINER_ZIP="https://github.com/Keryx-Labs/keryx-miner/releases/download/${MINER_VER}/keryx-miner-${MINER_VER}-linux-gnu-amd64.zip"
DIR="/opt/keryx-miner"
WALLET_FILE="$DIR/wallet.txt"
VER_FILE="$DIR/.miner_version"
SESSION="keryx"
NODE="192.168.1.38"       # standard node (used automatically)
PORT="22110"
LDPATH=".:/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib"
OPT_SO_MIN=6000000      # optimized .so ~10.2MB; stock ~4.3MB — used to tell them apart

need_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash keryx_menu.sh"; exit 1; }; }

check_driver() {
  command -v nvidia-smi >/dev/null 2>&1 || { echo "!! nvidia-smi not found — install the NVIDIA driver first."; return; }
  local dv; dv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  local major=${dv%%.*}
  echo "NVIDIA driver: $dv"
  if [ -n "$major" ] && [ "$major" -lt 570 ] 2>/dev/null; then
    echo "!! Driver $dv < 570 — optimized PTX may not load. Update: sudo apt install nvidia-driver-570 (+ reboot)."
  fi
}

ensure_cuda() {
  cd "$DIR" || return
  if ! LD_LIBRARY_PATH="$LDPATH" ldd libkeryxcuda.so 2>/dev/null | grep -qi 'not found'; then
    echo "CUDA runtime: OK"; return
  fi
  echo "CUDA runtime libs missing — installing (cublas/curand/nvrtc/cudart)..."
  export DEBIAN_FRONTEND=noninteractive
  local distro="ubuntu2404"
  [ -r /etc/os-release ] && { . /etc/os-release; distro="ubuntu${VERSION_ID//./}"; }
  if ! ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi cuda; then
    wget -qO /tmp/cuda-keyring.deb "https://developer.download.nvidia.com/compute/cuda/repos/${distro}/x86_64/cuda-keyring_1.1-1_all.deb" \
      && dpkg -i /tmp/cuda-keyring.deb
  fi
  apt-get update -y >/dev/null 2>&1
  apt-get install -y cuda-libraries-12-8 >/dev/null 2>&1 \
    || apt-get install -y cuda-libraries-12-6 >/dev/null 2>&1 \
    || apt-get install -y cuda-cudart-12-8 libcublas-12-8 libcurand-12-8 cuda-nvrtc-12-8 >/dev/null 2>&1 \
    || apt-get install -y cuda-toolkit >/dev/null 2>&1
  ldconfig
  LD_LIBRARY_PATH="$LDPATH" ldd libkeryxcuda.so 2>/dev/null | grep -qi 'not found' \
    && { echo "!! CUDA libs still missing:"; LD_LIBRARY_PATH="$LDPATH" ldd libkeryxcuda.so | grep -i 'not found'; } \
    || echo "CUDA runtime: installed OK"
}

# Always make sure the OPTIMIZED kernel is in place (overwrites a stock .so).
ensure_optimized_so() {
  cd "$DIR" || return
  local sz; sz=$(stat -c%s libkeryxcuda.so 2>/dev/null || echo 0)
  if [ "$sz" -ge "$OPT_SO_MIN" ]; then
    echo "Optimized kernel already in place ($sz bytes)."; return
  fi
  echo "Installing OPTIMIZED kernel (current .so is stock/missing, $sz bytes)..."
  wget -qO libkeryxcuda.so.new "$REPO_RAW/libkeryxcuda.so"
  local nsz; nsz=$(stat -c%s libkeryxcuda.so.new 2>/dev/null || echo 0)
  if [ "$nsz" -ge "$OPT_SO_MIN" ]; then
    mv -f libkeryxcuda.so.new libkeryxcuda.so
    echo "Optimized kernel installed ($nsz bytes)."
  else
    rm -f libkeryxcuda.so.new
    echo "!! Download failed ($nsz bytes) — kept existing .so. Check internet/repo."
  fi
}

install() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1
  apt-get install -y wget unzip tmux ca-certificates >/dev/null 2>&1
  mkdir -p "$DIR"; cd "$DIR" || exit 1

  # (Re)download the miner if it's missing OR the installed version differs
  # from MINER_VER above. This is what makes bumping MINER_VER actually
  # pull the new release instead of silently reusing an old binary.
  local cur_ver=""
  [ -f "$VER_FILE" ] && cur_ver="$(cat "$VER_FILE" 2>/dev/null)"
  if [ ! -x keryx-miner ] || [ "$cur_ver" != "$MINER_VER" ]; then
    echo "Downloading miner $MINER_VER (official release)..."
    rm -f keryx-miner
    wget -qO miner.zip "$MINER_ZIP" && unzip -oq miner.zip && rm -f miner.zip
    chmod +x keryx-miner
    echo "$MINER_VER" > "$VER_FILE"
  else
    echo "Miner already at $MINER_VER — skipping download."
  fi
  ensure_optimized_so
  check_driver
  ensure_cuda
}

get_wallet() {
  if [ -s "$WALLET_FILE" ]; then cat "$WALLET_FILE"; return; fi
  local w=""
  while [ -z "$w" ]; do
    printf "Enter your Keryx wallet address (keryx:...): " > /dev/tty
    read -r w < /dev/tty
  done
  printf "%s\n" "$w" > "$WALLET_FILE"; chmod 600 "$WALLET_FILE"
  printf "%s\n" "$w"
}

start() {
  need_root
  install                      # ensures miner + OPTIMIZED .so on disk

  # always (re)launch so the optimized kernel is actually loaded into the miner
  tmux kill-session -t "$SESSION" 2>/dev/null
  pkill -9 -x keryx-miner 2>/dev/null
  sleep 1

  local wallet; wallet="$(get_wallet)"
  tmux new-session -d -s "$SESSION" \
    "cd $DIR && LD_LIBRARY_PATH=$LDPATH ./keryx-miner -s $NODE -p $PORT -a $wallet --light 2>&1 | tee -a $DIR/miner.log"

  echo
  echo "Mining started in tmux session '$SESSION' ($MINER_VER, OPTIMIZED kernel)."
  echo "  attach: tmux attach -t $SESSION   (detach: Ctrl+B then D)"
  echo "  logs  : sudo bash keryx_menu.sh logs     stop: sudo bash keryx_menu.sh stop"
}

stop() {
  need_root
  tmux kill-session -t "$SESSION" 2>/dev/null
  pkill -9 -x keryx-miner 2>/dev/null
  echo "Mining stopped."
}

logs() {
  [ -f "$DIR/miner.log" ] || { echo "No log yet — start mining first."; exit 0; }
  tail -n 60 -f "$DIR/miner.log"
}

doctor() {
  cd "$DIR" 2>/dev/null || { echo "Not installed yet."; exit 0; }
  echo "Configured MINER_VER: $MINER_VER"
  echo "Installed version   : $(cat "$VER_FILE" 2>/dev/null || echo unknown)"
  local sz; sz=$(stat -c%s libkeryxcuda.so 2>/dev/null || echo 0)
  if [ "$sz" -ge "$OPT_SO_MIN" ]; then echo ".so: $sz bytes  -> OPTIMIZED"; else echo ".so: $sz bytes  -> STOCK/missing (run 'start' to fix)"; fi
  check_driver
  LD_LIBRARY_PATH="$LDPATH" ldd libkeryxcuda.so 2>/dev/null | grep -i 'not found' || echo "CUDA deps: OK"
  command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,power.draw,power.limit,clocks.sm --format=csv,noheader
}

case "${1:-start}" in
  install) install ;;
  start)   start ;;
  stop)    stop ;;
  logs)    logs ;;
  restart) stop; sleep 2; start ;;
  doctor)  doctor ;;
  *) echo "Usage: sudo bash keryx_menu.sh [start|stop|logs|restart|install|doctor]"; exit 1 ;;
esac
