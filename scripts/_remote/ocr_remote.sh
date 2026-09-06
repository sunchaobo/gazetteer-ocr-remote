#!/usr/bin/env bash
# 远程执行脚本：paddle-ocr venv 准备 + 调 ocr_pipeline.py 并发识别。
# 由 scripts/ocr_pages.sh 通过 ssh 注入环境变量后调用：
#   必需:
#     REMOTE_VENVS_DIR      venv 父目录
#     REMOTE_VENV_SOURCE    venv 源路径
#     REMOTE_VENV_LINK      venv 软链名
#     HF_ENDPOINT_VAL       HF mirror
#     REMOTE_SRC_DIR        远程 src 目录 (Python 脚本所在)
#     REMOTE_PY_SCRIPT      Python 脚本名 (默认 ocr_pipeline.py)
#     REMOTE_PAGES_DIR      输入 PNG 目录 (绝对路径)
#     REMOTE_RESULTS_DIR    识别结果输出目录 (绝对路径)
#     REMOTE_RUN_LOG        本次执行日志 (绝对路径)
#     VLLM_URL              vllm 服务 base URL
#     DOCLAYOUT_DIR         PP-DocLayoutV3 模型目录
#   可选:
#     WORKERS               OCR 并发线程数 (默认 4)

set -euo pipefail

: "${REMOTE_VENVS_DIR:=required}"
: "${REMOTE_VENV_SOURCE:=required}"
: "${REMOTE_VENV_LINK:=required}"
: "${HF_ENDPOINT_VAL:=required}"
: "${REMOTE_SRC_DIR:=required}"
: "${REMOTE_PY_SCRIPT:=ocr_pipeline.py}"
: "${REMOTE_PAGES_DIR:=required}"
: "${REMOTE_RESULTS_DIR:=required}"
: "${REMOTE_RUN_LOG:=required}"
: "${VLLM_URL:=required}"
: "${DOCLAYOUT_DIR:=required}"
WORKERS="${WORKERS:-4}"

mkdir -p "$(dirname "${REMOTE_RUN_LOG}")"
exec > >(tee -a "${REMOTE_RUN_LOG}") 2>&1
echo "[ocr-remote-start] $(date -u +%Y-%m-%dT%H:%M:%SZ) PID=$$ log=${REMOTE_RUN_LOG}"

LINK_PATH="${REMOTE_VENVS_DIR}/${REMOTE_VENV_LINK}"
ACTIVATE_PATH="${LINK_PATH}/bin/activate"

mkdir -p "${REMOTE_VENVS_DIR}"
if [ ! -e "${LINK_PATH}" ]; then
  ln -s "${REMOTE_VENV_SOURCE}" "${LINK_PATH}"
fi

mkdir -p "$(dirname "${REMOTE_RESULTS_DIR}")"

cd "${REMOTE_VENVS_DIR}"
# shellcheck disable=SC1091
source "${ACTIVATE_PATH}"

export HF_ENDPOINT="${HF_ENDPOINT_VAL}"

mkdir -p "${REMOTE_RESULTS_DIR}"

echo "[remote] Python 识别: python3 ${REMOTE_SRC_DIR}/${REMOTE_PY_SCRIPT} (workers=${WORKERS})"
python3 "${REMOTE_SRC_DIR}/${REMOTE_PY_SCRIPT}" \
  --pages-dir "${REMOTE_PAGES_DIR}" \
  --results-dir "${REMOTE_RESULTS_DIR}" \
  --vllm-url "${VLLM_URL}" \
  --doclayout-dir "${DOCLAYOUT_DIR}" \
  --workers "${WORKERS}"

echo "[ocr-remote-end] $(date -u +%Y-%m-%dT%H:%M:%SZ)"
