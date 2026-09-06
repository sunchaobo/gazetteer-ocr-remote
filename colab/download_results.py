#!/usr/bin/env python3
"""
从 Google Drive 下载 gazetteer_ocr/output/ 目录下的 OCR 结果到本地。

用法:
    python download_results.py                         # 下载所有
    python download_results.py --latest                # 仅最新
    python download_results.py --output ./my_results   # 指定目录
"""

import os
import sys
import argparse

CONFIG_DIR = os.environ.get("GAZETTEER_CONFIG", os.path.expanduser("~/.gazetteer_ocr"))
CREDENTIALS_FILE = os.path.join(CONFIG_DIR, "credentials.json")
TOKEN_FILE = os.path.join(CONFIG_DIR, "token_dl.json")
SCOPES = ["https://www.googleapis.com/auth/drive.readonly"]

PROXY_HOST = os.environ.get("GAZETTEER_PROXY_HOST", "127.0.0.1")
PROXY_PORT = int(os.environ.get("GAZETTEER_PROXY_PORT", "7897"))
PROXY_URL  = f"http://{PROXY_HOST}:{PROXY_PORT}"
os.environ.setdefault("HTTP_PROXY",  PROXY_URL)
os.environ.setdefault("HTTPS_PROXY", PROXY_URL)
os.environ.setdefault("http_proxy",  PROXY_URL)
os.environ.setdefault("https_proxy", PROXY_URL)


def get_drive_service():
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    os.makedirs(CONFIG_DIR, exist_ok=True)
    creds = None

    if os.path.exists(TOKEN_FILE):
        creds = Credentials.from_authorized_user_file(TOKEN_FILE, SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not os.path.exists(CREDENTIALS_FILE):
                print(f"未找到 OAuth 凭据: {CREDENTIALS_FILE}")
                sys.exit(1)
            flow = InstalledAppFlow.from_client_secrets_file(CREDENTIALS_FILE, SCOPES)
            creds = flow.run_local_server(port=0)
        with open(TOKEN_FILE, "w") as token:
            token.write(creds.to_json())

    import httplib2
    http = httplib2.Http(timeout=60)
    _orig = http.request
    def authed_request(uri, method='GET', body=None, headers=None, *a, **kw):
        headers = dict(headers or {})
        creds.apply(headers)
        return _orig(uri, method, body, headers, *a, **kw)
    http.request = authed_request
    return build("drive", "v3", http=http)


def find_folder(service, folder_path):
    parts = [p for p in folder_path.strip("/").split("/") if p]
    parent_id = "root"
    for name in parts:
        query = (
            f"name='{name}' and mimeType='application/vnd.google-apps.folder' "
            f"and '{parent_id}' in parents and trashed=false"
        )
        results = service.files().list(q=query, fields="files(id, name)", pageSize=1).execute()
        files = results.get("files", [])
        if not files:
            return None
        parent_id = files[0]["id"]
    return parent_id


def download_file(service, file_id, local_path):
    from googleapiclient.http import MediaIoBaseDownload

    request = service.files().get_media(fileId=file_id)
    os.makedirs(os.path.dirname(local_path) or ".", exist_ok=True)
    with open(local_path, "wb") as f:
        downloader = MediaIoBaseDownload(f, request)
        done = False
        while not done:
            _, done = downloader.next_chunk()
    return local_path


def main():
    parser = argparse.ArgumentParser(description="从 Google Drive 下载 OCR 结果")
    parser.add_argument("--folder", default="gazetteer_ocr/output", help="源文件夹路径")
    parser.add_argument("--output", "-o", default="./ocr_results", help="本地保存目录")
    parser.add_argument("--latest", action="store_true", help="只下载最新一批")
    args = parser.parse_args()

    print("连接 Google Drive...")
    service = get_drive_service()

    folder_id = find_folder(service, args.folder)
    if not folder_id:
        print(f"文件夹不存在: {args.folder}（请先在 Colab 中运行 OCR 生成结果）")
        sys.exit(1)

    query = f"'{folder_id}' in parents and trashed=false"
    files = service.files().list(q=query, fields="files(id, name, createdTime)", pageSize=100).execute().get("files", [])

    if not files:
        print("没有找到结果文件")
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)

    if args.latest:
        files.sort(key=lambda f: f["createdTime"], reverse=True)
        seen = set()
        latest = []
        for f in files:
            name = f["name"]
            base = name.rsplit("_ocr_", 1)[0] if "_ocr_" in name else name
            if base not in seen:
                seen.add(base)
                latest.append(f)
        files = latest

    print(f"下载 {len(files)} 个文件到 {args.output}/ ...")
    for f in files:
        local_path = os.path.join(args.output, f["name"])
        print(f"  {f['name']} ...", end=" ")
        download_file(service, f["id"], local_path)
        print("OK")

    print(f"\n完成: {os.path.abspath(args.output)}")


if __name__ == "__main__":
    main()
