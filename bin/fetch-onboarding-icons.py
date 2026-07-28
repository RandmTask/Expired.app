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
    if "appStoreId" not in entry:
        return False  # non-app tile — SF Symbol, no artwork to fetch
    regions = entry.get("regions")
    if regions is None:
        return True  # global entry
    return bool(set(regions) & include_regions)


def imageset_dir(app_store_id: str) -> Path:
    return ASSETS_DIR / f"{app_store_id}.imageset"


def already_fetched(app_store_id: str) -> bool:
    return (imageset_dir(app_store_id) / "icon.png").exists()


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


def download_and_resize(artwork_url: str, dest_png: Path) -> bool:
    with tempfile.NamedTemporaryFile(suffix=".src") as tmp:
        try:
            urllib.request.urlretrieve(artwork_url, tmp.name)
        except Exception as e:
            print(f"  ! download failed: {e}")
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
        app_store_id = entry["appStoreId"]
        name = entry["name"]

        if not args.force and already_fetched(app_store_id):
            skipped += 1
            continue

        # Region-exclusive apps (Stan/Binge/Kayo = AU, NOW/Sky = GB, …) don't exist
        # in the US storefront — a bare US lookup 404s even for a correct ID. Use
        # the entry's own region (lowercased) when it has one.
        lookup_country = (entry.get("regions") or ["us"])[0].lower()
        print(f"Fetching {name} ({app_store_id}, country={lookup_country})...")
        artwork_url = fetch_artwork_url(app_store_id, country=lookup_country)
        if not artwork_url:
            failed.append(name)
            continue

        dest = imageset_dir(app_store_id)
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
