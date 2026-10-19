#!/usr/bin/env bash
# release-preflight.sh PLUGIN VERSION
#
# Read-only pre-flight for release.yml, run right after Checkout, before any
# remote side effect. On success appends `prev_tag=` and `main_sha=` to
# $GITHUB_OUTPUT. On failure it exits non-zero and touches nothing.
#
# Requires (from the calling environment):
#   DEFAULT_BRANCH  the repository's default branch name (e.g. "main")
#   GITHUB_OUTPUT   path to append `key=value` output lines to
#
# See .adev/9-1/plan.md (R2) for the full contract.
set -euo pipefail

usage() {
  echo "Usage: $0 PLUGIN VERSION" >&2
  exit 1
}

[ $# -eq 2 ] || usage

PLUGIN="$1"
VERSION="$2"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH must be set}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${PLUGIN}--v${VERSION}"

# 1. Validate the version and resolve the previous release tag (if any).
#    prev-release-tag.sh exits 2 on invalid semver -- any nonzero here is a
#    validation failure, and nothing has been written to $GITHUB_OUTPUT yet.
if ! PREV_TAG="$(bash "$SCRIPT_DIR/prev-release-tag.sh" "$PLUGIN" "$VERSION")"; then
  echo "::error::Version '$VERSION' failed validation (see prev-release-tag.sh output above)." >&2
  exit 1
fi

# 2. HEAD must be the tip of the default branch. This is the only
#    pre-side-effect proof that GITHUB_TOKEN is about to act on what the
#    triggering user actually approved (see the token/permission table).
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_DEFAULT_SHA="$(git ls-remote origin "refs/heads/${DEFAULT_BRANCH}" | cut -f1)"
if [ -z "$REMOTE_DEFAULT_SHA" ] || [ "$HEAD_SHA" != "$REMOTE_DEFAULT_SHA" ]; then
  echo "::error::HEAD (${HEAD_SHA}) is not the tip of origin/${DEFAULT_BRANCH} (${REMOTE_DEFAULT_SHA:-<unknown>})." >&2
  exit 1
fi

# 3. Refuse if either the release tag or its source marker already exists.
#    Exact per-ref queries (not a substring grep over the full tag dump) so
#    that e.g. TAG "...v0.2.0" never false-matches an existing "...v0.2.0-rc.1".
if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "::error::Tag ${TAG} already exists on origin. Delete it first or pick a new version." >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/src/${TAG}" >/dev/null 2>&1; then
  echo "::error::Marker tag src/${TAG} already exists on origin. Delete it first or pick a new version." >&2
  exit 1
fi

# 4. If there is a previous release, its source marker must already exist:
#    it is the only ancestry link the changelog step has, and CI can never
#    create it retroactively (a human push is not subject to the
#    GITHUB_TOKEN rule -- see AGENTS.md).
if [ -n "$PREV_TAG" ] && ! git ls-remote --exit-code --tags origin "refs/tags/src/${PREV_TAG}" >/dev/null 2>&1; then
  echo "::error::Marker tag src/${PREV_TAG} is missing on origin. Run once, as a maintainer:" >&2
  echo "  git tag src/${PREV_TAG} <head_sha of the successful release.yml run for ${PREV_TAG}>" >&2
  echo "  git push origin src/${PREV_TAG}" >&2
  exit 1
fi

# 5. Success -- publish outputs for later steps in the same job.
printf 'prev_tag=%s\n' "$PREV_TAG" >>"$GITHUB_OUTPUT"
printf 'main_sha=%s\n' "$HEAD_SHA" >>"$GITHUB_OUTPUT"
