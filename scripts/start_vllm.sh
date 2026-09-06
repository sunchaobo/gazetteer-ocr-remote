#!/usr/bin/env bash
# 在远程主机（默认 ssh dl）上启动 vllm OCR 服务。
# 流程：
#   1) 探测 /v1/models, 已跑则跳过
#   2) scp scripts/_remote/start_vllm_remote.sh 到远程 EXTRACTORS/scripts/
#   3) ssh 注入环境变量后 bash 远程脚本 (venv 准备 + nohup vllm serve)
#   4) 轮询 /v1/models 等待就绪（默认 600s 超时）
#
# 远程目录:
#   ${REMOTE_EXTRACTORS_BASE}/scripts/   远程 shell 脚本
#   ${REMOTE_EXTRACTORS_BASE}/logs/      vllm 启动日志 (按 engine 分文件)
#
# 环境变量（可选）:
#   REMOTE_HOST                远程主机别名（默认 dl）
#   SERVICE_PORT              服务端口（默认 8000）
#   READY_TIMEOUT             等待就绪的最大秒数（默认 600）
#   REMOTE_EXTRACTORS_BASE    远程 extractors 根
#   REMOTE_LOG_DIR            vllm 日志目录
#   REMOTE_SCRIPTS_DIR        远程 shell 脚本目录
#   REMOTE_VENVS_DIR          venv 父目录
#   REMOTE_VENV_SOURCE        venv 源路径
#   REMOTE_VENV_LINK          venv 软链名
#   HF_ENDPOINT               模型下载 mirror
#   VLLM_ENGINE               引擎 (默认 paddle-ocr-vl; 可选 glm-ocr)

set -euo pipefail

VLLM_ENGINE="${VLLM_ENGINE:-glm-ocr}"

REMOTE_HOST="${REMOTE_HOST:-dl}"
SERVICE_PORT="${SERVICE_PORT:-8000}"
READY_TIMEOUT="${READY_TIMEOUT:-600}"

REMOTE_EXTRACTORS_BASE="${REMOTE_EXTRACTORS_BASE:-/root/autodl-tmp/extractors}"
REMOTE_LOG_DIR="${REMOTE_LOG_DIR:-${REMOTE_EXTRACTORS_BASE}/logs}"
REMOTE_SCRIPTS_DIR="${REMOTE_SCRIPTS_DIR:-${REMOTE_EXTRACTORS_BASE}/scripts}"
REMOTE_VENVS_DIR="${REMOTE_VENVS_DIR:-/root/autodl-tmp/venvs}"
REMOTE_VENV_SOURCE="${REMOTE_VENV_SOURCE:-/root/venvs/vllm-paddle}"
REMOTE_VENV_LINK="${REMOTE_VENV_LINK:-vllm-paddle}"
HF_ENDPOINT_VAL="${HF_ENDPOINT:-https://hf-mirror.com}"

# 按 engine 决定期望的 served-model-name (用于探测)
case "$VLLM_ENGINE" in
  paddle-ocr-vl)
    EXPECTED_MODEL="PaddleOCR-VL-1.6-0.9B"
    ENGINE_TAG="paddle-ocr-vl"
    ;;
  glm-ocr)
    EXPECTED_MODEL="GLM-OCR"
    ENGINE_TAG="glm-ocr"
    ;;
  *)
    echo "[start_vllm] 错误: 未知 VLLM_ENGINE='$VLLM_ENGINE' (可用 paddle-ocr-vl | glm-ocr)" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_ROOT="$(dirname "$SCRIPT_DIR")"
LOCAL_REMOTE_SH="${REMOTE_ROOT}/scripts/_remote/start_vllm_remote.sh"

if [ ! -f "$LOCAL_REMOTE_SH" ]; then
  echo "[start_vllm] 错误: 找不到本地远程脚本 ${LOCAL_REMOTE_SH}" >&2
  exit 1
fi

LOG_PREFIX="[start_vllm]"

probe_service() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" \
    "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${SERVICE_PORT}/v1/models" 2>/dev/null
}

echo "${LOG_PREFIX} 远程主机=${REMOTE_HOST}  端口=${SERVICE_PORT}  engine=${VLLM_ENGINE}  expected_model=${EXPECTED_MODEL}"
echo "${LOG_PREFIX} 远程日志=${REMOTE_LOG_DIR}  远程脚本=${REMOTE_SCRIPTS_DIR}"

status="$(probe_service || true)"
if [ "$status" = "200" ]; then
  echo "${LOG_PREFIX} ${SERVICE_PORT} 已在线, 跳过启动 (注意: 可能是别的 engine 在跑, 请确认 EXPECTED_MODEL)"
  exit 0
fi

echo "${LOG_PREFIX} 准备远程目录"
ssh "$REMOTE_HOST" "mkdir -p '${REMOTE_LOG_DIR}' '${REMOTE_SCRIPTS_DIR}'"

REMOTE_SH_PATH="${REMOTE_SCRIPTS_DIR}/start_vllm_remote.sh"
echo "${LOG_PREFIX} scp 上传远程脚本: ${LOCAL_REMOTE_SH} -> ${REMOTE_HOST}:${REMOTE_SH_PATH}"
scp -q "$LOCAL_REMOTE_SH" "${REMOTE_HOST}:${REMOTE_SH_PATH}"
ssh "$REMOTE_HOST" "chmod +x '${REMOTE_SH_PATH}'"

echo "${LOG_PREFIX} 远程执行启动脚本"
ssh "$REMOTE_HOST" \
  "REMOTE_VENVS_DIR='${REMOTE_VENVS_DIR}' \
   REMOTE_VENV_SOURCE='${REMOTE_VENV_SOURCE}' \
   REMOTE_VENV_LINK='${REMOTE_VENV_LINK}' \
   HF_ENDPOINT_VAL='${HF_ENDPOINT_VAL}' \
   REMOTE_LOG_DIR='${REMOTE_LOG_DIR}' \
   SERVICE_PORT='${SERVICE_PORT}' \
   VLLM_ENGINE='${VLLM_ENGINE}' \
   bash '${REMOTE_SH_PATH}'"

echo "${LOG_PREFIX} 等待服务就绪（超时 ${READY_TIMEOUT}s）..."
deadline=$(( $(date +%s) + READY_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  status="$(probe_service || true)"
  if [ "$status" = "200" ]; then
    # 进一步确认 served model 名匹配
    served=$(ssh -o BatchMode=yes "$REMOTE_HOST" \
      "curl -s http://127.0.0.1:${SERVICE_PORT}/v1/models" 2>/dev/null \
      | grep -o '"id":[^,]*' | head -1 || true)
    echo "${LOG_PREFIX} 服务已就绪: http://${REMOTE_HOST}:${SERVICE_PORT}/v1  (${served})"
    exit 0
  fi
  sleep 5
done

echo "${LOG_PREFIX} 错误: 服务启动超时（${READY_TIMEOUT}s）" >&2
exit 1
