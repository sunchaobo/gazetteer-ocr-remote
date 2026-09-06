# gazetteer-ocr-remote

方志 OCR 的远程通道代码（Kaggle Kernel + SSH 远端 + Google Drive/Colab 辅助脚本），
从 `chronicles-extractor` 主仓拆出、独立维护。

## 目录

- `kaggle/glm-ocr-vllm/` — Kaggle Kernel（GLM-OCR + vLLM），`kernel-metadata.json` 的
  `kaggle kernels push -p` 入口。依赖数据集 `chaobosun/pages-to-ocr`。
  notebook 启动时 `git clone` 本仓库（只用 `tools/` 下的两个脚本）。
- `tools/` — 自包含 Python 脚本（纯标准库 + `openai`），从主仓 `src/` 复制而来：
  `split_pdf.py`（切图）、`ocr_glm.py`（GLM-OCR 识别）。主仓的原件仍是本地通道在用，
  两边改动时手动同步（`diff tools/split_pdf.py ../chronicles-extractor/src/split_pdf.py`）。
- `scripts/kaggle_glm_ocr.sh` — Kaggle 一键流水线：更新 Kaggle 数据集 → 推送 Kernel 并等待 →
  下载结果到主仓 `data/<书>/results.glm/`。**在主仓根目录下执行**（`data/` 路径相对 cwd），
  Kernel 目录自动随本仓库定位：
  ```bash
  /path/to/gazetteer-ocr-remote/scripts/kaggle_glm_ocr.sh /path/to/xxx.pdf            # 全流程
  /path/to/gazetteer-ocr-remote/scripts/kaggle_glm_ocr.sh --download-only /path/to/xxx.pdf  # 仅下载结果
  ```
- `scripts/extract_pdf_pages.sh` — SSH 远端 OCR 入口：本地切图 → scp 到远端 → 远端 OCR →
  拉回 `results.<engine>/`。默认布局（本仓与主仓同级检出）零配置；否则设环境变量：
  `MAIN_REPO`（主仓根目录，默认 `../chronicles-extractor`，提供 `src/ocr_pipeline.py` /
  `src/ocr_glm.py` 与 `data/`），`LOCAL_SPLIT_PY` / `LOCAL_OCR_PY` / `LOCAL_DATA_DIR` 可单独覆盖。
- `scripts/start_vllm.sh` + `scripts/_remote/` — 远端 vLLM 服务启动与远端执行脚本
  （`split_pdf_remote.sh` / `ocr_remote.sh` / `ocr_glm_remote.sh` / `start_vllm_remote.sh`），
  只依赖环境变量与远端路径，原样搬入。
- `colab/` — Google Drive 上传/下载辅助脚本（`upload_to_drive.py` / `download_results.py`），
  首次使用需 `pip install -r requirements.txt` 并把 OAuth 凭据放到 `~/.gazetteer_ocr/credentials.json`
 （详见各脚本头注释）。

## 与主仓的关系

- 主仓只保留本地 OCR 通道与解析流水线；远程执行全部在这里。
- 主仓通过产物目录消费识别结果（`data/<书>/results.glm/`、`results.paddle/`）。
