#!/usr/bin/env python3
"""
将本地文件上传到 Google Drive 的 extractors/data/raw/ 目录。

首次使用:
    pip install -r requirements.txt
    将 OAuth 凭据放到 ~/.gazetteer_ocr/credentials.json

用法:
    python upload_to_drive.py /path/to/file.pdf
    python upload_to_drive.py /path/to/script.py
    python upload_to_drive.py /path/to/data.json --folder extractors/data/input
"""

import argparse
import os
import sys
import time

CONFIG_DIR = os.environ.get("GAZETTEER_CONFIG", os.path.expanduser("~/.gazetteer_ocr"))
CREDENTIALS_FILE = os.path.join(CONFIG_DIR, "credentials.json")
TOKEN_FILE = os.path.join(CONFIG_DIR, "token.json")
SCOPES = ["https://www.googleapis.com/auth/drive.file"]

PROXY_HOST = os.environ.get("GAZETTEER_PROXY_HOST", "127.0.0.1")
PROXY_PORT = int(os.environ.get("GAZETTEER_PROXY_PORT", "7897"))
PROXY_URL  = f"http://{PROXY_HOST}:{PROXY_PORT}"
# 大小写两套，httplib2 只看小写，requests 优先看大写
os.environ["HTTP_PROXY"] = PROXY_URL
os.environ["HTTPS_PROXY"] = PROXY_URL
os.environ["http_proxy"] = PROXY_URL
os.environ["https_proxy"] = PROXY_URL

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload, MediaIoBaseDownload

from io import BytesIO

def log(msg, level="INFO"):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] [{level}] {msg}"
    print(line, file=sys.stderr if level == "ERROR" else sys.stdout)
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def die(msg):
    log(msg, "ERROR")
    sys.exit(1)


def _make_http(creds):
    """创建带超时和认证的 httplib2.Http 实例（代理通过环境变量自动生效）

    注意：httplib2 0.32 显式传 proxy_info=ProxyInfo(...) 会触发 KeyError: 0，
    让 httplib2 用默认的 proxy_info_from_environment（每请求读 http_proxy/https_proxy）反而稳定。
    """
    import httplib2
    http = httplib2.Http(timeout=300)
    http.redirect_codes = frozenset(c for c in httplib2.REDIRECT_CODES if c != 308)
    _orig = http.request
    def authed_request(uri, method='GET', body=None, headers=None, *a, **kw):
        headers = dict(headers or {})
        creds.apply(headers)
        return _orig(uri, method, body, headers, *a, **kw)
    http.request = authed_request
    return http

def get_drive_service():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    creds = None

    if os.path.exists(TOKEN_FILE):
        creds = Credentials.from_authorized_user_file(TOKEN_FILE, SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            log("凭据已过期，正在刷新...")
            creds.refresh(Request())
        else:
            if not os.path.exists(CREDENTIALS_FILE):
                die(
                    f"未找到 OAuth 凭据文件: {CREDENTIALS_FILE}\n"
                    f"请将下载的 JSON 凭据放到该路径。\n"
                    f"获取步骤: https://console.cloud.google.com/apis/credentials\n"
                    f"→ 创建 OAuth 客户端 ID → 桌面应用 → 下载 JSON"
                )
            log("首次使用需要浏览器授权，即将打开浏览器...")
            flow = InstalledAppFlow.from_client_secrets_file(CREDENTIALS_FILE, SCOPES)
            creds = flow.run_local_server(port=0)
            log("授权成功")

        with open(TOKEN_FILE, "w") as token:
            token.write(creds.to_json())

    http = _make_http(creds)
    log(f"Google API 通过代理 {PROXY_URL} 连接 (超时 300s)")
    return build("drive", "v3", http=http)

def resolve_folder(service, folder_path):
    parts = [p for p in folder_path.strip("/").split("/") if p]
    parent_id = "root"
    for name in parts:
        query = (
            f"name='{name}' and mimeType='application/vnd.google-apps.folder' "
            f"and '{parent_id}' in parents and trashed=false"
        )
        results = service.files().list(q=query, fields="files(id, name)", pageSize=1).execute()
        files = results.get("files", [])
        if files:
            parent_id = files[0]["id"]
        else:
            folder = service.files().create(
                body={"name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parent_id]},
                fields="id"
            ).execute()
            parent_id = folder["id"]
    return parent_id


def upload_file(service, local_path, folder_id):
    from googleapiclient.http import MediaFileUpload

    filename = os.path.basename(local_path)
    query = f"name='{filename}' and '{folder_id}' in parents and trashed=false"
    results = service.files().list(q=query, fields="files(id)").execute()
    for f in results.get("files", []):
        service.files().delete(fileId=f["id"]).execute()

    # 根据扩展名推断 MIME
    ext = os.path.splitext(local_path)[1].lower()
    mime_map = {
        ".pdf": "application/pdf",
        ".py": "text/x-python",
        ".json": "application/json",
        ".txt": "text/plain",
        ".csv": "text/csv",
        ".sh": "text/x-shellscript",
        ".yaml": "text/yaml",
        ".yml": "text/yaml",
        ".md": "text/markdown",
        ".html": "text/html",
    }
    mime = mime_map.get(ext, "application/octet-stream")

    media = MediaFileUpload(local_path, mimetype=mime, resumable=True)
    file_meta = {"name": filename, "parents": [folder_id]}
    return service.files().create(body=file_meta, media_body=media, fields="id, name").execute()


def main():
    parser = argparse.ArgumentParser(description="上传文件到 Google Drive")
    parser.add_argument("file_path", help="本地文件路径（支持 .pdf/.py/.json 等）")
    parser.add_argument("--folder", default="extractors/data/raw", help="目标文件夹路径")
    args = parser.parse_args()

    if not os.path.exists(args.file_path):
        print(f"文件不存在: {args.file_path}")
        sys.exit(1)

    print(f"代理: {PROXY_URL}")
    print("测试 Google 连通性...")
    import urllib.request
    try:
        urllib.request.urlopen("https://www.googleapis.com/", timeout=10)
        print("  Google 可达")
    except Exception as e:
        print(f"  警告: {e}")

    print("连接 Google Drive...")
    service = get_drive_service()

    folder_id = resolve_folder(service, args.folder)
    uploaded = upload_file(service, args.file_path, folder_id)

    print(f"\n上传成功: MyDrive/{args.folder}/{uploaded['name']}")


if __name__ == "__main__":
    main()
