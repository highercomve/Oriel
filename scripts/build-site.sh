#!/usr/bin/env bash
# Run from the repository root. Pagefind indexes only data-pagefind-body articles.
set -euo pipefail
output=${1:-public}
zine release --force --output "$output"
npx --yes pagefind@1.5.2 --site "$output"
