#!/usr/bin/env bash
# 远程执行脚本：在 dl 上启动 vllm 服务。
# 由 scripts/start_vllm.sh 通过 ssh 注入环境变量后调用：
#   必需:
#     REMOTE_VENVS_DIR      venv 父目录
#     REMOTE_VENV_SOURCE    venv 源路径
#     REMOTE_VENV_LINK      venv 软链名 (默认 vllm-paddle, vllm pip 通用)
#     HF_ENDPOINT_VAL       HF mirror
#     REMOTE_LOG_DIR        vllm 日志目录
#     SERVICE_PORT          (默认 8000)
#   可选:
#     VLLM_ENGINE          引擎选择, 默认 "paddle-ocr-vl", 可选 "glm-ocr"

set -euo pipefail

VLLM_ENGINE="${VLLM_ENGINE:-glm-ocr}"

: "${REMOTE_VENVS_DIR:=required}"
: "${REMOTE_VENV_SOURCE:=required}"
: "${REMOTE_VENV_LINK:=vllm-paddle}"
: "${HF_ENDPOINT_VAL:=required}"
: "${REMOTE_LOG_DIR:=required}"
SERVICE_PORT="${SERVICE_PORT:-8000}"

# 按 VLLM_ENGINE 选择 model id / served name / 额外启动参数 / engine tag
case "$VLLM_ENGINE" in
  paddle-ocr-vl)
    VLLM_MODEL_ID="PaddlePaddle/PaddleOCR-VL"
    VLLM_SERVED_NAME="PaddleOCR-VL-1.6-0.9B"
    ENGINE_TAG="paddle-ocr-vl"
    ENGINE_EXTRA_ARGS=(--trust-remote-code --gpu-memory-utilization 0.80)
    ;;
  glm-ocr)
    VLLM_MODEL_ID="zai-org/GLM-OCR"
    VLLM_SERVED_NAME="GLM-OCR"
    ENGINE_TAG="glm-ocr"
    ENGINE_EXTRA_ARGS=(--allowed-local-media-path "/" --trust-remote-code)
    ;;
  *)
    echo "[start_vllm_remote] 错误: 未知 VLLM_ENGINE='$VLLM_ENGINE'" >&2
    echo "[start_vllm_remote] 可用: paddle-ocr-vl | glm-ocr" >&2
    exit 1
    ;;
esac

LINK_PATH="${REMOTE_VENVS_DIR}/${REMOTE_VENV_LINK}"
ACTIVATE_PATH="${LINK_PATH}/bin/activate"

mkdir -p "${REMOTE_VENVS_DIR}" "${REMOTE_LOG_DIR}"
if [ ! -e "${LINK_PATH}" ]; then
  ln -s "${REMOTE_VENV_SOURCE}" "${LINK_PATH}"
fi

cd "${REMOTE_VENVS_DIR}"
# shellcheck disable=SC1091
source "${ACTIVATE_PATH}"

export HF_ENDPOINT="${HF_ENDPOINT_VAL}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="${REMOTE_LOG_DIR}/vllm_${ENGINE_TAG}_${TIMESTAMP}.log"
PID_FILE="${REMOTE_LOG_DIR}/vllm_${ENGINE_TAG}_${TIMESTAMP}.pid"

echo "[start_vllm_remote] engine=${ENGINE_TAG}  model=${VLLM_MODEL_ID}  served_name=${VLLM_SERVED_NAME}"
echo "[start_vllm_remote] log: ${LOG_FILE}"

# 探测端口: 若已有 vllm 在跑, 直接退出 (不强制 kill)
if curl -sf "http://127.0.0.1:${SERVICE_PORT}/v1/models" >/dev/null 2>&1; then
  echo "[start_vllm_remote] ${SERVICE_PORT} 已在线, 跳过启动"
  exit 0
fi

# 启动 vllm
nohup vllm serve "${VLLM_MODEL_ID}" \
    "${ENGINE_EXTRA_ARGS[@]}" \
    --max-num-batched-tokens 16384 \
    --no-enable-prefix-caching \
    --mm-processor-cache-gb 0 \
    --served-model-name "${VLLM_SERVED_NAME}" \
    > "${LOG_FILE}" 2>&1 &

echo $! > "${PID_FILE}"
disown 2>/dev/null || true

echo "started: engine=${ENGINE_TAG} pid=$(cat "${PID_FILE}") log=${LOG_FILE} port=${SERVICE_PORT}"
