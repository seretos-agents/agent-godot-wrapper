#!/usr/bin/env bash
# prev-release-tag.sh PLUGIN VERSION
#
# Prints the highest existing "${PLUGIN}--v<semver>" tag whose SemVer 2.0
# precedence is strictly lower than VERSION, or nothing if there is none
# (first release). Exits 2 if VERSION is not strict SemVer 2.0 (no leading
# zeros, no build metadata). `src/*` marker tags and other plugins' tags are
# never matched.
#
# See .adev/9-1/plan.md (R1) for the full contract.
set -euo pipefail

usage() {
  echo "Usage: $0 PLUGIN VERSION" >&2
  exit 2
}

[ $# -eq 2 ] || usage

PLUGIN="$1"
VERSION="$2"

# The canonical SemVer 2.0 grammar (see semver.org #FAQ regex), with no
# leading zeros in numeric components and no build-metadata suffix.
SEMVER_BODY='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?'
SEMVER_RE="^${SEMVER_BODY}\$"

if [[ ! "$VERSION" =~ $SEMVER_RE ]]; then
  echo "::error::Version '$VERSION' is not valid SemVer 2.0 (MAJOR.MINOR.PATCH[-PRERELEASE], no leading zeros, no build metadata)." >&2
  exit 2
fi

version_core() { printf '%s' "${1%%-*}"; }
version_pre() {
  case "$1" in
    *-*) printf '%s' "${1#*-}" ;;
    *) printf '' ;;
  esac
}

is_numeric_id() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Sets CMP to -1, 0 or 1.
compare_identifier() {
  local a="$1" b="$2"
  if is_numeric_id "$a" && is_numeric_id "$b"; then
    if ((10#$a < 10#$b)); then CMP=-1; elif ((10#$a > 10#$b)); then CMP=1; else CMP=0; fi
  elif is_numeric_id "$a" && ! is_numeric_id "$b"; then
    CMP=-1
  elif ! is_numeric_id "$a" && is_numeric_id "$b"; then
    CMP=1
  else
    if [[ "$a" < "$b" ]]; then CMP=-1; elif [[ "$a" > "$b" ]]; then CMP=1; else CMP=0; fi
  fi
}

# Sets CMP to -1, 0 or 1 comparing two "X.Y.Z" core strings.
compare_core() {
  local a="$1" b="$2"
  local IFS=.
  local -a A=($a) B=($b)
  local i
  CMP=0
  for i in 0 1 2; do
    if ((10#${A[i]} < 10#${B[i]})); then
      CMP=-1
      return
    elif ((10#${A[i]} > 10#${B[i]})); then
      CMP=1
      return
    fi
  done
}

# Sets CMP to -1, 0 or 1 comparing two prerelease strings (may be empty,
# meaning "no prerelease" i.e. a release, which always outranks one).
compare_prerelease() {
  local pa="$1" pb="$2"
  if [[ -z "$pa" && -z "$pb" ]]; then
    CMP=0
    return
  fi
  if [[ -z "$pa" ]]; then
    CMP=1
    return
  fi
  if [[ -z "$pb" ]]; then
    CMP=-1
    return
  fi
  local IFS=.
  local -a A=($pa) B=($pb)
  local n=${#A[@]} m=${#B[@]}
  local max=$((n > m ? n : m))
  local i
  for ((i = 0; i < max; i++)); do
    if ((i >= n)); then
      CMP=-1
      return
    fi
    if ((i >= m)); then
      CMP=1
      return
    fi
    compare_identifier "${A[i]}" "${B[i]}"
    if ((CMP != 0)); then
      return
    fi
  done
  CMP=0
}

# Sets CMP to -1, 0 or 1 comparing two full "X.Y.Z[-pre]" versions.
compare_versions() {
  local a="$1" b="$2"
  compare_core "$(version_core "$a")" "$(version_core "$b")"
  if ((CMP != 0)); then
    return
  fi
  compare_prerelease "$(version_pre "$a")" "$(version_pre "$b")"
}

TAG_RE="^${PLUGIN}--v${SEMVER_BODY}\$"

best_tag=""
best_ver=""
while IFS= read -r tag; do
  [ -z "$tag" ] && continue
  ver="${tag#"${PLUGIN}"--v}"
  compare_versions "$ver" "$VERSION"
  if ((CMP < 0)); then
    if [ -z "$best_ver" ]; then
      best_tag="$tag"
      best_ver="$ver"
    else
      compare_versions "$ver" "$best_ver"
      if ((CMP > 0)); then
        best_tag="$tag"
        best_ver="$ver"
      fi
    fi
  fi
done < <(git tag --list "${PLUGIN}--v*" | grep -E "$TAG_RE" || true)

printf '%s\n' "$best_tag"
