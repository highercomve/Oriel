#!/usr/bin/env bash
# Rewrites the Zine config and site links so the site builds for
# https://<subdomain>.foreachdeveloper.com/ instead of highercomve.github.io/<prefix>/.
# CI runs it on a throwaway checkout before `zine release`; don't commit its output.
# usage: scripts/site-for-cloudflare.sh <subdomain> <github-pages-prefix>
set -euo pipefail
sub=$1
prefix=$2

sed -i -E \
	-e "s#\.host_url = \"https://highercomve\.github\.io\"#.host_url = \"https://$sub.foreachdeveloper.com\"#" \
	-e "s#\.url_path_prefix = \"$prefix\"#.url_path_prefix = \"\"#" \
	zine.ziggy
grep -q "https://$sub.foreachdeveloper.com" zine.ziggy
grep -q '.url_path_prefix = ""' zine.ziggy

# Links to the sibling projects move to their own subdomains, and root-relative
# paths lose the GitHub Pages prefix.
{ grep -rlE "highercomve\.github\.io/(Oriel|GhostPen|GhostReel|hollershare|ghostpantry)\b|[\"'(]/$prefix/" site || true; } | xargs -r sed -i -E \
	-e 's#https?://highercomve\.github\.io/Oriel/?#https://oriel.foreachdeveloper.com/#g' \
	-e 's#https?://highercomve\.github\.io/GhostPen/?#https://ghostpen.foreachdeveloper.com/#g' \
	-e 's#https?://highercomve\.github\.io/GhostReel/?#https://ghostreel.foreachdeveloper.com/#g' \
	-e 's#https?://highercomve\.github\.io/hollershare/?#https://hollershare.foreachdeveloper.com/#g' \
	-e 's#https?://highercomve\.github\.io/ghostpantry/?#https://ghostpantry.foreachdeveloper.com/#g' \
	-e "s#([\"'(])/$prefix/#\1/#g"
