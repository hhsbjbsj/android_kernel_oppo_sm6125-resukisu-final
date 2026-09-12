#!/usr/bin/env bash
set -Eeuo pipefail
# Resolve ReSukiSU main / SukiSU-Ultra builtin HEAD at compile time.
# SukiSU main is manager/LKM-only and lacks in-tree KSU_SUSFS; 4.14 must use builtin.
mode="${1:-both}"
env_file="${GITHUB_ENV:-}"
resolve() {
  local name="$1" url="$2" ref="$3" var="$4"
  local sha
  sha="$(git ls-remote "$url" "$ref" | awk '{print $1}')"
  if [ -z "$sha" ]; then
    echo "failed to resolve $name $ref from $url" >&2
    exit 1
  fi
  echo "Resolved $name ($ref): $sha"
  if [ -n "$env_file" ]; then
    echo "${var}=$sha" >> "$env_file"
  fi
  export "$var=$sha"
}
case "$mode" in
  resukisu)
    resolve ReSukiSU https://github.com/ReSukiSU/ReSukiSU.git refs/heads/main RESUKISU_COMMIT
    ;;
  sukisu)
    resolve SukiSU-Ultra https://github.com/SukiSU-Ultra/SukiSU-Ultra.git refs/heads/builtin SUKISU_COMMIT
    echo "SUKISU_BRANCH=builtin" >> "${env_file:-/dev/null}"
    ;;
  both)
    resolve ReSukiSU https://github.com/ReSukiSU/ReSukiSU.git refs/heads/main RESUKISU_COMMIT
    resolve SukiSU-Ultra https://github.com/SukiSU-Ultra/SukiSU-Ultra.git refs/heads/builtin SUKISU_COMMIT
    if [ -n "$env_file" ]; then
      echo "SUKISU_BRANCH=builtin" >> "$env_file"
    fi
    ;;
  *)
    echo "usage: $0 [resukisu|sukisu|both]" >&2
    exit 2
    ;;
esac
