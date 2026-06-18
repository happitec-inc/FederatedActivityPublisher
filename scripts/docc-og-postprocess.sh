#!/usr/bin/env bash
# Inject Open Graph / Twitter card meta tags into a generated DocC site, pointing at a
# committed static OG image. Public replacement for the private
# happitec-logo-generator `docc-og-postprocess` action.
#
# It differs from that action on purpose: it serves the committed PNG as-is (no
# PNG->JPG conversion) and injects a standard meta-tag set into every page <head>.
# The image dimensions (2400x1260) match what the logo-generator template produces.
#
# Usage:
#   docc-og-postprocess.sh <docs-dir> <og-image-src> <base-url> <title> <description>
set -euo pipefail

DOCS_DIR="${1:?docs dir required}"
OG_IMAGE_SRC="${2:?og image source path required}"
BASE_URL="${3:?base url required}"
TITLE="${4:?title required}"
DESCRIPTION="${5:?description required}"

# Strip any trailing slash so we can build clean absolute URLs.
BASE_URL="${BASE_URL%/}"
OG_IMAGE_URL="${BASE_URL}/og-image.png"

if [ ! -f "$OG_IMAGE_SRC" ]; then
  echo "error: OG image not found at $OG_IMAGE_SRC" >&2
  exit 1
fi

# Publish the image alongside the docs so the absolute URL resolves.
cp "$OG_IMAGE_SRC" "$DOCS_DIR/og-image.png"

export OG_IMAGE_URL TITLE DESCRIPTION

# Inject the meta block immediately after the first <head> in every HTML file.
# Idempotent: skip a file that already carries our marker.
find "$DOCS_DIR" -name '*.html' -type f -print0 | while IFS= read -r -d '' html; do
  HTML_FILE="$html" perl -0777 -i -pe '
    my $file  = $ENV{HTML_FILE};
    my $img   = $ENV{OG_IMAGE_URL};
    my $title = $ENV{TITLE};
    my $desc  = $ENV{DESCRIPTION};
    for ($img, $title, $desc) { s/&/&amp;/g; s/"/&quot;/g; s/</&lt;/g; s/>/&gt;/g; }
    next if /<!-- og:injected -->/;
    my $meta = qq{<!-- og:injected -->\n}
      . qq{<meta property="og:type" content="website">\n}
      . qq{<meta property="og:title" content="$title">\n}
      . qq{<meta property="og:description" content="$desc">\n}
      . qq{<meta property="og:image" content="$img">\n}
      . qq{<meta property="og:image:width" content="2400">\n}
      . qq{<meta property="og:image:height" content="1260">\n}
      . qq{<meta name="twitter:card" content="summary_large_image">\n}
      . qq{<meta name="twitter:title" content="$title">\n}
      . qq{<meta name="twitter:description" content="$desc">\n}
      . qq{<meta name="twitter:image" content="$img">\n};
    s/(<head[^>]*>)/$1\n$meta/i;
  ' "$html"
done

echo "Injected OG/Twitter meta into $(find "$DOCS_DIR" -name '*.html' -type f | wc -l | tr -d ' ') HTML files."
