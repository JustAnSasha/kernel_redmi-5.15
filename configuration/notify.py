import os
import sys
import urllib.request
import urllib.parse
import json

TOKEN = os.environ.get("TELEGRAM_TOKEN")
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID")
STATUS = os.environ.get("BUILD_STATUS", "unknown")
RUN_URL = os.environ.get("RUN_URL", "")
VARIANT = os.environ.get("VARIANT", "?")
BRANCH = os.environ.get("KERNEL_BRANCH", "?")
CLANG = os.environ.get("CLANG_VERSION", "?")
LTO = os.environ.get("LTO_TYPE", "?")
OPT = os.environ.get("OPT_LEVEL", "?")
TICK = os.environ.get("TICK_RATE", "?")
SUSFS = os.environ.get("ENABLE_SUSFS", "false")
BBG = os.environ.get("BBG", "off")
KPM = os.environ.get("KPM", "off")
SPOOF = os.environ.get("SPOOF_INTEGRITY", "off")
KSUVER = os.environ.get("KSUVER", "")
ZIP_PATH = os.environ.get("ZIP_PATH", "")

DEVICE = "Redmi Note 12/13 4G NFC"


def on(v):
    return str(v).lower() in ("true", "on", "yes", "1")


def api(method, **data):
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    req = urllib.request.Request(url, urllib.parse.urlencode(data).encode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except Exception as e:
        print(f"telegram {method} failed: {e}")
        return None


def send_document(path, caption):
    import uuid
    boundary = uuid.uuid4().hex
    name = os.path.basename(path)
    with open(path, "rb") as f:
        payload = f.read()

    parts = []
    for field in (("chat_id", CHAT_ID), ("caption", caption), ("parse_mode", "HTML")):
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field[0]}\"\r\n\r\n{field[1]}\r\n".encode()
        )
    parts.append(
        (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{name}\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n"
        ).encode()
        + payload
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TOKEN}/sendDocument",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.load(r)
    except Exception as e:
        print(f"upload failed: {e}")
        return None


def build_caption():
    if STATUS != "success":
        return (
            "<b>❌ Shining Kernel Build Failed</b>\n\n"
            f"• Variant: <b>{VARIANT}</b>\n"
            f"• Branch: {BRANCH}\n"
            f'• <a href="{RUN_URL}">View logs</a>'
        )

    ksu_line = f" ({KSUVER})" if KSUVER else ""
    return (
        "<b>✅ Shining Kernel Build Successful</b>\n\n"
        "<b>📦 Build Info</b>\n"
        f"• Variant: <b>{VARIANT}</b>{ksu_line}\n"
        f"• Kernel: Linux 5.15 (Android 13)\n"
        f"• Device: {DEVICE}\n"
        f"• Branch: {BRANCH}\n"
        f"• Clang: {CLANG} | LTO: {LTO} | -{OPT} | {TICK}Hz\n\n"
        "<b>⚙️ Features</b>\n"
        f"{'✅' if on(SUSFS) else '❌'} SuSFS\n"
        f"{'✅' if on(BBG) else '❌'} Baseband Guard\n"
        f"{'✅' if on(KPM) else '❌'} KPM\n"
        f"{'✅' if on(SPOOF) else '❌'} Integrity Spoof\n\n"
        f'<a href="{RUN_URL}">🔍 View build</a>'
    )


def main():
    if not TOKEN or not CHAT_ID:
        print("no telegram secrets set, skipping notify")
        return

    caption = build_caption()
    zip_file = None

    if STATUS == "success" and ZIP_PATH and os.path.isdir(ZIP_PATH):
        import subprocess
        zip_file = f"/tmp/{os.environ.get('ZIP_NAME', 'kernel')}.zip"
        subprocess.run(["zip", "-q", "-r9", zip_file, "./"], cwd=ZIP_PATH, check=True)

    if zip_file and os.path.isfile(zip_file):
        send_document(zip_file, caption)
    else:
        api("sendMessage", chat_id=CHAT_ID, text=caption, parse_mode="HTML")


if __name__ == "__main__":
    main()
