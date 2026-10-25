"""腾讯云「图像切边增强」预处理：切边 + 弯曲矫正 + 去阴影 + 摆正，只留页内区域。

用途：把「拍照得到的课本页」变成「接近扫描件的单页图」，再交给 OCR/VLM。

密钥来源（二选一，都不入库）：
  1) validation/B0A/config.json 里加一段：
     "tencent": { "secret_id": "AKID...", "secret_key": "..." }
  2) 环境变量 TENCENT_SECRET_ID / TENCENT_SECRET_KEY

用法：
  python scripts/preprocess_doc.py --images artifacts/b2-final/thumb_1.jpg \
      --out-dir artifacts/b2-final/cropped [--enhance 5] [--no-deskew]
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "validation" / "B0A" / "config.json"
HOST = "ocr.tencentcloudapi.com"
SERVICE = "ocr"
VERSION = "2018-11-19"
ACTION = "CropEnhanceImageOCR"


def credentials() -> tuple[str, str]:
    sid = os.environ.get("TENCENT_SECRET_ID", "")
    skey = os.environ.get("TENCENT_SECRET_KEY", "")
    if sid and skey:
        return sid, skey
    if CONFIG.exists():
        d = json.loads(CONFIG.read_text(encoding="utf-8"))
        t = d.get("tencent") or {}
        sid = sid or t.get("secret_id", "")
        skey = skey or t.get("secret_key", "")
    if not sid or not skey:
        raise SystemExit("缺少腾讯云密钥：在 validation/B0A/config.json 加 tencent.secret_id/secret_key，"
                         "或设 TENCENT_SECRET_ID / TENCENT_SECRET_KEY 环境变量")
    return sid, skey


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _sha256_hex(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def sign_and_post(payload: dict, sid: str, skey: str) -> dict:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    ts = int(time.time())
    date = time.strftime("%Y-%m-%d", time.gmtime(ts))

    canonical_request = "\n".join([
        "POST", "/", "",
        "content-type:application/json; charset=utf-8",
        f"host:{HOST}", "",
        "content-type;host",
        _sha256_hex(body),
    ])
    credential_scope = f"{date}/{SERVICE}/tc3_request"
    string_to_sign = "\n".join([
        "TC3-HMAC-SHA256", str(ts), credential_scope, _sha256_hex(canonical_request),
    ])
    k_date = _hmac(f"TC3{skey}".encode("utf-8"), date)
    k_service = _hmac(k_date, SERVICE)
    k_signing = _hmac(k_service, "tc3_request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    authorization = (f"TC3-HMAC-SHA256 Credential={sid}/{credential_scope}, "
                     f"SignedHeaders=content-type;host, Signature={signature}")

    req = urllib.request.Request(
        f"https://{HOST}/",
        data=body,
        headers={
            "Authorization": authorization,
            "Content-Type": "application/json; charset=utf-8",
            "Host": HOST,
            "X-TC-Action": ACTION,
            "X-TC-Timestamp": str(ts),
            "X-TC-Version": VERSION,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))["Response"]


def process(path: Path, out_dir: Path, enhance: int, deskew: bool, sid: str, skey: str) -> None:
    payload = {
        "ImageBase64": base64.b64encode(path.read_bytes()).decode("ascii"),
        "Crop": 1,
        "Deskew": 1 if deskew else 0,
        "OnlyPosition": 0,
        "EnhanceType": enhance,
        "AdjustOrientation": 1,
    }
    resp = sign_and_post(payload, sid, skey)
    if "Error" in resp:
        print(f"{path.name}: ERROR {resp['Error'].get('Code')} {resp['Error'].get('Message')}")
        return

    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{path.stem}_cropped.jpg"
    url = resp.get("CroppedImageUrl", "")
    if url:
        urllib.request.urlretrieve(url, out)
    else:  # 兼容旧字段
        b64 = resp.get("CroppedImage", "")
        out.write_bytes(base64.b64decode(b64))
    pos = resp.get("Position", [])
    print(f"{path.name}: {resp.get('CroppedWidth')}x{resp.get('CroppedHeight')} "
          f"angle={resp.get('Angle')} corners={pos} -> {out.name}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", nargs="+", required=True)
    ap.add_argument("--out-dir", default=str(ROOT / "artifacts/b2-final/cropped"))
    ap.add_argument("--enhance", type=int, default=5, help="-1 不增强 1 增亮 2 锐化 3 黑白 4 灰度 5 去阴影 6 点阵")
    ap.add_argument("--no-deskew", action="store_true", help="关闭弯曲矫正")
    args = ap.parse_args()

    sid, skey = credentials()
    for img in args.images:
        process(Path(img), Path(args.out_dir), args.enhance, not args.no_deskew, sid, skey)


if __name__ == "__main__":
    main()
