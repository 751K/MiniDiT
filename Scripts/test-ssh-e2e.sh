#!/bin/bash
# SSH 访问身份验证端到端测试：模拟索尼相机 + 模拟相机 SSH 服务（键盘交互、aes128-ctr）+ ssh-e2e。
# 需要装了 paramiko 的 Python：PYTHON=/path/to/python Scripts/test-ssh-e2e.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PYTHON="${PYTHON:-python3}"
"$PYTHON" -c "import paramiko" 2>/dev/null || { echo "需要 paramiko：$PYTHON -m pip install paramiko"; exit 2; }

swift build --product fake-sony-camera >/dev/null
swift build --product ssh-e2e >/dev/null
BIN="$(swift build --show-bin-path)"

CAM_PORT=$(( 20000 + RANDOM % 20000 ))
LOG="$(mktemp -d)"
"$BIN/fake-sony-camera" "$CAM_PORT" >"$LOG/camera.log" 2>&1 &
CAM_PID=$!
FORWARD_PORT="$CAM_PORT" "$PYTHON" -u Scripts/ssh-test-server.py camuser 's3cret-Pw' >"$LOG/sshd.log" 2>&1 &
SSHD_PID=$!
trap 'kill $CAM_PID $SSHD_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do grep -q READY "$LOG/sshd.log" && break; sleep 0.1; done
for _ in $(seq 1 100); do grep -q "已启动" "$LOG/camera.log" 2>/dev/null && break; sleep 0.2; done
read -r _ SSH_PORT FP < <(grep READY "$LOG/sshd.log")
echo "SSH 端口 $SSH_PORT，指纹 $FP，模拟相机端口 $CAM_PORT"

"$BIN/ssh-e2e" "$SSH_PORT" camuser 's3cret-Pw' "$FP"
