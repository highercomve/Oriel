#!/bin/bash
# Write the latest Oriel release into Zine's '$site.custom' context so every
# page shows the real release at build time (no hardcoded version badges).
#
#   scripts/site-version.sh            read github highest release tag
#   scripts/site-version.sh vX.Y.Z     write it in an explicit tag
set -euo pipefail
cd "$(dirname "$0")/.."

tag=${1:-}
if [ -z "$tag" ]; then
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/highercomve/Oriel/releases/latest | sed 's|.*/releases/tag/||') || true
    if [ -z "$tag" ]; then tag=$(git describe --tags --abbrev=0); fi
fi
echo "site version: $tag"

python3 - "$tag" <<'PY'
import re, sys
tag = sys.argv[1]
path = 'zine.ziggy'
text = open(path).read()
new = re.sub(r'(\.custom = \.\{[\s\S]*?\.version = ")[^"]*(")', r'\g<1>' + tag + r'\g<2>', text, count=1)
assert new != text, "zine.ziggy: custom.version block not found"
link = f"https://github.com/highercomve/Oriel/releases/tag/{tag}"
new = re.sub(r'(\.custom = \.\{[\s\S]*?\.releases_link = ")[^"]*(")', r'\g<1>' + link + r'\g<2>', new, count=1)
open(path, 'w').write(new)
PY
