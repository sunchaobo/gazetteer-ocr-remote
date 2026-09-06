#!/usr/bin/env bash
set -euo pipefail

DOWNLOAD_ONLY=false
if [ "${1:-}" = "--download-only" ] || [ "${1:-}" = "-d" ]; then
    DOWNLOAD_ONLY=true
    shift
fi

PDF="$1"
if [ -z "$PDF" ]; then
    echo "用法: $0 [--download-only|-d] <pdf_path>"
    exit 1
fi
PDF="$(cd "$(dirname "$PDF")" && pwd)/$(basename "$PDF")"

BASENAME=$(basename "$PDF" .pdf)
PAGES_DIR="data/$BASENAME/pages"
KAGGLE_DATA="data/kaggle_datasets/pages-to-ocr"
# Kernel 目录随本脚本定位（仓库检出到任意路径均可；data/ 路径仍相对执行时的 cwd，即主仓根目录）
REMOTE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="$REMOTE_ROOT/kaggle/glm-ocr-vllm"
KERNEL_ID="chaobosun/glm-ocr-vllm"
OUTPUT_DIR="temp/output"
RESULTS_DIR="data/$BASENAME/results.glm"

#echo "=== 1/4 切图 + 压缩 ==="
#python src/split_pdf.py --pdf "$PDF" --pages-dir "$PAGES_DIR" --compress

if ! $DOWNLOAD_ONLY; then
    NEED_UPDATE=true
    if [ -f "$KAGGLE_DATA/original.pdf" ]; then
        NEW_MD5=$(md5sum < "$PDF" 2>/dev/null | cut -d' ' -f1 || md5 -q "$PDF")
        OLD_MD5=$(md5sum < "$KAGGLE_DATA/original.pdf" 2>/dev/null | cut -d' ' -f1 || md5 -q "$KAGGLE_DATA/original.pdf")
        [ "$NEW_MD5" = "$OLD_MD5" ] && NEED_UPDATE=false
    fi

    if $NEED_UPDATE; then
        echo "=== 2/4 更新 Kaggle 数据集 ==="
        mkdir -p "$KAGGLE_DATA"
        cp "$PDF" "$KAGGLE_DATA/original.pdf"
        kaggle datasets version -p "$KAGGLE_DATA" -m "update pages"
    else
        echo "=== 2/4 PDF 未变更，跳过数据集更新 ==="
    fi

    echo "=== 3/4 推送并等待 Kernel ==="
    kaggle kernels push -p "$KERNEL_DIR"
    while true; do
        sleep 30
        STATUS=$(kaggle kernels status "$KERNEL_ID" 2>&1) || true
        echo "  $STATUS"
        if [[ "$STATUS" == *"COMPLETE"* ]]; then
            break
        elif [[ "$STATUS" == *"ERROR"* || "$STATUS" == *"CANCEL"* ]]; then
            echo "Kernel 失败"
            exit 1
        fi
    done
fi

echo "=== 4/4 下载结果 ==="
rm -rf "$OUTPUT_DIR"
kaggle kernels output "$KERNEL_ID" -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$RESULTS_DIR")"
tar -xzf "$OUTPUT_DIR/results.tar.gz" -C "$OUTPUT_DIR"
mv "$OUTPUT_DIR/results" "$RESULTS_DIR"
rm -rf "$OUTPUT_DIR"

echo "=== 完成: $RESULTS_DIR ==="
