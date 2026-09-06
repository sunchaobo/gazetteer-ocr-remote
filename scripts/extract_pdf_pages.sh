#!/usr/bin/env bash
# 单一入口 PDF 处理流水线。
#
# 用法:
#   ./scripts/extract_pdf_pages.sh <pdf_path>
#   SKIP_SPLIT=true        ./scripts/extract_pdf_pages.sh <pdf_path>  # 跳过上传+切图
#   SKIP_SCP=true          ./scripts/extract_pdf_pages.sh <pdf_path>  # 只跳过上传 PDF
#   SKIP_SPLIT=true SKIP_SCP=true ./scripts/extract_pdf_pages.sh <pdf_path>
#
# 流程分支（由 SKIP_SPLIT / SKIP_SCP 控制，默认都为 false）:
#   SKIP_SPLIT=false SKIP_SCP=false (默认):
#     上传 PDF → 本地切图 → scp pages/ → 远程 OCR → 拉回 results/
#   SKIP_SPLIT=true  SKIP_SCP=*:
#     (假定远程 pages/ 已就绪，跳过整段阶段 1) → 远程 OCR → 拉回 results/
#   SKIP_SPLIT=false SKIP_SCP=true:
#     (假定远程 PDF 已存在，跳过 scp PDF) → 本地切图 → scp pages/ → 远程 OCR → 拉回 results/
#
# 输出目录（不带时间戳）:
# 远程: ${REMOTE_DATA_DIR}/<pdf-basename>/{<pdf>.pdf, pages/, results.<engine>/}
#       其中 results.paddle/ 或 results.glm/ (按 VLLM_ENGINE)
# 本地: ${LOCAL_DATA_DIR}/<pdf-basename>/{pages/, results.<engine>/}
# 日志:
#   ${REMOTE_LOG_DIR}/ocr_<pdf-basename>.log
#
# 幂等:
#   * 本地 pages 已有 manifest.json → 跳过本地切图
#   * 远程 results.<engine>/summary.json 已存在 → 跳过远程 OCR（仍拉回本地）
#   * SKIP_SPLIT=true 但远程 pages/ 不存在 → 报错
#   * SKIP_SCP=true 但远程 PDF 不存在 → WARN，仍继续
#
# 前置条件:
#   * 已通过 scripts/start_vllm.sh 启动对应 VLLM_ENGINE 的服务
#     - VLLM_ENGINE=paddle-ocr-vl (默认): 需 PaddleOCR-VL 模型 + PP-DocLayoutV3
#     - VLLM_ENGINE=glm-ocr:              需 GLM-OCR 模型 (无版面分析依赖)
#   * 远程 venv /root/venvs/paddle-ocr 已装好 paddleocr (paddle-ocr-vl) / openai (glm-ocr)
#
# 环境变量（可选）:
#   SKIP_SPLIT                true/false（默认 false）跳过上传 PDF + 本地切图
#   SKIP_SCP                  true/false（默认 false）只跳过 scp 上传 PDF
#   VLLM_ENGINE               引擎 (默认 paddle-ocr-vl; 可选 glm-ocr), 给探测 vllm 时校验 served name 用
#   REMOTE_HOST                远程主机别名（默认 dl）
#   LOCAL_DATA_DIR             本地结果目录（默认 <项目根>/data）
#   REMOTE_EXTRACTORS_BASE     远程 extractors 根
#   REMOTE_DATA_DIR            远程数据目录
#   REMOTE_SRC_DIR             远程 src 目录
#   REMOTE_SCRIPTS_DIR         远程 shell 脚本目录
#   REMOTE_LOG_DIR             执行日志目录
#   REMOTE_VENVS_DIR           venv 父目录
#   REMOTE_VENV_SOURCE         venv 源路径
#   REMOTE_VENV_LINK           venv 软链名
#   HF_ENDPOINT                模型下载 mirror
#   VLLM_URL                   vllm 服务 base URL
#   DOCLAYOUT_DIR              PP-DocLayoutV3 模型目录
#   DPI                        切图 dpi（默认 200）
#   SPLIT_WORKERS              PDF 切图进程数（默认 4）
#   WORKERS                    OCR 并发线程数（默认 4）
#   REQUIRE_VLLM               是否探测 vllm（默认 true）

set -euo pipefail

SKIP_SPLIT="$(echo "${SKIP_SPLIT:-false}" | tr '[:upper:]' '[:lower:]')"
SKIP_SCP="$(echo "${SKIP_SCP:-false}" | tr '[:upper:]' '[:lower:]')"
VLLM_ENGINE="${VLLM_ENGINE:-glm-ocr}"

REMOTE_HOST="${REMOTE_HOST:-dl}"
REMOTE_EXTRACTORS_BASE="${REMOTE_EXTRACTORS_BASE:-/root/autodl-tmp/extractors}"
REMOTE_DATA_DIR="${REMOTE_DATA_DIR:-${REMOTE_EXTRACTORS_BASE}/data}"
REMOTE_SRC_DIR="${REMOTE_SRC_DIR:-${REMOTE_EXTRACTORS_BASE}/src}"
REMOTE_SCRIPTS_DIR="${REMOTE_SCRIPTS_DIR:-${REMOTE_EXTRACTORS_BASE}/scripts}"
REMOTE_LOG_DIR="${REMOTE_LOG_DIR:-${REMOTE_EXTRACTORS_BASE}/logs}"
REMOTE_VENVS_DIR="${REMOTE_VENVS_DIR:-/root/autodl-tmp/venvs}"
REMOTE_VENV_SOURCE="${REMOTE_VENV_SOURCE:-/root/venvs/paddle-ocr}"
REMOTE_VENV_LINK="${REMOTE_VENV_LINK:-paddle-ocr}"
REMOTE_PY_SCRIPT="${REMOTE_PY_SCRIPT:-ocr_pipeline.py}"
HF_ENDPOINT_VAL="${HF_ENDPOINT:-https://hf-mirror.com}"
VLLM_URL="${VLLM_URL:-http://localhost:8000/v1}"
DOCLAYOUT_DIR="${DOCLAYOUT_DIR:-/root/PP-DocLayoutV3/}"
DPI="${DPI:-200}"
SPLIT_WORKERS="${SPLIT_WORKERS:-4}"
WORKERS="${WORKERS:-4}"
REQUIRE_VLLM="${REQUIRE_VLLM:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_ROOT="$(dirname "$SCRIPT_DIR")"
# 主仓检出位置（ocr_pipeline.py 等仍在主仓；与本仓同级默认布局可零配置）
MAIN_REPO="${MAIN_REPO:-$(dirname "$REMOTE_ROOT")/chronicles-extractor}"
LOCAL_SPLIT_PY="${LOCAL_SPLIT_PY:-${REMOTE_ROOT}/tools/split_pdf.py}"
LOCAL_OCR_PY="${LOCAL_OCR_PY:-${MAIN_REPO}/src/${REMOTE_PY_SCRIPT}}"
LOCAL_REMOTE_SH="${REMOTE_ROOT}/scripts/_remote/ocr_remote.sh"
LOCAL_SPLIT_REMOTE_SH="${REMOTE_ROOT}/scripts/_remote/split_pdf_remote.sh"
LOCAL_DATA_DIR="${LOCAL_DATA_DIR:-${MAIN_REPO}/data}"

LOG_PREFIX="[process_pdf]"
T_START=$(date +%s)

if [ ! -f "$LOCAL_SPLIT_PY" ]; then
  echo "${LOG_PREFIX} 错误: 找不到本地 split 脚本 ${LOCAL_SPLIT_PY}" >&2
  exit 1
fi
if [ ! -f "$LOCAL_OCR_PY" ]; then
  echo "${LOG_PREFIX} 错误: 找不到本地 OCR 脚本 ${LOCAL_OCR_PY}" >&2
  exit 1
fi
if [ ! -f "$LOCAL_REMOTE_SH" ]; then
  echo "${LOG_PREFIX} 错误: 找不到本地远程脚本 ${LOCAL_REMOTE_SH}" >&2
  exit 1
fi

if [ "$#" -ne 1 ]; then
  cat >&2 <<EOF
用法: $0 <pdf_path>
  pdf_path: 本地 PDF 文件路径

环境变量:
  SKIP_SPLIT=true   跳过上传 PDF 和本地切图（假定远程 pages/ 已存在）
  SKIP_SCP=true     仅跳过 scp 上传 PDF（假定远程 PDF 已存在，仍做本地切图）
EOF
  exit 1
fi

PDF_PATH="$1"
if [ ! -f "$PDF_PATH" ]; then
  echo "${LOG_PREFIX} 错误: PDF 文件不存在: ${PDF_PATH}" >&2
  exit 1
fi

PDF_BASENAME="$(basename "$PDF_PATH" .pdf)"

LOCAL_RUN_DIR="${LOCAL_DATA_DIR}/${PDF_BASENAME}"
LOCAL_PAGES_DIR="${LOCAL_RUN_DIR}/pages"

REMOTE_RUN_DIR="${REMOTE_DATA_DIR}/${PDF_BASENAME}"
REMOTE_PDF_BACKUP="${REMOTE_RUN_DIR}/$(basename "$PDF_PATH")"
REMOTE_PAGES_DIR="${REMOTE_RUN_DIR}/pages"

# 按 VLLM_ENGINE 决定远/本地的 results 子目录 (results.paddle / results.glm)
case "$VLLM_ENGINE" in
  paddle-ocr-vl) RESULTS_SUBDIR="results.paddle" ;;
  glm-ocr)       RESULTS_SUBDIR="results.glm" ;;
  *)             RESULTS_SUBDIR="results" ;;
esac
REMOTE_RESULTS_DIR="${REMOTE_RUN_DIR}/${RESULTS_SUBDIR}"
LOCAL_RESULTS_DIR="${LOCAL_RUN_DIR}/${RESULTS_SUBDIR}"

REMOTE_RUN_LOG="${REMOTE_LOG_DIR}/ocr_${PDF_BASENAME}.log"
REMOTE_DONE_MARKER="${REMOTE_RESULTS_DIR}/summary.json"

echo "${LOG_PREFIX} 远程主机=${REMOTE_HOST}  vllm=${VLLM_URL}  engine=${VLLM_ENGINE}  SKIP_SPLIT=${SKIP_SPLIT}  SKIP_SCP=${SKIP_SCP}"
echo "${LOG_PREFIX} 本地目录=${LOCAL_RUN_DIR}"
echo "${LOG_PREFIX} 远程目录=${REMOTE_RUN_DIR}"
echo "${LOG_PREFIX} 执行日志=${REMOTE_RUN_LOG}"

# 探测 vllm
if [ "$REQUIRE_VLLM" = "true" ]; then
  probe_url="${VLLM_URL%/v1}/v1/models"
  echo "${LOG_PREFIX} 探测 vllm: ${probe_url}"
  status=$(ssh -o BatchMode=yes "$REMOTE_HOST" \
    "curl -s -o /dev/null -w '%{http_code}' ${probe_url}" 2>/dev/null || true)
  if [ "$status" != "200" ]; then
    echo "${LOG_PREFIX} 错误: vllm 服务未就绪，请先运行 scripts/start_vllm.sh (VLLM_ENGINE=${VLLM_ENGINE})" >&2
    exit 1
  fi
  # 校验 served model name 与 engine 期望一致
  case "$VLLM_ENGINE" in
    paddle-ocr-vl) EXPECTED_MODEL_NAME="PaddleOCR-VL-1.6-0.9B" ;;
    glm-ocr)       EXPECTED_MODEL_NAME="GLM-OCR" ;;
    *)             EXPECTED_MODEL_NAME="" ;;
  esac
  if [ -n "$EXPECTED_MODEL_NAME" ]; then
    served=$(ssh -o BatchMode=yes "$REMOTE_HOST" \
      "curl -s ${probe_url}" 2>/dev/null | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 || true)
    if ! echo "$served" | grep -q "$EXPECTED_MODEL_NAME"; then
      echo "${LOG_PREFIX} 警告: vllm 在线但 served model 与 VLLM_ENGINE=${VLLM_ENGINE} 不匹配" >&2
      echo "${LOG_PREFIX}   expected: $EXPECTED_MODEL_NAME" >&2
      echo "${LOG_PREFIX}   got     : $served" >&2
      echo "${LOG_PREFIX}   请先停止现有 vllm 或调对应 VLLM_ENGINE=..." >&2
      exit 1
    fi
  fi
  echo "${LOG_PREFIX} vllm 服务在线 (engine=${VLLM_ENGINE})"
fi

# ===========================================================================
# 阶段 1: 远程切图 (SKIP_SPLIT=false 时执行)
# ===========================================================================
if [ "$SKIP_SPLIT" = "true" ]; then
  echo "${LOG_PREFIX} 跳过阶段 1 (远程切图)，需自行保证远程 pages/ 已就绪"
  if ! ssh -o BatchMode=yes "$REMOTE_HOST" \
       "[ -d '${REMOTE_PAGES_DIR}' ] && [ -f '${REMOTE_PAGES_DIR}/manifest.json' ]" 2>/dev/null; then
    echo "${LOG_PREFIX} 错误: SKIP_SPLIT=true 但远程 pages 不存在或缺 manifest.json" >&2
    echo "${LOG_PREFIX}       请先用默认参数跑一遍: ./scripts/extract_pdf_pages.sh ${PDF_PATH}" >&2
    exit 1
  fi
else
  # 远程建目录
  echo "${LOG_PREFIX} 准备远程目录"
  ssh "$REMOTE_HOST" \
    "mkdir -p '${REMOTE_DATA_DIR}' '${REMOTE_SRC_DIR}' \
             '${REMOTE_SCRIPTS_DIR}' '${REMOTE_LOG_DIR}' \
             '${REMOTE_RUN_DIR}' '${REMOTE_PAGES_DIR}'"

  # scp 上传 PDF 备份 (SKIP_SCP=true 时跳过)
  if [ "$SKIP_SCP" = "true" ]; then
    if ssh -o BatchMode=yes "$REMOTE_HOST" "[ -f '${REMOTE_PDF_BACKUP}' ]" 2>/dev/null; then
      echo "${LOG_PREFIX} SKIP_SCP=true, 跳过上传 PDF (远程 ${REMOTE_PDF_BACKUP} 已存在)"
    else
      echo "${LOG_PREFIX} [WARN] SKIP_SCP=true 但远程 PDF 不存在: ${REMOTE_PDF_BACKUP}, 继续执行"
    fi
  else
    echo "${LOG_PREFIX} scp 上传 PDF -> ${REMOTE_HOST}:${REMOTE_PDF_BACKUP}"
    scp -q "$PDF_PATH" "${REMOTE_HOST}:${REMOTE_PDF_BACKUP}"
  fi

  # scp 上传 split_pdf.py 到远程 src/
  echo "${LOG_PREFIX} scp 上传 split_pdf.py -> ${REMOTE_HOST}:${REMOTE_SRC_DIR}/"
  scp -q "$LOCAL_SPLIT_PY" "${REMOTE_HOST}:${REMOTE_SRC_DIR}/split_pdf.py"

  # scp 上传 split_pdf_remote.sh 到远程 scripts/
  echo "${LOG_PREFIX} scp 上传 split_pdf_remote.sh -> ${REMOTE_HOST}:${REMOTE_SCRIPTS_DIR}/"
  scp -q "$LOCAL_SPLIT_REMOTE_SH" "${REMOTE_HOST}:${REMOTE_SCRIPTS_DIR}/split_pdf_remote.sh"
  ssh "$REMOTE_HOST" "chmod +x '${REMOTE_SCRIPTS_DIR}/split_pdf_remote.sh'"

  # 远程切图：调用 _remote/split_pdf_remote.sh (内部 source paddle-ocr + 调 split_pdf.py)
  echo "${LOG_PREFIX} 远程切分 (dpi=${DPI}, workers=${SPLIT_WORKERS})"
  ssh "$REMOTE_HOST" \
    "REMOTE_VENVS_DIR='${REMOTE_VENVS_DIR}' \
     REMOTE_VENV_SOURCE='${REMOTE_VENV_SOURCE}' \
     REMOTE_VENV_LINK='${REMOTE_VENV_LINK}' \
     HF_ENDPOINT_VAL='${HF_ENDPOINT_VAL}' \
     REMOTE_SRC_DIR='${REMOTE_SRC_DIR}' \
     REMOTE_PDF='${REMOTE_PDF_BACKUP}' \
     REMOTE_PAGES_DIR='${REMOTE_PAGES_DIR}' \
     DPI='${DPI}' \
     SPLIT_WORKERS='${SPLIT_WORKERS}' \
     bash '${REMOTE_SCRIPTS_DIR}/split_pdf_remote.sh'"
fi

# ===========================================================================
# 阶段 2: 远程 OCR 识别 (无论 SKIP_SPLIT 都执行)
#         按 VLLM_ENGINE 选不同的 Python pipeline 与远程调度脚本
# ===========================================================================

# 远程 pages 校验（即使 SKIP_SPLIT=true 也必须就绪）
echo "${LOG_PREFIX} 检查远程 pages: ${REMOTE_PAGES_DIR}"
if ! ssh -o BatchMode=yes "$REMOTE_HOST" \
     "[ -d '${REMOTE_PAGES_DIR}' ] && [ -f '${REMOTE_PAGES_DIR}/manifest.json' ]" 2>/dev/null; then
  echo "${LOG_PREFIX} 错误: 远程 pages 不存在或缺 manifest.json" >&2
  exit 1
fi

# 按 engine 决定: local Python, remote script, output subdir
case "$VLLM_ENGINE" in
  paddle-ocr-vl)
    LOCAL_OCR_PY="${MAIN_REPO}/src/ocr_pipeline.py"
    REMOTE_PY_NAME="ocr_pipeline.py"
    REMOTE_SH_NAME="ocr_remote.sh"
    ;;
  glm-ocr)
    LOCAL_OCR_PY="${MAIN_REPO}/src/ocr_glm.py"
    REMOTE_PY_NAME="ocr_glm.py"
    REMOTE_SH_NAME="ocr_glm_remote.sh"
    ;;
  *)
    echo "${LOG_PREFIX} 错误: VLLM_ENGINE='$VLLM_ENGINE' 不支持" >&2
    exit 1
    ;;
esac
# REMOTE_DONE_MARKER 已在前面按 engine 设置为 results.<engine>/summary.json

# 幂等：summary.json 已存在则跳过远程识别
echo "${LOG_PREFIX} 检查是否已识别: ${REMOTE_DONE_MARKER}"
if ssh -o BatchMode=yes "$REMOTE_HOST" "[ -f '${REMOTE_DONE_MARKER}' ]" 2>/dev/null; then
  echo "${LOG_PREFIX} 已存在识别结果, 跳过远程 OCR"
  SKIP_OCR=1
else
  SKIP_OCR=0

  echo "${LOG_PREFIX} 准备远程 src/scripts 目录"
  ssh "$REMOTE_HOST" \
    "mkdir -p '${REMOTE_SRC_DIR}' '${REMOTE_SCRIPTS_DIR}' '${REMOTE_LOG_DIR}' '${REMOTE_RESULTS_DIR}'"

  echo "${LOG_PREFIX} scp 上传 Python pipeline -> ${REMOTE_HOST}:${REMOTE_SRC_DIR}/${REMOTE_PY_NAME}"
  scp -q "$LOCAL_OCR_PY" "${REMOTE_HOST}:${REMOTE_SRC_DIR}/${REMOTE_PY_NAME}"

  echo "${LOG_PREFIX} scp 上传远程调度脚本 -> ${REMOTE_HOST}:${REMOTE_SCRIPTS_DIR}/${REMOTE_SH_NAME}"
  scp -q "${REMOTE_ROOT}/scripts/_remote/${REMOTE_SH_NAME}" \
    "${REMOTE_HOST}:${REMOTE_SCRIPTS_DIR}/${REMOTE_SH_NAME}"
  ssh "$REMOTE_HOST" "chmod +x '${REMOTE_SCRIPTS_DIR}/${REMOTE_SH_NAME}'"

  if [ "$VLLM_ENGINE" = "paddle-ocr-vl" ]; then
    echo "${LOG_PREFIX} 远程执行 (venv 准备 + PaddleOCRVL, workers=${WORKERS})"
    ssh "$REMOTE_HOST" \
      "REMOTE_VENVS_DIR='${REMOTE_VENVS_DIR}' \
       REMOTE_VENV_SOURCE='${REMOTE_VENV_SOURCE}' \
       REMOTE_VENV_LINK='${REMOTE_VENV_LINK}' \
       HF_ENDPOINT_VAL='${HF_ENDPOINT_VAL}' \
       REMOTE_SRC_DIR='${REMOTE_SRC_DIR}' \
       REMOTE_PY_SCRIPT='${REMOTE_PY_NAME}' \
       REMOTE_PAGES_DIR='${REMOTE_PAGES_DIR}' \
       REMOTE_RESULTS_DIR='${REMOTE_RESULTS_DIR}' \
       REMOTE_RUN_LOG='${REMOTE_RUN_LOG}' \
       VLLM_URL='${VLLM_URL}' \
       DOCLAYOUT_DIR='${DOCLAYOUT_DIR}' \
       WORKERS='${WORKERS}' \
       bash '${REMOTE_SCRIPTS_DIR}/${REMOTE_SH_NAME}'"
  else  # glm-ocr
    echo "${LOG_PREFIX} 远程执行 (venv 准备 + GLM-OCR via OpenAI, workers=${WORKERS})"
    ssh "$REMOTE_HOST" \
      "REMOTE_VENVS_DIR='${REMOTE_VENVS_DIR}' \
       REMOTE_VENV_SOURCE='${REMOTE_VENV_SOURCE}' \
       REMOTE_VENV_LINK='${REMOTE_VENV_LINK}' \
       HF_ENDPOINT_VAL='${HF_ENDPOINT_VAL}' \
       REMOTE_SRC_DIR='${REMOTE_SRC_DIR}' \
       REMOTE_PAGES_DIR='${REMOTE_PAGES_DIR}' \
       REMOTE_RESULTS_DIR='${REMOTE_RESULTS_DIR}' \
       REMOTE_RUN_LOG='${REMOTE_RUN_LOG}' \
       LLM_API_BASE='${VLLM_URL}' \
       LLM_MODEL='${EXPECTED_MODEL_NAME}' \
       LLM_API_KEY='dummy' \
       GLM_OCR_WORKERS='${WORKERS}' \
       PDF_BASENAME='${PDF_BASENAME}' \
       bash '${REMOTE_SCRIPTS_DIR}/${REMOTE_SH_NAME}'"
  fi
fi

# ===========================================================================
# 阶段 3: 只拉回 results.<engine>/，不带 PDF 备份回本地
# ===========================================================================
echo "${LOG_PREFIX} scp 拉回 ${RESULTS_SUBDIR}/ -> 本地: ${LOCAL_RESULTS_DIR}/"
mkdir -p "${LOCAL_RUN_DIR}"

# 保险：如果本地残留了上一次的 PDF 副本 (历史遗留)，先清掉
if [ -f "${LOCAL_RUN_DIR}/$(basename "${REMOTE_PDF_BACKUP}")" ]; then
  echo "${LOG_PREFIX} 清理本地残留的 PDF: ${LOCAL_RUN_DIR}/$(basename "${REMOTE_PDF_BACKUP}")"
  rm -f "${LOCAL_RUN_DIR}/$(basename "${REMOTE_PDF_BACKUP}")"
fi

if ! scp -qr "${REMOTE_HOST}:${REMOTE_RESULTS_DIR}/" "${LOCAL_RUN_DIR}/${RESULTS_SUBDIR}/"; then
  echo "${LOG_PREFIX} 错误: SCP 拉回 ${RESULTS_SUBDIR}/ 失败" >&2
  exit 1
fi

# ===========================================================================
# 阶段 4: 清理 (默认开启，结果已拉到本地，远程中间产物可以删)
# ===========================================================================
REMOTE_CLEANUP="${REMOTE_CLEANUP:-true}"
LOCAL_CLEANUP="${LOCAL_CLEANUP:-true}"

if [ "$REMOTE_CLEANUP" = "true" ]; then
  echo "${LOG_PREFIX} [cleanup] 删除远程 pages/ (PDF 备份保留)"
  ssh "$REMOTE_HOST" "rm -rf '${REMOTE_PAGES_DIR}'" || true
fi

if [ "$LOCAL_CLEANUP" = "true" ]; then
  # 清理本地可能残留的 PDF 历史副本 (现在阶段 3 已经只拉 results，本步冗余但保险)
  for f in "${LOCAL_RUN_DIR}"/*.pdf; do
    [ -f "$f" ] && rm -f "$f" && echo "${LOG_PREFIX} [cleanup] 清理本地 PDF: $f"
  done
fi

echo "${LOG_PREFIX} 完成"
if [ "$SKIP_OCR" = "1" ]; then
  echo "${LOG_PREFIX}   (本次跳过远程 OCR, 复用了已有的 results/summary.json)"
fi
if [ "$SKIP_SPLIT" = "true" ]; then
  echo "${LOG_PREFIX}   (本次跳过上传 PDF 和本地切图)"
fi
if [ "$SKIP_SCP" = "true" ]; then
  echo "${LOG_PREFIX}   (本次跳过 scp 上传 PDF，假定远程已存在)"
fi
echo "${LOG_PREFIX} 切分图片(本地): ${LOCAL_PAGES_DIR}/"
echo "${LOG_PREFIX} 识别结果(本地): ${LOCAL_RESULTS_DIR}/"
echo "${LOG_PREFIX} 识别结果(远程): ${REMOTE_HOST}:${REMOTE_RESULTS_DIR}/"
echo "${LOG_PREFIX} 执行日志(远程): ${REMOTE_HOST}:${REMOTE_RUN_LOG}"
if [ "$REMOTE_CLEANUP" = "true" ]; then
  echo "${LOG_PREFIX} (pages 已在阶段 4 删除; 远程 PDF 备份保留)"
fi

T_END=$(date +%s)
ELAPSED=$((T_END - T_START))
H=$((ELAPSED / 3600))
M=$(((ELAPSED % 3600) / 60))
S=$((ELAPSED % 60))
if [ "$H" -gt 0 ]; then
  echo "${LOG_PREFIX} shell 总耗时: ${H}h${M}m${S}s (${ELAPSED}s)"
elif [ "$M" -gt 0 ]; then
  echo "${LOG_PREFIX} shell 总耗时: ${M}m${S}s (${ELAPSED}s)"
else
  echo "${LOG_PREFIX} shell 总耗时: ${S}s"
fi
