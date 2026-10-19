#!/usr/bin/env bash
# marketplace-payload.sh
#
# Builds the repository_dispatch JSON payload for a plugin release, reading
# NAME, DESC, REPO, VERSION, TAG (required) and CHANGELOG (optional) from
# the environment and printing the JSON to stdout. Exits 1 if a required
# variable is empty or unset.
#
# `changelog` is added to client_payload only when CHANGELOG is non-empty --
# this keeps the payload at or under the repository_dispatch 10-key limit
# and matches the #5 first-release case (no previous tag, no changelog).
#
# CHANGELOG is passed through byte-for-byte: no trimming of leading or
# trailing whitespace/newlines happens here (the sentinel-based trailing-
# newline strip on the release body happens once, earlier, in release.yml's
# Dispatch step -- never again in this script).
#
# See .adev/9-1/plan.md (R3) for the full contract.
set -euo pipefail

# On native-Windows jq (as shipped on windows-latest runners), reading
# non-ASCII bytes back out of the environment via jq's own `$ENV` mangles
# them (jq's Windows build reads the process environment through the
# narrow/ANSI API, not UTF-8 -- verified empirically: a "u+umlaut" and an
# emoji both come back as the replacement character). Passing every value
# as a `--arg` instead keeps it on the argv path, which git-bash hands to
# jq.exe with the bytes intact. MSYS_NO_PATHCONV / MSYS2_*_CONV_EXCL stop
# git-bash from rewriting any argv value that merely looks like a Unix path
# (e.g. a changelog line containing "/usr/bin:/tmp") before jq ever sees it.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
export MSYS2_ENV_CONV_EXCL='*'

for var in NAME DESC REPO VERSION TAG; do
  if [ -z "${!var:-}" ]; then
    echo "::error::marketplace-payload.sh: required variable $var is empty or unset." >&2
    exit 1
  fi
done

ICON="https://raw.githubusercontent.com/${REPO}/${TAG}/assets/icon.png"
DESC_URL="https://raw.githubusercontent.com/${REPO}/${TAG}/description.md"

# `changelog` is added only when CHANGELOG is non-empty (unset or "" both
# omit it); the boolean is computed here, not in jq, so the "is it present"
# decision never depends on jq's environment reading either.
if [ -n "${CHANGELOG:-}" ]; then
  HAS_CHANGELOG=true
else
  HAS_CHANGELOG=false
fi

jq -n \
  --arg name "$NAME" \
  --arg desc "$DESC" \
  --arg repo "$REPO" \
  --arg version "$VERSION" \
  --arg tag "$TAG" \
  --arg icon "$ICON" \
  --arg desc_url "$DESC_URL" \
  --arg changelog "${CHANGELOG:-}" \
  --argjson has_changelog "$HAS_CHANGELOG" \
  '
  {
    event_type: "plugin-release",
    client_payload: (
      {
        name:             $name,
        description:      $desc,
        repo:             $repo,
        category:         "skill",
        version:          $version,
        ref:              $tag,
        icon:             $icon,
        description_url:  $desc_url,
        tags:             ["godot", "game-engine", "3d"]
      }
      + (if $has_changelog then { changelog: $changelog } else {} end)
    )
  }
'
