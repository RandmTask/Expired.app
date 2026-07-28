#!/usr/bin/env python3
"""
One-time/incremental dev tool — NOT run at build time or in CI.

Fetches App Store artwork for every AppCatalog.json entry that (a) has an
appStoreId, (b) is global (no "regions" field, or entry explicitly flagged
onboarding: true), and (c) doesn't already have a populated imageset —
then bakes each into a "Single Scale" imageset in Assets.xcassets/OnboardingIcons/.

Single Scale (one 180x180 PNG, no separate 1x/2x/3x files) is deliberate: a
180px source is sharp at a 60pt/@3x tile and SwiftUI only ever downsamples it
for 1x/2x, never upsamples, so one file is enough — see
_shared/onboarding-conventions.md "Bundle icons for the global core only".

Usage:
    python3 bin/fetch-onboarding-icons.py            # fetch what's missing
    python3 bin/fetch-onboarding-icons.py --force     # re-fetch everything
    python3 bin/fetch-onboarding-icons.py --region AU # also include that region's pack

Requires: curl, sips (both ship with macOS). No pip dependencies.
"""

import argparse
import json
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "Resources" / "AppCatalog.json"
ASSETS_DIR = ROOT / "Expired" / "Assets.xcassets" / "OnboardingIcons"
ICON_SIZE = 180  # px — 60pt @3x, single-scale (see docstring)

CONTENTS_JSON_TEMPLATE = {
    "images": [
        {"filename": "icon.png", "idiom": "universal"}
    ],
    "info": {"author": "xcode", "version": 1},
    "properties": {"template-rendering-intent": "original"}
}


def load_catalog() -> list[dict]:
    with open(CATALOG_PATH) as f:
        return json.load(f)


def should_fetch(entry: dict, include_regions: set[str]) -> bool:
    # A web-only service (no App Store app) can supply an explicit "iconURL" +
    # "iconAsset" pair instead — see fetch_web_icon(). Everything else needs an
    # appStoreId; non-app SF-Symbol tiles have neither and are skipped.
    if "appStoreId" not in entry and "iconURL" not in entry:
        return False
    regions = entry.get("regions")
    if regions is None:
        return True  # global entry
    return bool(set(regions) & include_regions)


def asset_key(entry: dict) -> str:
    """Imageset name: the explicit iconAsset when present (web-sourced icons),
    otherwise the appStoreId. Must match AppCatalog.swift's lookup order."""
    return entry.get("iconAsset") or entry["appStoreId"]


def imageset_dir(key: str) -> Path:
    return ASSETS_DIR / f"{key}.imageset"


def already_fetched(key: str) -> bool:
    return (imageset_dir(key) / "icon.png").exists()


def fetch_web_icon(entry: dict) -> str | None:
    """For services with no App Store app. Prefers an explicit "iconURL" pointing
    at a high-res SQUARE source (apple-touch-icon, press-kit logo) — favicons are
    too low-res to look right at 60pt and are deliberately not auto-discovered.
    Verified square/size after download by download_and_resize()."""
    return entry.get("iconURL")


def fetch_artwork_url(app_store_id: str, country: str = "us") -> str | None:
    url = f"https://itunes.apple.com/lookup?id={app_store_id}&country={country}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"  ! lookup failed for {app_store_id}: {e}")
        return None
    results = data.get("results", [])
    if not results:
        return None
    entry = results[0]
    return entry.get("artworkUrl512") or entry.get("artworkUrl100")


MIN_SOURCE_PX = 120       # reject low-res favicons — they look mushy at 60pt
MAX_ASPECT_SKEW = 1.15    # reject clearly non-square wordmark logos


def source_dimensions(path: str) -> tuple[int, int] | None:
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    w = h = None
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("pixelWidth:"):
            w = int(line.split(":")[1])
        elif line.startswith("pixelHeight:"):
            h = int(line.split(":")[1])
    return (w, h) if w and h else None


def download_and_resize(artwork_url: str, dest_png: Path) -> bool:
    with tempfile.NamedTemporaryFile(suffix=".src") as tmp:
        # Apple's artwork CDN resets the connection on rapid sequential pulls, so a
        # bare single attempt reports a perfectly valid appStoreId as "failed" and
        # sends you off verifying IDs that were never wrong. Retry with backoff.
        # Some sites also 403 the stdlib UA; send a browser-ish one.
        req = urllib.request.Request(
            artwork_url,
            headers={"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"},
        )
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=15) as resp, open(tmp.name, "wb") as out:
                    out.write(resp.read())
                break
            except Exception as e:
                if attempt == 3:
                    print(f"  ! download failed after 4 attempts: {e}")
                    return False
                time.sleep(1.5 * (attempt + 1))

        # Quality gate — a blurry or letterboxed tile is worse than a clean
        # placeholder letter, so reject rather than bake in a bad icon.
        dims = source_dimensions(tmp.name)
        if dims is None:
            print("  ! unreadable image (not a valid bitmap?)")
            return False
        w, h = dims
        if min(w, h) < MIN_SOURCE_PX:
            print(f"  ! source too small ({w}x{h}, need >= {MIN_SOURCE_PX}px)")
            return False
        if max(w, h) / min(w, h) > MAX_ASPECT_SKEW:
            print(f"  ! source not square enough ({w}x{h})")
            return False

        dest_png.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [
                "sips",
                "-s", "format", "png",
                "-z", str(ICON_SIZE), str(ICON_SIZE),
                tmp.name,
                "--out", str(dest_png),
            ],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"  ! sips failed: {result.stderr.strip()}")
            return False
        return True


def write_contents_json(imageset: Path):
    with open(imageset / "Contents.json", "w") as f:
        json.dump(CONTENTS_JSON_TEMPLATE, f, indent=2)
        f.write("\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="re-fetch even if icon.png exists")
    parser.add_argument("--region", action="append", default=[], help="also fetch this region's pack (e.g. AU, GB)")
    args = parser.parse_args()

    include_regions = set(args.region)
    catalog = load_catalog()
    candidates = [e for e in catalog if should_fetch(e, include_regions)]

    fetched, skipped, failed = 0, 0, []

    for entry in candidates:
        name = entry["name"]
        key = asset_key(entry)

        if not args.force and already_fetched(key):
            skipped += 1
            continue

        if "appStoreId" in entry:
            # Region-exclusive apps (Stan/Binge/Kayo = AU, NOW/Sky = GB, …) don't exist
            # in the US storefront — a bare US lookup 404s even for a correct ID. Use
            # the entry's own region (lowercased) when it has one.
            lookup_country = (entry.get("regions") or ["us"])[0].lower()
            print(f"Fetching {name} ({key}, App Store {lookup_country})...")
            artwork_url = fetch_artwork_url(entry["appStoreId"], country=lookup_country)
        else:
            print(f"Fetching {name} ({key}, web)...")
            artwork_url = fetch_web_icon(entry)

        if not artwork_url:
            failed.append(name)
            continue

        dest = imageset_dir(key)
        if download_and_resize(artwork_url, dest / "icon.png"):
            write_contents_json(dest)
            fetched += 1
        else:
            failed.append(name)

    print(f"\nDone. Fetched {fetched}, skipped {skipped} (already present), failed {len(failed)}.")
    if failed:
        print("Failed — add these manually or check the appStoreId:")
        for name in failed:
            print(f"  - {name}")
        sys.exit(1)


if __name__ == "__main__":
    main()
