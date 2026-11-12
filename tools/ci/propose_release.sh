#!/bin/bash
# A release's proposal (docs/CI_POLICY.md in AttilaTheFun/reviews), made by
# CI's propose job once the commit's verify and pins passed in the same run:
# a draft release, tag v<version> on the commit (named, not made: a draft's
# tag is made only when Logan presses Release in Reviews), not marked
# pre-release (a library has releases alone), its notes naming the run that
# verified it. A run again for the same version brings the same draft up to
# date rather than making a second. No agent makes a draft or a tag: the
# run's token does (contents: write). Only curl and Python: no gh on the
# runners.
#
#   tools/ci/propose_release.sh <version> [<proof> [<assets>]]
#
# <version>: MAJOR.MINOR.PATCH, newer than every v* tag. <proof>: the run's
# `proof` artifact as downloaded (proof.json and its files, format 2), put on
# the draft as proof.zip, so the release keeps it and Reviews compares the next
# release's with it (AttilaTheFun/reviews' docs/PROOF_FORMAT.md). <assets>: a
# folder whose every file goes on the draft as well (the static
# agent-wrapper for each architecture and SHA256SUMS), a file there
# already of the same name replaced; SHA256SUMS is quoted in the notes, for
# images that fetch the client by version and check it.
#
#   GH_TOKEN           the job's token (contents: write)
#   GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_SERVER_URL, GITHUB_RUN_ID
#                      a job has them
set -euo pipefail
me="$(basename "$0")"
version="${1:?usage: $me <version> [<proof> [<assets>]]}"
proof="${2:-}"
assets="${3:-}"
for name in GH_TOKEN GITHUB_REPOSITORY GITHUB_SHA GITHUB_SERVER_URL GITHUB_RUN_ID; do
    [ -n "${!name:-}" ] || { echo "$me: no $name" >&2; exit 1; }
done
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || { echo "::error::not a version, MAJOR.MINOR.PATCH: $version"; exit 1; }
tag="v$version"
newest="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)"
if [ -n "$newest" ]; then
    later="$(printf '%s\n%s\n' "$newest" "$tag" | sort -V | tail -1)"
    if [ "$newest" = "$tag" ] || [ "$later" != "$tag" ]; then
        echo "::error::$tag is not newer than $newest"
        exit 1
    fi
fi
api="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY"
run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'Authorization: Bearer %s\n' "$GH_TOKEN" > "$work/auth"
# GitHub's answer on stdout; when it refuses, its message in the job's log
# too (a rate limit, a permission, a rule), not only curl's status.
github() {
    local answer status
    answer="$(curl -sSL --fail-with-body --max-time 60 -H @"$work/auth" -H 'Accept: application/vnd.github+json' "$@")" \
        && { printf '%s\n' "$answer"; return 0; }
    status=$?
    echo "::error::GitHub refused $(printf '%s ' "$@" | grep -oE 'https://[^ ]+' | head -1): $(printf '%s' "$answer" | head -c 600)" >&2
    return "$status"
}
# The releases, every page (a draft is listed only to a token that may
# write), as one JSON list. Each page in a file of its own: GitHub's JSON
# spans many lines.
releases() {
    rm -f "$work"/page-*.json
    page=1
    while :; do
        github "$api/releases?per_page=100&page=$page" > "$work/page-$page.json"
        count="$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$work/page-$page.json")"
        [ "$count" -gt 0 ] || break
        page=$((page + 1))
    done
    python3 -I -c 'import json, sys
print(json.dumps([r for p in sys.argv[1:] for r in json.load(open(p))]))' "$work"/page-*.json
}

{
    echo "Release proposed: $version, of ${GITHUB_SHA:0:7}."
    echo
    echo "Verified by $run (its tests, and the proof as its \`proof\` artifact)."
    if [ -n "$assets" ] && [ -f "$assets/SHA256SUMS" ]; then
        echo
        echo "The static agent-wrapper, for an image or a runner to fetch by version and check:"
        echo
        echo '```'
        cat "$assets/SHA256SUMS"
        echo '```'
    fi
} > "$work/notes.md"

# A release of this tag already: a draft is brought up to date, a published
# one is never touched.
releases > "$work/releases.json"
python3 -I -c 'import json, sys
for r in json.load(open(sys.argv[1])):
    if r["tag_name"] == sys.argv[2]: print("%d\t%s" % (r["id"], "true" if r["draft"] else "false"))' \
    "$work/releases.json" "$tag" > "$work/same.tsv"
if grep -q $'\tfalse$' "$work/same.tsv"; then
    echo "::error::$tag is released already: nothing proposed"
    exit 1
fi
existing="$(head -1 "$work/same.tsv" | cut -f1)"

python3 -I -c 'import json, sys
tag, sha, name, notes = sys.argv[1:5]
print(json.dumps({"tag_name": tag, "target_commitish": sha, "name": name,
                  "body": open(notes).read(), "draft": True, "prerelease": False}))' \
    "$tag" "$GITHUB_SHA" "agent_protocol $version" "$work/notes.md" > "$work/release.json"

if [ -n "$existing" ]; then
    github -X PATCH "$api/releases/$existing" --data-binary @"$work/release.json" > "$work/made.json"
    said="brought up to date"
else
    github -X POST "$api/releases" --data-binary @"$work/release.json" > "$work/made.json"
    said="made"
fi
echo "Draft $tag $said: $(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["html_url"])' "$work/made.json")"
# The draft as GitHub keeps it, read back by its id (the list of releases
# can lag a new one): its tag, commit and kind as asked (a draft's edit
# has been seen to lose its tag).
made="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$work/made.json")"
github "$api/releases/$made" > "$work/kept.json"
python3 -I -c 'import json, sys
r = json.load(open(sys.argv[1]))
tag, sha, prerelease = sys.argv[2], sys.argv[3], sys.argv[4] == "true"
sys.exit(0 if r["draft"] and r["tag_name"] == tag and r["target_commitish"] == sha and r["prerelease"] == prerelease else 1)' \
    "$work/kept.json" "$tag" "$GITHUB_SHA" false \
    || { echo "::error::the draft of $tag isn't as asked: look at the repository's releases"; exit 1; }

# The proof on the draft, as proof.zip: proof.json at its top, its files
# beside it. One there already (a run again for the same version) is replaced.
if [ -n "$proof" ]; then
    [ -f "$proof/proof.json" ] || { echo "::error::$proof has no proof.json"; exit 1; }
    python3 -I - "$proof" "$work/proof.zip" << 'PY'
import os, sys, zipfile
source, target = sys.argv[1:3]
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as made:
    for top, _, files in os.walk(source):
        for name in sorted(files):
            path = os.path.join(top, name)
            # The comparison goes beside proof.zip, not in it.
            if os.path.relpath(path, source) == "proof-diff.json":
                continue
            made.write(path, os.path.relpath(path, source))
PY
    github "$api/releases/$made/assets?per_page=100" > "$work/assets.json"
    old="$(python3 -I -c 'import json, sys
print(next((str(a["id"]) for a in json.load(open(sys.argv[1])) if a["name"] == "proof.zip"), ""))' "$work/assets.json")"
    [ -z "$old" ] || github -X DELETE "$api/releases/assets/$old" > /dev/null
    uploads="https://uploads.github.com/repos/$GITHUB_REPOSITORY"
    github -X POST -H 'Content-Type: application/zip' --data-binary @"$work/proof.zip" \
        "$uploads/releases/$made/assets?name=proof.zip" > /dev/null
    echo "proof.zip attached to the draft of $tag ($(wc -c < "$work/proof.zip" | tr -d ' ') bytes)"
    # Its comparison with the prior release's (proof-diff.json, which verify
    # made), beside it; one there already is replaced.
    if [ -f "$proof/proof-diff.json" ]; then
        old="$(python3 -I -c 'import json, sys
print(next((str(a["id"]) for a in json.load(open(sys.argv[1])) if a["name"] == "proof-diff.json"), ""))' "$work/assets.json")"
        [ -z "$old" ] || github -X DELETE "$api/releases/assets/$old" > /dev/null
        github -X POST -H 'Content-Type: application/json' --data-binary @"$proof/proof-diff.json" \
            "$uploads/releases/$made/assets?name=proof-diff.json" > /dev/null
        echo "proof-diff.json attached to the draft of $tag"
    fi
fi

# The assets on the draft, each as its file is named; one there already (a
# run again for the same version) is replaced.
if [ -n "$assets" ]; then
    [ -d "$assets" ] || { echo "::error::$assets is not a folder"; exit 1; }
    uploads="https://uploads.github.com/repos/$GITHUB_REPOSITORY"
    github "$api/releases/$made/assets?per_page=100" > "$work/assets.json"
    for file in "$assets"/*; do
        [ -f "$file" ] || continue
        name="$(basename "$file")"
        old="$(python3 -I -c 'import json, sys
print(next((str(a["id"]) for a in json.load(open(sys.argv[1])) if a["name"] == sys.argv[2]), ""))' "$work/assets.json" "$name")"
        [ -z "$old" ] || github -X DELETE "$api/releases/assets/$old" > /dev/null
        github -X POST -H 'Content-Type: application/octet-stream' --data-binary @"$file" \
            "$uploads/releases/$made/assets?name=$name" > /dev/null
        echo "$name attached to the draft of $tag ($(wc -c < "$file" | tr -d ' ') bytes)"
    done
fi
