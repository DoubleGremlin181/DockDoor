#!/bin/bash
# Prints the next fork release version as key=value lines.
# Version format: <upstream release>-fork.<n>, where <upstream release> is the newest
# upstream x.y.z tag merged into HEAD and <n> counts fork releases on that base.
# Needs upstream tags and UPSTREAM_REF (default upstream/main) fetched.
set -euo pipefail

UPSTREAM_REF=${UPSTREAM_REF:-upstream/main}

upstream_sha=$(git merge-base HEAD "$UPSTREAM_REF")
base=""
for tag in $(git tag --merged "$upstream_sha" --sort=-v:refname); do
    if [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        base=$tag
        break
    fi
done
if [[ -z $base ]]; then
    echo "No upstream x.y.z tag is reachable from $upstream_sha; fetch upstream tags first." >&2
    exit 1
fi

last=0
for tag in $(git tag -l "$base-fork.*"); do
    n=${tag##*-fork.}
    if [[ $n =~ ^[0-9]+$ ]] && ((n > last)); then
        last=$n
    fi
done

echo "version=$base-fork.$((last + 1))"
echo "base=$base"
echo "upstream_sha=$upstream_sha"
echo "upstream_ahead=$(git rev-list --count "$base..$upstream_sha")"
echo "previous_tag=$(git describe --tags --abbrev=0 --match '*-fork.*' HEAD 2>/dev/null || true)"
