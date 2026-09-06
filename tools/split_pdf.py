#!/usr/bin/env python3
"""PDF 切图：自动选择最稳的引擎。

优先级:
  1) mutool draw (mupdf 的 CLI，单进程多线程 native，最稳也最快)
  2) PyMuPDF + ProcessPoolExecutor (spawn, workers=1 时退化为单进程)

用法:
    python3 split_pdf.py --pdf <path> --pages-dir <dir> \\
        [--dpi 200] [--workers 4]

输出:
    <pages-dir>/page_<NNNN>.png          (1-indexed)
    <pages-dir>/manifest.json

为什么不再死磕 PyMuPDF 多进程:
  - fork 模式下 PDFium 在子进程里 segfault
  - spawn 模式下某些 Python / glibc / libomp 组合会把 worker 进程 SIGABRT
    （malloc 一致性断言），症状不稳
"""
import argparse
import concurrent.futures as cf
import glob
import json
import multiprocessing as mp
import os
import shutil
import subprocess
import sys
import tarfile
import time

# PyMuPDF 1.24+ 模块名改为 pymupdf；老版本 (1.23-) 用 fitz 别名。
# 统一 import 成 pymupdf 变量，后续全文直接 pymupdf.open(...)。
try:
    import pymupdf
except ImportError:
    try:
        import fitz as pymupdf
    except ImportError:
        sys.stderr.write("[split_pdf] 缺少 pymupdf (>=1.24 推荐) 或 fitz，请 `pip install pymupdf`\n")
        sys.exit(1)


def _ensure_spawn_start_method():
    try:
        mp.set_start_method("spawn", force=True)
    except (RuntimeError, ValueError):
        pass


def _detect_mutool() -> str:
    """返回 mutool 绝对路径，未装返回空串。"""
    return shutil.which("mutool") or ""


# ---------------------------------------------------------------------------
# Engine A: mutool draw (mupdf CLI)
# ---------------------------------------------------------------------------

def _split_with_mutool(pdf_path: str, pages_dir: str, dpi: int, mutool_bin: str) -> list:
    """调用 mutool draw 把 PDF 切图，0-indexed 输出重命名成 1-indexed。"""
    os.makedirs(pages_dir, exist_ok=True)

    out_pattern = os.path.join(pages_dir, "page_%04d.png")
    cmd = [mutool_bin, "draw", "-r", str(dpi), "-o", out_pattern, pdf_path]
    print(f"[split_pdf] engine=mutool cmd={' '.join(cmd)}", flush=True)
    subprocess.run(cmd, check=True)

    pngs = sorted(glob.glob(os.path.join(pages_dir, "page_*.png")))
    if not pngs:
        raise RuntimeError("mutool 未产出任何 PNG")

    # 用 PIL 读尺寸 (可选)；失败则 width/height=None
    try:
        from PIL import Image
        have_pil = True
    except ImportError:
        have_pil = False

    manifest = []
    for i, src in enumerate(pngs, start=1):
        dst = os.path.join(pages_dir, f"page_{i:04d}.png")
        if os.path.abspath(src) != os.path.abspath(dst):
            os.rename(src, dst)
        width = height = None
        if have_pil:
            try:
                with Image.open(dst) as im:
                    width, height = im.size
            except Exception:
                pass
        manifest.append({
            "page": i,
            "filename": f"page_{i:04d}.png",
            "path": os.path.abspath(dst),
            "width": width,
            "height": height,
        })

    return manifest


# ---------------------------------------------------------------------------
# Engine B: PyMuPDF + ProcessPoolExecutor (spawn)
# ---------------------------------------------------------------------------

def _render_chunk(args):
    """子进程工作函数。pymupdf 来自 module-level import（fitz 自动 alias）。"""
    pdf_path, start, end, out_dir, dpi = args
    doc = pymupdf.open(pdf_path)
    out = []
    for idx in range(start, end):
        try:
            page = doc[idx]
            pix = page.get_pixmap(dpi=dpi)
            img_name = f"page_{idx + 1:04d}.png"
            img_path = os.path.join(out_dir, img_name)
            pix.save(img_path)
            out.append({
                "page": idx + 1,
                "filename": img_name,
                "path": os.path.abspath(img_path),
                "width": pix.width,
                "height": pix.height,
            })
        except Exception as e:
            sys.stderr.write(f"[split_pdf] page {idx + 1} 失败: {e}\n")
            out.append({"page": idx + 1, "error": repr(e)})
    doc.close()
    return out


def _split_with_pymupdf(pdf_path: str, pages_dir: str, dpi: int, workers: int) -> list:
    """ProcessPoolExecutor spawn 多进程切图；workers<=1 / total<=4 退化为单进程。"""
    os.makedirs(pages_dir, exist_ok=True)
    doc = pymupdf.open(pdf_path)
    total = len(doc)
    doc.close()
    print(f"[split_pdf] engine=pymupdf total={total} dpi={dpi} workers={workers}",
          flush=True)

    if total == 0:
        return []

    if workers <= 1 or total <= 4:
        chunks = [(pdf_path, 0, total, pages_dir, dpi)]
    else:
        chunk_size = max(1, -(-total // (workers * 4)))
        chunks = []
        for start in range(0, total, chunk_size):
            end = min(start + chunk_size, total)
            chunks.append((pdf_path, start, end, pages_dir, dpi))

    manifest: list = [None] * total
    completed = 0
    with cf.ProcessPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(_render_chunk, c): c for c in chunks}
        for fut in cf.as_completed(futures):
            for item in fut.result():
                if item.get("page"):
                    manifest[item["page"] - 1] = item
            completed += 1
            print(f"  chunks [{completed}/{len(chunks)}]", flush=True)

    return [m for m in manifest if m is not None]


def _compress_pages_dir(pages_dir: str) -> str:
    """将 pages_dir 打包为 pages.tar.gz，放在 pages_dir 内，解压后为 pages/ 目录。"""
    archive = os.path.join(pages_dir, "pages.tar.gz")
    with tarfile.open(archive, "w:gz") as tar:
        for name in os.listdir(pages_dir):
            fp = os.path.join(pages_dir, name)
            if os.path.isfile(fp):
                tar.add(fp, arcname=f"pages/{name}")
    return archive


def main():
    p = argparse.ArgumentParser(description="PDF 切图 (优先 mutool，否则 PyMuPDF)")
    p.add_argument("--pdf", required=True)
    p.add_argument("--pages-dir", required=True)
    p.add_argument("--dpi", type=int, default=200)
    p.add_argument("--workers", type=int, default=4,
                   help="PyMuPDF 引擎的并发进程数 (mutool 不需要，<1 走单进程)")
    p.add_argument("--compress", action="store_true",
                   help="切图完成后把图片目录打包为 tar.gz (解压后单层文件)")
    args = p.parse_args()

    t0 = time.perf_counter()
    mutool_bin = _detect_mutool()

    try:
        if mutool_bin:
            manifest = _split_with_mutool(args.pdf, args.pages_dir, args.dpi, mutool_bin)
            engine = "mutool"
        else:
            print(f"[split_pdf] 未检测到 mutool, 回退到 PyMuPDF", flush=True)
            manifest = _split_with_pymupdf(args.pdf, args.pages_dir, args.dpi, args.workers)
            engine = "pymupdf"
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"[split_pdf] mutool 失败: {e}\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"[split_pdf] 失败: {e}\n")
        sys.exit(1)

    elapsed = time.perf_counter() - t0
    total = len(manifest)
    avg_ms = (elapsed / total * 1000) if total else 0

    out = {
        "pdf": os.path.abspath(args.pdf),
        "total_pages": total,
        "dpi": args.dpi,
        "engine": engine,
        "elapsed_seconds": round(elapsed, 3),
        "avg_seconds_per_page": round(elapsed / total, 4) if total else 0,
        "pages": manifest,
    }
    with open(os.path.join(args.pages_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    if args.compress:
        archive = _compress_pages_dir(args.pages_dir)
        print(f"[split_pdf] 压缩完成: {archive}", flush=True)

    print(f"[split_pdf] 完成 ({engine}): {total} 页, 总耗时 {elapsed:.2f}s, 平均 {avg_ms:.1f}ms/页",
          flush=True)


if __name__ == "__main__":
    _ensure_spawn_start_method()
    main()
