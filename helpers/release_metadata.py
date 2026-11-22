#!/usr/bin/env python3
"""Version, Homebrew and Sparkle metadata for the single production release channel."""
import argparse
import base64
import hashlib
import plistlib
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree
from xml.sax.saxutils import escape

import ed25519

SEMVER = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
REPOSITORY = "maxmeis/hypermug"
FEED_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/updates/appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
BUNDLE_VERSION = re.compile(r"^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$")


def render_cask(version, digest, repository=REPOSITORY):
    if not SEMVER.fullmatch("v" + version) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("invalid version or archive digest")
    if repository != REPOSITORY:
        raise ValueError("release must use this repository")
    return f'''cask "hypermug" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/{repository}/releases/download/v#{{version}}/HyperMug-#{{version}}.zip"
  name "HyperMug"
  desc "Caps Lock remapping, caffeine, and mouse controls for macOS"
  homepage "https://github.com/{repository}"

  livecheck do
    skip "Cask versions follow the published production artifacts"
  end

  auto_updates true
  depends_on macos: :sonoma
  depends_on arch: :arm64
  conflicts_with cask: "hypermug@canary"
  conflicts_with cask: "hypermug@nightly"
  app "HyperMug.app"
end
'''


def archive_info(archive):
    """Info.plist of the single HyperMug.app inside a release ZIP."""
    with zipfile.ZipFile(archive) as bundle:
        return plistlib.loads(bundle.read("HyperMug.app/Contents/Info.plist"))


def render_appcast(version, archive, signature, repository=REPOSITORY, expected_build=None):
    """One-item feed for the exact published archive, checked against its own public key."""
    if not SEMVER.fullmatch("v" + version) or repository != REPOSITORY:
        raise ValueError("invalid version or repository")
    info = archive_info(archive)
    build = str(info.get("CFBundleVersion", ""))
    if info.get("CFBundleShortVersionString") != version or not BUNDLE_VERSION.fullmatch(build):
        raise ValueError("archive version does not match the release")
    if expected_build is not None and build != str(expected_build):
        raise ValueError("archive build number does not match the release")
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError("archive does not read the production appcast")
    try:
        public = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
        raw_signature = base64.b64decode(signature, validate=True)
    except ValueError:
        raise ValueError("invalid EdDSA key or signature encoding") from None
    data = Path(archive).read_bytes()
    if not ed25519.verify(public, data, raw_signature):
        raise ValueError("EdDSA signature does not match the archive's SUPublicEDKey")
    url = f"https://github.com/{repository}/releases/download/v{version}/HyperMug-{version}.zip"
    e = lambda value: escape(str(value), {'"': "&quot;"})
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <title>HyperMug updates</title>
    <item>
      <title>HyperMug {e(version)}</title>
      <sparkle:version>{e(build)}</sparkle:version>
      <sparkle:shortVersionString>{e(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{e(info.get("LSMinimumSystemVersion", "14.0"))}</sparkle:minimumSystemVersion>
      <enclosure url="{e(url)}" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{e(signature)}" />
    </item>
  </channel>
</rss>
'''


def feed_version(text):
    item = ElementTree.fromstring(text).find("./channel/item")
    build = item.findtext(f"{{{SPARKLE}}}version") if item is not None else None
    if not build or not BUNDLE_VERSION.fullmatch(build):
        raise ValueError("published appcast has no orderable sparkle:version")
    return tuple(map(int, build.split(".")))


def feed_decision(current, candidate):
    """advance, current (already published) or newer (never move the feed backward)."""
    if current is None:
        return "advance"
    old, new = feed_version(current), feed_version(candidate)
    if old > new:
        return "newer"
    if old == new:
        if current != candidate:
            raise ValueError("published appcast for this version describes different bytes")
        return "current"
    return "advance"


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    cask = sub.add_parser("cask")
    cask.add_argument("--version", required=True)
    cask.add_argument("--zip", type=Path, required=True)
    cask.add_argument("--output", type=Path, required=True)
    appcast = sub.add_parser("appcast")
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--zip", type=Path, required=True)
    appcast.add_argument("--signature", required=True)
    appcast.add_argument("--build-number", required=True)
    appcast.add_argument("--output", type=Path, required=True)
    decision = sub.add_parser("feed-decision")
    decision.add_argument("--current", type=Path, required=True)
    decision.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, ElementTree.ParseError) as error:
        sys.exit(f"error: {error}")


def run(args):
    if args.command == "appcast":
        args.output.write_text(render_appcast(args.version, args.zip, args.signature, expected_build=args.build_number))
    elif args.command == "feed-decision":
        current = args.current.read_text() if args.current.exists() else None
        print(feed_decision(current, args.candidate.read_text()))
    else:
        digest = hashlib.sha256(args.zip.read_bytes()).hexdigest()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(render_cask(args.version, digest))


if __name__ == "__main__":
    main()
