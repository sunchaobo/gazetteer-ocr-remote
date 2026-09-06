# gazetteer-ocr-remote

方志 OCR 的远程通道代码（Kaggle Kernel + Google Drive/Colab 辅助脚本），
从 `chronicles-extractor` 主仓拆出、独立维护。

## 目录

- `kaggle/glm-ocr-vllm/` — Kaggle Kernel（GLM-OCR + vLLM），`kernel-metadata.json` 的
  `kaggle kernels push -p` 入口。依赖数据集 `chaobosun/pages-to-ocr`。
- `scripts/kaggle_glm_ocr.sh` — 一键流水线：更新 Kaggle 数据集 → 推送 Kernel 并等待 →
  下载结果到主仓 `data/<书>/results.glm/`。**在主仓根目录下执行**（`data/` 路径相对 cwd），
  Kernel 目录自动随本仓库定位：
  ```bash
  ./scripts/kaggle_glm_ocr.sh /path/to/xxx.pdf            # 全流程
  ./scripts/kaggle_glm_ocr.sh --download-only /path/to/xxx.pdf  # 仅下载结果
  ```
- `colab/` — Google Drive 上传/下载辅助脚本（`upload_to_drive.py` / `download_results.py`），
  首次使用需 `pip install -r requirements.txt` 并把 OAuth 凭据放到 `~/.gazetteer_ocr/credentials.json`
 （详见各脚本头注释）。

## 与主仓的关系

- 主仓只保留本地 OCR 通道（`ocr_glm.py` / `ocr_pipeline.py` / `vlm_ocr.py`）。
- 本仓不依赖主仓任何代码；主仓通过 `kaggle kernels output` 产物（`results.glm/`）消费识别结果。
