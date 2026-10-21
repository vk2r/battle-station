#!/usr/bin/env bash
# Set the plugin version in manifest.json, commit it and tag it v<version>.
# Usage: mise run version 1.2.0
#
# It runs on main, up to date with origin, and only when bin/ was built by
# build-engine.yml from the current engine sources, so the Release workflow
# accepts the tag. Nothing is pushed; it prints the command to do it.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

die() { echo "version: $*" >&2; exit 1; }

version="${1:-}"
version="${version#v}"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "usage: mise run version <x.y.z>"

current="$(jq -r .version manifest.json)"
[[ $version != "$current" ]] || die "manifest.json is already $version"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && die "tag v$version already exists"

[[ "$(git branch --show-current)" == main ]] || die "switch to main first"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash your changes first"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not in sync with origin/main (git pull / git push first)"

# The same check as verify-binaries.yml, from the bot commit that last wrote bin/engine.
built_from="$(git log -1 --format=%B -- bin/engine | grep -oE 'from [0-9a-f]{40}' | head -1 | cut -d' ' -f2 || true)"
[[ -n $built_from ]] || die "bin/engine was not committed by Build engine; wait for it to finish and pull"
for path in engine mise.toml scripts/build-engine.sh; do
  [[ "$(git rev-parse "$built_from:$path" 2>/dev/null)" == "$(git rev-parse "HEAD:$path")" ]] ||
    die "bin/ is older than $path; wait for Build engine to commit the new binaries and pull"
done

# Edit the line in place to keep the file's formatting.
sed -i -E "0,/\"version\": *\"[^\"]*\"/s//\"version\": \"$version\"/" manifest.json
[[ "$(jq -r .version manifest.json)" == "$version" ]] || die "could not update manifest.json"

git add manifest.json
git commit -q -m "🔖 release v$version"
git tag -a "v$version" -m "v$version"

echo "manifest.json: $current -> $version, tagged v$version"
echo "Publish with: git push origin main v$version"
