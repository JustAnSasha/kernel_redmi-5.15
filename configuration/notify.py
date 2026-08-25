import json
import os
import subprocess
import urllib.parse
import urllib.request
import uuid

TOKEN = os.environ.get("TELEGRAM_TOKEN", "")
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
STATUS = os.environ.get("BUILD_STATUS", "unknown")
RUN_URL = os.environ.get("RUN_URL", "")
VARIANT = os.environ.get("VARIANT", "?")
BRANCH = os.environ.get("KERNEL_BRANCH", "?")
KERNEL_VERSION = os.environ.get("KERNEL_VERSION", "5.15")
SPOOFED_VERSION = os.environ.get("SPOOFED_VERSION", "")
LOCAL_VERSION = os.environ.get("LOCAL_VERSION", "")
CLANG = os.environ.get("CLANG_VERSION", "?")
LTO = os.environ.get("LTO_TYPE", "?")
OPT = os.environ.get("OPT_LEVEL", "?")
TICK = os.environ.get("TICK_RATE", "?")
SUSFS = os.environ.get("ENABLE_SUSFS", "false")
BBG = os.environ.get("BBG", "off")
KPM = os.environ.get("KPM", "off")
DROIDSPACES = os.environ.get("DROIDSPACES", "off")
INTEGRITY = os.environ.get("SPOOF_INTEGRITY", "off")
DLKM = os.environ.get("SYSTEM_DLKM_PACKED", "false")
KSUVER = os.environ.get("KSUVER", "")
ZIP_PATH = os.environ.get("ZIP_PATH", "")
ZIP_NAME = os.environ.get("ZIP_NAME", "kernel")

DEVICE = "Redmi Note 12 4G (topaz/tapas) · Redmi Note 13 4G (sapphire/sapphiren)"


def enabled(value):
    return str(value).lower() in ("true", "on", "yes", "1")


def mark(flag):
    return "\u2705" if enabled(flag) else "\u274c"


def api(method, **data):
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    request = urllib.request.Request(url, urllib.parse.urlencode(data).encode())
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except Exception as error:
        print(f"telegram {method} failed: {error}")
        return None


def send_document(path, caption):
    boundary = uuid.uuid4().hex
    name = os.path.basename(path)
    with open(path, "rb") as file:
        payload = file.read()

    parts = []
    for field in (("chat_id", CHAT_ID), ("caption", caption), ("parse_mode", "HTML")):
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field[0]}\"\r\n\r\n{field[1]}\r\n".encode()
        )
    parts.append(
        (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{name}\"\r\n"
            "Content-Type: application/zip\r\n\r\n"
        ).encode()
        + payload
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())

    request = urllib.request.Request(
        f"https://api.telegram.org/bot{TOKEN}/sendDocument",
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return json.load(response)
    except Exception as error:
        print(f"upload failed: {error}")
        return None


def caption():
    title = "\u2705 Kernel Build Successful" if STATUS == "success" else "\u274c Kernel Build Failed"
    lines = [
        f"<b>{title}</b>\n",
        f"<b>\U0001f4e6 Build Information:</b>",
        f"\u2022 Kernel: Linux {KERNEL_VERSION}",
        f"\u2022 Devices: <b>{DEVICE}</b>",
        f"\u2022 Branch: <code>{BRANCH}</code>",
    ]
    if SPOOFED_VERSION:
        lines.append(f"\u2022 Spoofed to: <code>{SPOOFED_VERSION}{LOCAL_VERSION}</code>")
    if STATUS != "success":
        lines += ["", f'<a href="{RUN_URL}">\U0001f50d Check the logs</a>']
        return "\n".join(lines)
    lines += [
        "",
        f"<b>\u26a1KSU Variant:</b>",
        f"\u2022 Variant: <b>{VARIANT}</b> <code>({KSUVER})</code>" if VARIANT != "Vanilla" else "\u2022 Variant: <b>Vanilla</b> (no root)",
        f"\u2022 SuSFS: {mark(SUSFS)} {'Enabled' if enabled(SUSFS) else 'Disabled'}",
        f"\u2022 Baseband Guard: {mark(BBG)} {'Enabled' if enabled(BBG) else 'Disabled'}",
        f"\u2022 KPM: {mark(KPM)} {'Enabled' if enabled(KPM) else 'Disabled'}",
        f"\u2022 Droidspaces: {mark(DROIDSPACES)} {'Enabled' if enabled(DROIDSPACES) else 'Disabled'}",
        f"\u2022 Integrity Spoof: {mark(INTEGRITY)} {'Enabled' if enabled(INTEGRITY) else 'Disabled'}",
        f"\u2022 system_dlkm packed: {mark(DLKM)}",
        "",
        f"<i>Clang {CLANG} \u00b7 LTO {LTO} \u00b7 -{OPT} \u00b7 {TICK}Hz</i>",
        f'<a href="{RUN_URL}">\U0001f50d View build</a>',
    ]
    return "\n".join(lines)


def main():
    if not TOKEN or not CHAT_ID:
        print("no telegram secrets set, skipping notify")
        return

    text = caption()
    zip_file = None

    if STATUS == "success" and ZIP_PATH and os.path.isdir(ZIP_PATH):
        zip_file = f"/tmp/{ZIP_NAME}.zip"
        subprocess.run(["zip", "-q", "-r9", zip_file, "./"], cwd=ZIP_PATH, check=True)

    if zip_file and os.path.isfile(zip_file):
        send_document(zip_file, text)
    else:
        api("sendMessage", chat_id=CHAT_ID, text=text, parse_mode="HTML")


if __name__ == "__main__":
    main()
