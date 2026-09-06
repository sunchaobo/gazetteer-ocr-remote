#!/usr/bin/env bash
# 远程执行脚本：paddle-ocr venv 准备 + 调 ocr_glm.py (GLM-OCR via OpenAI chat completions).
# 由 scripts/extract_pdf_pages.sh 通过 ssh 调用, VLLM_ENGINE=glm-ocr 时使用.
# 必需:
#   REMOTE_VENVS_DIR, REMOTE_VENV_SOURCE, REMOTE_VENV_LINK,
#   HF_ENDPOINT_VAL,
#   REMOTE_SRC_DIR,
#   REMOTE_PAGES_DIR,
#   REMOTE_RESULTS_DIR,
#   REMOTE_RUN_LOG,
#   LLM_API_BASE          (GLM-OCR 即 vLLM OpenAI base URL, 同 VLLM_URL)
#   LLM_MODEL             (默认 GLM-OCR)
# 可选:
#   GLM_OCR_WORKERS       (默认 4)
#   GLM_OCR_MAX_TOKENS    (默认 8192)
#   GLM_OCR_CONTEXT_WINDOW (默认 0)
#   GLM_OCR_OUT_SUBDIR    (默认 glm_ocr)

set -euo pipefail

: "${REMOTE_VENVS_DIR:=required}"
: "${REMOTE_VENV_SOURCE:=required}"
: "${REMOTE_VENV_LINK:=required}"
: "${HF_ENDPOINT_VAL:=required}"
: "${REMOTE_SRC_DIR:=required}"
: "${REMOTE_PAGES_DIR:=required}"
: "${REMOTE_RESULTS_DIR:=required}"
: "${REMOTE_RUN_LOG:=required}"
: "${LLM_API_BASE:=required}"
LLM_MODEL="${LLM_MODEL:-GLM-OCR}"
GLM_OCR_WORKERS="${GLM_OCR_WORKERS:-4}"
GLM_OCR_MAX_TOKENS="${GLM_OCR_MAX_TOKENS:-8192}"
GLM_OCR_CONTEXT_WINDOW="${GLM_OCR_CONTEXT_WINDOW:-0}"
GLM_OCR_OUT_SUBDIR="${GLM_OCR_OUT_SUBDIR:-}"

mkdir -p "$(dirname "${REMOTE_RUN_LOG}")"
exec > >(tee -a "${REMOTE_RUN_LOG}") 2>&1
echo "[ocr-glm-remote-start] $(date -u +%Y-%m-%dT%H:%M:%SZ) PID=$$"

LINK_PATH="${REMOTE_VENVS_DIR}/${REMOTE_VENV_LINK}"
ACTIVATE_PATH="${LINK_PATH}/bin/activate"

mkdir -p "${REMOTE_VENVS_DIR}"
if [ ! -e "${LINK_PATH}" ]; then
  ln -s "${REMOTE_VENV_SOURCE}" "${LINK_PATH}"
fi

cd "${REMOTE_VENVS_DIR}"
# shellcheck disable=SC1091
source "${ACTIVATE_PATH}"

export HF_ENDPOINT="${HF_ENDPOINT_VAL}"

mkdir -p "${REMOTE_RESULTS_DIR}"

echo "[ocr-glm-remote] python: $(command -v python3)"
echo "[ocr-glm-remote] model: ${LLM_MODEL}  api_base: ${LLM_API_BASE}"

python3 "${REMOTE_SRC_DIR}/ocr_glm.py" \
  --pages-dir "${REMOTE_PAGES_DIR}" \
  --results-dir "${REMOTE_RESULTS_DIR}" \
  --api-base "${LLM_API_BASE}" \
  --api-key "${REMOTE_RUN_LOG_API_KEY:-${LLM_API_KEY:-dummy}}" \
  --model "${LLM_MODEL}" \
  --workers "${GLM_OCR_WORKERS}" \
  --max-tokens "${GLM_OCR_MAX_TOKENS}" \
  --context-window "${GLM_OCR_CONTEXT_WINDOW}" \
  --out-subdir "${GLM_OCR_OUT_SUBDIR}" \
  --pdf-basename "${PDF_BASENAME:-}"

echo "[ocr-glm-remote-end] $(date -u +%Y-%m-%dT%H:%M:%SZ)"
