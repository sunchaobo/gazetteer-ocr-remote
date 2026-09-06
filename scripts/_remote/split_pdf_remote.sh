#!/usr/bin/env bash
# 远程执行脚本：激活 paddle-ocr venv + 调 split_pdf.py 切分 PDF。
# 由 scripts/extract_pdf_pages.sh 通过 ssh 调用：
#   必需:
#     REMOTE_VENVS_DIR      venv 父目录
#     REMOTE_VENV_SOURCE    venv 源路径
#     REMOTE_VENV_LINK      venv 软链名
#     HF_ENDPOINT_VAL       HF mirror
#     REMOTE_SRC_DIR        远程 src 目录 (Python 脚本所在)
#     REMOTE_PDF            输入 PDF 绝对路径
#     REMOTE_PAGES_DIR      切图输出目录 (绝对路径)
#   可选:
#     DPI                   (默认 200)
#     SPLIT_WORKERS         (默认 4)
#     REMOTE_RUN_LOG        执行日志 (绝对路径, 留空则不写日志)

set -euo pipefail

: "${REMOTE_VENVS_DIR:=required}"
: "${REMOTE_VENV_SOURCE:=required}"
: "${REMOTE_VENV_LINK:=required}"
: "${HF_ENDPOINT_VAL:=required}"
: "${REMOTE_SRC_DIR:=required}"
: "${REMOTE_PDF:=required}"
: "${REMOTE_PAGES_DIR:=required}"
DPI="${DPI:-200}"
SPLIT_WORKERS="${SPLIT_WORKERS:-4}"
REMOTE_RUN_LOG="${REMOTE_RUN_LOG:-}"

LINK_PATH="${REMOTE_VENVS_DIR}/${REMOTE_VENV_LINK}"
ACTIVATE_PATH="${LINK_PATH}/bin/activate"

if [ -n "$REMOTE_RUN_LOG" ]; then
  mkdir -p "$(dirname "$REMOTE_RUN_LOG")"
  exec > >(tee -a "$REMOTE_RUN_LOG") 2>&1
fi

echo "[remote-split-start] $(date -u +%Y-%m-%dT%H:%M:%SZ) PID=$$"

mkdir -p "${REMOTE_VENVS_DIR}"
if [ ! -e "${LINK_PATH}" ]; then
  ln -s "${REMOTE_VENV_SOURCE}" "${LINK_PATH}"
fi

mkdir -p "$(dirname "${REMOTE_PAGES_DIR}")"

cd "${REMOTE_VENVS_DIR}"
# shellcheck disable=SC1091
source "${ACTIVATE_PATH}"

export HF_ENDPOINT="${HF_ENDPOINT_VAL}"

mkdir -p "${REMOTE_PAGES_DIR}"

echo "[remote-split] 激活 venv: ${ACTIVATE_PATH}"
echo "[remote-split] python: $(command -v python3)"
echo "[remote-split] 启动 split_pdf.py pdf=${REMOTE_PDF} dpi=${DPI} workers=${SPLIT_WORKERS}"

python3 "${REMOTE_SRC_DIR}/split_pdf.py" \
  --pdf "${REMOTE_PDF}" \
  --pages-dir "${REMOTE_PAGES_DIR}" \
  --dpi "${DPI}" \
  --workers "${SPLIT_WORKERS}"

echo "[remote-split-end] $(date -u +%Y-%m-%dT%H:%M:%SZ)"
