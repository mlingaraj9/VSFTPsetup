#!/usr/bin/env python3
import os
import json
import time
import shutil
import hashlib
import logging
from logging.handlers import RotatingFileHandler
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import xml.etree.ElementTree as ET

import requests


# ---------------------- Helpers ----------------------
NY_TZ = ZoneInfo("America/New_York")

def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    # Minimal defaults
    cfg.setdefault("poll_seconds", 2)
    cfg.setdefault("delete_after_seconds", 3 * 3600)
    cfg.setdefault("request_timeout_seconds", 10)
    cfg.setdefault("verify_tls", False)
    cfg.setdefault("max_log_bytes", 100 * 1024 * 1024)
    cfg.setdefault("endpoints", [])
    cfg.setdefault("camera_name_map", {})
    return cfg

def setup_logger(log_path: str, max_bytes: int) -> logging.Logger:
    logger = logging.getLogger("cmprs_forwarder")
    logger.setLevel(logging.INFO)

    handler = RotatingFileHandler(
        log_path,
        maxBytes=max_bytes,
        backupCount=1,  # keep 1 old file; total <= ~200MB worst case
        encoding="utf-8"
    )
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    handler.setFormatter(fmt)
    logger.addHandler(handler)

    # Also log to console (useful during testing)
    console = logging.StreamHandler()
    console.setFormatter(fmt)
    logger.addHandler(console)

    return logger

def safe_get_text(root: ET.Element, tag: str) -> str | None:
    el = root.find(tag)
    if el is None or el.text is None:
        return None
    t = el.text.strip()
    return t if t else None

def parse_utc_capture_dt(root: ET.Element) -> str:
    """
    XML has UTCDate like '2026:02:04' and UTCTime like '13:40:28'.
    Convert to America/New_York and format like 2026-02-04T08:40:28-0500
    """
    utc_date = safe_get_text(root, "UTCDate")
    utc_time = safe_get_text(root, "UTCTime")

    if not utc_date or not utc_time:
        # Fallback: now in NY
        dt_ny = datetime.now(timezone.utc).astimezone(NY_TZ)
        return dt_ny.strftime("%Y-%m-%dT%H:%M:%S%z")

    # Normalize date format
    # Expected: YYYY:MM:DD
    y, m, d = utc_date.split(":")
    hh, mm, ss = utc_time.split(":")

    dt_utc = datetime(int(y), int(m), int(d), int(hh), int(mm), int(ss), tzinfo=timezone.utc)
    dt_ny = dt_utc.astimezone(NY_TZ)
    return dt_ny.strftime("%Y-%m-%dT%H:%M:%S%z")

def xml_to_json_payload(xml_path: str, camera_name_map: dict) -> dict:
    tree = ET.parse(xml_path)
    root = tree.getroot()

    plate = safe_get_text(root, "Plate") or "UNKNOWN"
    guid = safe_get_text(root, "Guid") or ""
    xml_cam = safe_get_text(root, "CameraName") or ""

    mapped_cam = camera_name_map.get(xml_cam, xml_cam)  # if not found, keep original

    lat = safe_get_text(root, "Latitude")
    lon = safe_get_text(root, "Longitude")

    # Images are already base64 in XML (no data:image prefix in your sample)
    scene_b64 = safe_get_text(root, "ContextImage") or ""
    patch_b64 = safe_get_text(root, "PlateImage") or ""

    # Convert timestamp to EST/EDT
    capture_dt = parse_utc_capture_dt(root)

    payload = {
        "CameraName": mapped_cam,
        "CaptureDt": capture_dt,
        "MessageID": guid,
        "PlateText": plate,
        "Coordinates": {
            "Latitude": float(lat) if lat else 0.0,
            "Longitude": float(lon) if lon else 0.0
        },
        "SceneImage": scene_b64,
        "PatchImage": patch_b64,

        # Fields not in XML (set null; endpoints can ignore)
        "CountryCode": None,
        "StateCode": None,
        "VehicleMake": None,
        "VehicleModel": None,
        "VehicleColor": None,
        "PlateConfidenceNbr": None,
        "MakeConfidenceNbr": None,
        "ModelConfidenceNbr": None,
        "ColorConfidenceNbr": None,
        "StateConfidenceNbr": None
    }
    return payload

def file_id(path: str) -> str:
    """
    Stable id for state tracking, based on path + size + mtime.
    Cheap and good enough.
    """
    st = os.stat(path)
    key = f"{os.path.basename(path)}|{st.st_size}|{int(st.st_mtime)}"
    return hashlib.sha1(key.encode("utf-8")).hexdigest()

def load_state(state_path: str) -> dict:
    if not os.path.exists(state_path):
        return {"files": {}}
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"files": {}}

def save_state(state_path: str, state: dict) -> None:
    tmp = state_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, state_path)

def all_endpoints_succeeded(file_state: dict, endpoints: list[str]) -> bool:
    results = file_state.get("results", {})
    return all(results.get(ep, {}).get("ok") is True for ep in endpoints)

def now_ts() -> int:
    return int(time.time())


# ---------------------- Main loop ----------------------
def main():
    cfg = load_config("config.json")
    watch_dir = cfg["watch_dir"]
    endpoints = cfg["endpoints"]
    cam_map = cfg["camera_name_map"]

    poll_seconds = int(cfg["poll_seconds"])
    delete_after = int(cfg["delete_after_seconds"])
    timeout = int(cfg["request_timeout_seconds"])
    verify_tls = bool(cfg["verify_tls"])

    state_path = os.path.join(watch_dir, ".cmprs_forwarder_state.json")
    logger = setup_logger(cfg["log_file"], int(cfg["max_log_bytes"]))

    logger.info(f"Starting forwarder. watch_dir={watch_dir} endpoints={endpoints} delete_after={delete_after}s")

    # Ensure watch dir exists
    os.makedirs(watch_dir, exist_ok=True)

    # Create a small subfolder for processed files (optional safety)
    processed_dir = os.path.join(watch_dir, "_processed")
    os.makedirs(processed_dir, exist_ok=True)

    session = requests.Session()

    while True:
        state = load_state(state_path)
        files_state = state.setdefault("files", {})

        # 1) Find candidate XMLs (ignore temp and our processed folder)
        try:
            names = os.listdir(watch_dir)
        except Exception as e:
            logger.error(f"Cannot list watch_dir: {e}")
            time.sleep(poll_seconds)
            continue

        xml_files = []
        for n in names:
            if n.startswith("."):
                continue
            if n == "_processed":
                continue
            if not n.lower().endswith(".xml"):
                continue
            # Some cameras upload .xml.temp then rename; we only take final .xml
            if n.lower().endswith(".xml.temp"):
                continue
            xml_files.append(os.path.join(watch_dir, n))

        # 2) Send any not-yet-successful files
        for path in sorted(xml_files):
            try:
                fid = file_id(path)
            except FileNotFoundError:
                continue

            entry = files_state.get(fid) or {
                "path": path,
                "first_seen": now_ts(),
                "last_attempt": 0,
                "success_ts": None,
                "results": {}
            }

            # If already successful everywhere, skip (deletion handled later)
            if all_endpoints_succeeded(entry, endpoints):
                files_state[fid] = entry
                continue

            # Avoid hammering (try at most once per poll)
            if now_ts() - int(entry.get("last_attempt", 0)) < poll_seconds:
                files_state[fid] = entry
                continue

            # Build payload
            try:
                payload = xml_to_json_payload(path, cam_map)
                sanitized = dict(payload)  # shallow copy is enough
                sanitized.pop("SceneImage", None)
                sanitized.pop("PatchImage", None)

                logger.info(
                    "PAYLOAD file=%s json=%s",
                    os.path.basename(path),
                    json.dumps(sanitized, separators=(",", ":"))
                )
            except Exception as e:
                logger.error(f"XML parse/map failed: file={path} err={e}")
                entry["last_attempt"] = now_ts()
                # Mark failure for all endpoints this round (optional)
                files_state[fid] = entry
                continue

            entry["last_attempt"] = now_ts()
            entry["path"] = path

            # Post to each endpoint
            all_ok = True
            for ep in endpoints:
                ok = False
                err = ""
                code = None
                try:
                    r = session.post(ep, json=payload, timeout=timeout, verify=verify_tls)
                    code = r.status_code
                    ok = (200 <= r.status_code < 300)
                    if not ok:
                        err = (r.text or "")[:300]
                except Exception as e:
                    err = str(e)[:300]

                entry["results"][ep] = {
                    "ok": ok,
                    "http": code,
                    "err": err,
                    "ts": now_ts()
                }

                if ok:
                    logger.info(f"SEND OK file={os.path.basename(path)} endpoint={ep} http={code}")
                else:
                    all_ok = False
                    logger.warning(f"SEND FAIL file={os.path.basename(path)} endpoint={ep} http={code} err={err}")

            if all_ok:
                entry["success_ts"] = now_ts()

                # Optional: move to _processed immediately to avoid re-upload by accident,
                # but we still keep it for delayed deletion.
                try:
                    base = os.path.basename(path)
                    moved_path = os.path.join(processed_dir, base)
                    if os.path.abspath(path) != os.path.abspath(moved_path):
                        # Only move if not already moved
                        if os.path.exists(path):
                            shutil.move(path, moved_path)
                            entry["path"] = moved_path
                            logger.info(f"MOVED to processed: {base}")
                except Exception as e:
                    # Not fatal; keep path as-is
                    logger.warning(f"Could not move to _processed: file={path} err={e}")

            files_state[fid] = entry

        # 3) Delete only files that succeeded AND are older than delete_after since success_ts
        now = now_ts()
        to_delete = []
        for fid, entry in list(files_state.items()):
            success_ts = entry.get("success_ts")
            if not success_ts:
                continue
            if not all_endpoints_succeeded(entry, endpoints):
                continue
            if now - int(success_ts) < delete_after:
                continue

            p = entry.get("path")
            if p and os.path.exists(p):
                try:
                    os.remove(p)
                    logger.info(f"DELETED after delay: {os.path.basename(p)}")
                except Exception as e:
                    logger.warning(f"Delete failed: file={p} err={e}")
                    continue

            to_delete.append(fid)

        # Prune deleted entries to keep state small
        for fid in to_delete:
            files_state.pop(fid, None)

        # Save state
        save_state(state_path, state)

        time.sleep(poll_seconds)


if __name__ == "__main__":
    main()