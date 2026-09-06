#!/usr/bin/env python3
"""GLM-OCR via vLLM OpenAI 兼容接口 (/v1/chat/completions)。

与 ocr_pipeline.py 同级, 但不走 paddleocr.PaddleOCRVL 中间层,
直接 base64 编图像、调 chat completions, 把 GLM-OCR 的 markdown 输出落盘。

输入: <pages-dir>/page_*.png
输出: <results-dir>/<out-subdir>/<base>.json + <base>.done (断点续跑)

    用法:
    python3 ocr_glm.py \\
        --pages-dir <pages> --results-dir <results> \\
        --api-base http://localhost:8000/v1 http://localhost:8001/v1 \\
        --model GLM-OCR \\
        [--workers 4] [--context-window 0] [--prompt PROMPT]

    支持多个 --api-base，文件按 round-robin 平均分配到各服务，每个服务并发数由 --workers 控制。
"""
import argparse
import base64
import concurrent.futures as cf
import glob
import json
import os
import re
import sys
import threading
import time


# ---------------------------------------------------------------------------
# GLM-OCR API helpers
# ---------------------------------------------------------------------------

def _image_as_data_url(image_path: str) -> str:
    """Encode image as data URL (base64)."""
    suffix = os.path.splitext(image_path)[1].lstrip(".").lower() or "png"
    if suffix == "jpg":
        suffix = "jpeg"
    mime = f"image/{suffix}"
    with open(image_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")
    return f"data:{mime};base64,{b64}"


def call_glm(client, model, image_path, prompt, max_tokens):
    """Call GLM-OCR via OpenAI-compatible /v1/chat/completions."""
    data_url = _image_as_data_url(image_path)
    resp = client.chat.completions.create(
        model=model,
        messages=[{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": data_url}},
                {"type": "text", "text": prompt},
            ],
        }],
        max_tokens=max_tokens,
        temperature=0.0,
    )
    return resp.choices[0].message.content


# ---------------------------------------------------------------------------
# 线程局部 client (多线程并发安全)
# ---------------------------------------------------------------------------

_thread_local = threading.local()


def _get_client(api_base, api_key):
    clients = getattr(_thread_local, "clients", None)
    if clients is None:
        clients = {}
        _thread_local.clients = clients
    c = clients.get(api_base)
    if c is None:
        from openai import OpenAI
        c = OpenAI(base_url=api_base, api_key=api_key)
        clients[api_base] = c
    return c


# ---------------------------------------------------------------------------
# 断点续跑
# ---------------------------------------------------------------------------

def _is_done(out_path: str) -> bool:
    return os.path.exists(out_path + ".done")


def _mark_done(out_path: str) -> None:
    if os.path.exists(out_path + ".done"):
        return
    tmp = out_path + ".done.tmp"
    with open(tmp, "w") as f:
        f.write("ok\n")
    os.replace(tmp, out_path + ".done")


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

DEFAULT_PROMPT = """你是古籍 OCR 助手。完整识别图中文字，按原文结构输出 markdown。
【阅读顺序】
- 竖排：每列从上到下，列与列从右到左
竖排，列从上到下，列间从右到左。
页面有两类字：
- 大字正文：占满整列、粗黑，是主体；**所有大字必须逐字识别、不漏**
- 双行小注：细字、占两窄列成对，是注释；视为一整块，先读右窄列再读左窄列，连读不拆
两者都要完整输出，缺一不可。
顺序：每段大字 → 紧接其后的双行小注 → 下一段大字……
例：大字 1 列 + 小注 1 块 → 先输出大字全文，再输出小注文，不调换、不省略。
【输出格式】
- 页眉、页脚、页码、印章保留原文
【字符】
- 保留繁体、异体字（如 經、縣、堡）
- 不确定时保留相似字形
- 不添加原文没有的字，不解释，不用 ``` 包裹
# context-window 预先生成 ctx 缓存时用更简洁 prompt, 只为产出连贯文本做上下文
"""

CTX_PROMPT = """OCR 此图像, 输出连贯可读的纯文本 (按阅读顺序, 竖排按列换行)。去版式坐标, 不要 markdown 包裹, 不要解释。"""


# ---------------------------------------------------------------------------
# 单页处理
# ---------------------------------------------------------------------------

def _process_one(page_path, out_path, client, model, prompt, max_tokens):
    base = os.path.splitext(os.path.basename(page_path))[0]
    try:
        text = call_glm(client, model, page_path, prompt, max_tokens)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump({
                "image": page_path,
                "model": model,
                "result": text,
                "prompt": prompt,
                "engine": "glm-ocr",
            }, f, ensure_ascii=False, indent=2)
        _mark_done(out_path)
        return True, text
    except Exception as e:
        return False, repr(e)


# ---------------------------------------------------------------------------
# context-window 预生成
# ---------------------------------------------------------------------------

def _ctx_path(out_dir, page_path):
    base = os.path.splitext(os.path.basename(page_path))[0]
    return os.path.join(out_dir, f"{base}.ctx.json")


def _generate_ctx_first_pass(page_paths_sorted, out_dir, client, model, max_tokens):
    cache = {}
    for page in page_paths_sorted:
        cp = _ctx_path(out_dir, page)
        if os.path.exists(cp):
            try:
                cache[os.path.basename(page)] = json.load(open(cp, encoding="utf-8")).get("raw_text", "")
                continue
            except Exception:
                pass
        try:
            text = call_glm(client, model, page, CTX_PROMPT, max_tokens)
            cache[os.path.basename(page)] = text
            with open(cp, "w", encoding="utf-8") as f:
                json.dump({"raw_text": text}, f, ensure_ascii=False, indent=2)
        except Exception as e:
            sys.stderr.write(f"[ocr_glm] ctx-error {page}: {e}\n")
            cache[os.path.basename(page)] = ""
    return cache


def _gather_context(cache, page_paths_sorted, target_idx, half):
    def base(p): return os.path.splitext(os.path.basename(p))[0]
    prev = [cache.get(base(p), "") for p in page_paths_sorted[max(0, target_idx - half):target_idx]]
    nxt  = [cache.get(base(p), "") for p in page_paths_sorted[target_idx + 1:min(len(page_paths_sorted), target_idx + 1 + half)]]
    return "\n\n".join(t for t in prev if t), "\n\n".join(t for t in nxt if t)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def recognize_pages(pages_dir, results_dir, out_subdir,
                   api_bases, api_key, model,
                   workers, max_tokens, prompt, context_window,
                   pdf_basename=""):
    pages = sorted(glob.glob(os.path.join(pages_dir, "page_*.png")))
    if not pages:
        print(f"[ocr_glm] {pages_dir} 下未找到 page_*.png", flush=True)
        return 0

    out_dir = results_dir if not out_subdir else os.path.join(results_dir, out_subdir)
    os.makedirs(out_dir, exist_ok=True)

    # 上下文预生成（用第一个服务）
    text_cache = None
    if context_window > 0:
        client0 = _get_client(api_bases[0], api_key)
        print(f"[ocr_glm] context-window={context_window}: 预生成每页 ctx", flush=True)
        text_cache = _generate_ctx_first_pass(pages, out_dir, client0, model, max_tokens)

    tasks = []
    skipped = 0
    for page in pages:
        base = os.path.splitext(os.path.basename(page))[0]
        out_path = os.path.join(out_dir, f"{base}.json")
        if _is_done(out_path):
            skipped += 1
            continue
        tasks.append((page, out_path))

    if not tasks:
        print(f"[ocr_glm] 全部 {len(pages)} 张均已完成 (跳过)", flush=True)
        _write_summary(out_dir, pages, skipped, total=len(pages), elapsed=0)
        return 0

    n_svc = len(api_bases)
    print(f"[ocr_glm] 共 {len(pages)} 张 | 跳过已完成 {skipped} | 待识别 {len(tasks)} | "
          f"服务数={n_svc} | workers/服务={workers} | context-window={context_window}", flush=True)

    # round-robin 分配到各服务
    chunks = [[] for _ in range(n_svc)]
    for i, task in enumerate(tasks):
        chunks[i % n_svc].append(task)
    for i, c in enumerate(chunks):
        print(f"  [分配] 服务{i}: {len(c)} 页", flush=True)

    err_count = 0
    completed = 0
    total_tasks = len(tasks)
    t0 = time.perf_counter()
    lock = threading.Lock()

    def submit(item, svc_idx):
        page_path, out_path = item
        client = _get_client(api_bases[svc_idx], api_key)
        clean = re.sub(r"^[a-zA-Z0-9]+", "", pdf_basename)
        full_prompt = f"你接下来要处理的文件是{clean}\n\n{prompt}"
        if text_cache is not None:
            idx = pages.index(page_path)
            prev_t, next_t = _gather_context(text_cache, pages, idx, context_window)
            if prev_t:
                full_prompt += f"\n\n【上一页 (作上下文)】\n{prev_t}"
            if next_t:
                full_prompt += f"\n\n【下一页 (作上下文)】\n{next_t}"
        ok, payload = _process_one(page_path, out_path, client, model, full_prompt, max_tokens)
        return item, ok, payload, svc_idx

    all_futures = []
    executors = []
    try:
        for svc_idx, chunk in enumerate(chunks):
            if not chunk:
                continue
            ex = cf.ThreadPoolExecutor(max_workers=workers)
            executors.append(ex)
            for task in chunk:
                all_futures.append(ex.submit(submit, task, svc_idx))

        for fut in cf.as_completed(all_futures):
            item, ok, payload, svc_idx = fut.result()
            page_path, out_path = item
            base = os.path.splitext(os.path.basename(page_path))[0]
            if ok:
                with lock:
                    completed += 1
                chars = len(payload) if isinstance(payload, str) else 0
                print(f"  [{completed}/{total_tasks}] [{api_bases[svc_idx]}] {base}: ok ({chars} chars)", flush=True)
            else:
                with lock:
                    err_count += 1
                print(f"  ERR [{api_bases[svc_idx]}] {base}: {payload}", flush=True)
    finally:
        for ex in executors:
            ex.shutdown(wait=False)

    elapsed = time.perf_counter() - t0
    avg = (elapsed / completed * 1000) if completed else 0
    print(f"[ocr_glm] 完成: 成功 {completed} / 失败 {err_count} | "
          f"本次耗时 {elapsed:.2f}s | 平均 {avg:.0f}ms/页", flush=True)

    _write_summary(out_dir, pages, skipped, total=len(pages), elapsed=elapsed)
    return 0 if err_count == 0 else 1


def _write_summary(out_dir, pages, skipped, total, elapsed):
    summary = {
        "engine": "glm-ocr",
        "total_pages": total,
        "skipped_pages": skipped,
        "elapsed_seconds": round(elapsed, 3),
        "pages": sorted(os.path.splitext(os.path.basename(p))[0] for p in pages),
    }
    with open(os.path.join(out_dir, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)


def main():
    p = argparse.ArgumentParser(description="GLM-OCR via vLLM OpenAI 兼容接口")
    p.add_argument("--pages-dir", required=True)
    p.add_argument("--results-dir", required=True)
    p.add_argument("--api-base", required=True, nargs="+",
                   help="vLLM 服务地址 (支持多个, 文件平均分配到各服务)")
    p.add_argument("--api-key", default=os.environ.get("LLM_API_KEY", "dummy"))
    p.add_argument("--model", default="GLM-OCR")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--max-tokens", type=int, default=1024)
    p.add_argument("--context-window", type=int, default=0)
    p.add_argument("--out-subdir", default="")
    p.add_argument("--prompt", default=DEFAULT_PROMPT)
    p.add_argument("--pdf-basename", default="",
                   help="原始 PDF 名称 (不含 .pdf), 注入 prompt 提升识别准确率")
    args = p.parse_args()

    sys.exit(recognize_pages(
        args.pages_dir, args.results_dir, args.out_subdir,
        args.api_base, args.api_key, args.model,
        args.workers, args.max_tokens, args.prompt, args.context_window,
        args.pdf_basename,
    ) or 0)


if __name__ == "__main__":
    main()
