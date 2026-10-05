#!/usr/bin/env bash
# Validate Conventional Commit subjects for the MortarMQ component scopes.
# Usage:
#   check-commit-messages.sh BASE HEAD
#   check-commit-messages.sh              # GitHub Actions event mode
#   check-commit-messages.sh --self-test
set -euo pipefail

export LC_ALL=C.UTF-8

readonly PATTERN='^(feat|fix|docs|test|refactor|perf|chore|build|ci)\((a0[1-9]|a1[0-2]|m[1-3]|infra|deps(-dev)?)\)!?: .+$'
readonly ZERO_SHA='0000000000000000000000000000000000000000'

sha_exists() {
  local sha="${1:-}"
  [[ -n "$sha" && "$sha" != "$ZERO_SHA" ]] || return 1
  git rev-parse --verify --quiet "${sha}^{commit}" >/dev/null
}

validate_subject() {
  local subject=$1

  if [[ -z "$subject" ]]; then
    echo "empty subject"
    return 1
  fi
  if [[ "$subject" =~ ^[[:space:]] || "$subject" =~ [[:space:]]$ ]]; then
    echo "leading/trailing whitespace"
    return 1
  fi
  if [[ "$subject" == *[[:cntrl:]]* ]]; then
    echo "control character"
    return 1
  fi
  if ((${#subject} > 72)); then
    echo "subject exceeds 72 code points"
    return 1
  fi
  if [[ "$subject" == Merge\ * ]]; then
    echo "merge commit"
    return 1
  fi
  if ! grep -Eq "$PATTERN" <<<"$subject"; then
    echo "invalid type/scope/description format"
    return 1
  fi
}

run_self_test() {
  local -a valid=(
    'feat(a01): add fifteen op wire enum'
    'ci(infra): enforce conventional commit subjects'
    'fix(a03): tolerate zero length trailing record'
    'feat(a01)!: change wire framing'
    'ci(deps): bump actions/cache from 4.3.0 to 6.1.0'
    'build(deps-dev): bump mermaid from 11.17.2 to 12.0.0'
  )
  local -a invalid=(
    'feat: missing scope'
    'oops(a01): invalid type'
    'feat(a01): subject exceeds seventy-two characters and must therefore be rejected by the checker'
    'feat(a01):missing space'
    'Merge branch '"'"'main'"'"' into feature'
  )
  local subject failures=0

  for subject in "${valid[@]}"; do
    if validate_subject "$subject"; then
      printf 'valid:   %s\n' "$subject"
    else
      printf 'self-test failure, expected valid: %s\n' "$subject" >&2
      failures=$((failures + 1))
    fi
  done

  for subject in "${invalid[@]}"; do
    if validate_subject "$subject"; then
      printf 'self-test failure, expected invalid: %s\n' "$subject" >&2
      failures=$((failures + 1))
    else
      printf 'invalid: %s -- %s\n' "$(validate_subject "$subject" 2>/dev/null || true)" "$subject"
    fi
  done

  if ((failures != 0)); then
    printf 'self-test failed with %d unexpected result(s)\n' "$failures" >&2
    return 1
  fi
  printf 'self-test passed: %d valid and %d invalid subjects\n' "${#valid[@]}" "${#invalid[@]}"
}

run_range_self_test() {
  local script_dir checker temp
  script_dir=$(cd "$(dirname "$0")" && pwd)
  checker="$script_dir/$(basename "$0")"
  temp=$(mktemp -d) || return 1

  (
    set -e
    cd "$temp"
    git init -q -b main
    git config user.name "Commit Checker Test"
    git config user.email "commit-checker-test@example.invalid"

    printf 'base\n' > file.txt
    git add file.txt
    git commit -q -m 'ci(infra): create range test base'

    printf 'valid\n' > file.txt
    git add file.txt
    git commit -q -m 'feat(a01): valid range subject'
    local valid_head
    valid_head=$(git rev-parse HEAD)

    local range_base
    range_base=$(git rev-parse HEAD~1)
    if bash "$checker" "$range_base" HEAD >/dev/null 2>&1; then
      printf 'range self-test passed\n'
    else
      printf 'range self-test rejected a valid range\n' >&2
      exit 1
    fi

    if bash "$checker" main main >/dev/null 2>&1; then
      printf 'same-SHA self-test unexpectedly passed\n' >&2
      exit 1
    fi
    printf 'same-SHA self-test passed\n'

    printf 'invalid\n' > file.txt
    git add file.txt
    git commit -q -m 'invalid subject'
    if bash "$checker" main HEAD >/dev/null 2>&1; then
      printf 'range self-test accepted an invalid commit\n' >&2
      exit 1
    fi
    printf 'invalid-range self-test passed\n'

    printf 'fixed\n' > file.txt
    git add file.txt
    git commit -q -m 'fix(a01): valid fallback subject'
    local fixed_head
    fixed_head=$(git rev-parse HEAD)
    if PUSH_BEFORE=0000000000000000000000000000000000000000 PUSH_AFTER="$fixed_head" bash "$checker" >/dev/null 2>&1; then
      printf 'fallback self-test passed\n'
    else
      printf 'fallback self-test rejected a valid latest commit\n' >&2
      exit 1
    fi

    if PUSH_BEFORE=main PUSH_AFTER="$fixed_head" bash "$checker" >/dev/null 2>&1; then
      printf 'push-range self-test accepted an invalid commit\n' >&2
      exit 1
    fi
    printf 'push-range self-test passed\n'
  )
  local status=$?
  rm -rf "$temp"
  return "$status"
}

validate_commit_stream() {
  local sha subject reason failures=0 count=0

  while read -r sha subject; do
    count=$((count + 1))
    if reason=$(validate_subject "$subject"); then
      printf 'valid:   %s %s\n' "${sha:0:12}" "$subject"
    else
      printf 'invalid: %s -- %s\n' "${sha:0:12}" "$reason"
      printf '  subject: %s\n' "$subject"
      failures=$((failures + 1))
    fi
  done

  if ((count == 0)); then
    printf 'commit selection contains no commits\n' >&2
    return 1
  fi
  if ((failures != 0)); then
    printf 'commit subject gate failed: %d invalid of %d commit(s)\n' "$failures" "$count" >&2
    return 1
  fi
  printf 'commit subject gate passed: %d commit(s)\n' "$count"
}

check_range() {
  local base=$1 head=$2

  sha_exists "$base" || { printf 'base SHA is missing or unreachable: %s\n' "$base" >&2; return 1; }
  sha_exists "$head" || { printf 'head SHA is missing or unreachable: %s\n' "$head" >&2; return 1; }

  validate_commit_stream < <(git log --format='%H %s' "$base..$head")
}

check_single() {
  local head=$1

  sha_exists "$head" || { printf 'head SHA is missing or unreachable: %s\n' "$head" >&2; return 1; }

  validate_commit_stream < <(git log -1 --format='%H %s' "$head")
}

check_fallback() {
  local head=$1 parent

  if parent=$(git rev-parse --verify --quiet "${head}^"); then
    check_range "$parent" "$head"
  else
    check_single "$head"
  fi
}

select_github_range() {
  local pr_base="${PR_BASE:-}" pr_head="${PR_HEAD:-}"
  local push_before="${PUSH_BEFORE:-}" push_after="${PUSH_AFTER:-}"

  if sha_exists "$pr_base" && sha_exists "$pr_head"; then
    printf 'PR range: %s..%s\n' "$pr_base" "$pr_head" >&2
    check_range "$pr_base" "$pr_head"
  elif sha_exists "$push_before" && sha_exists "$push_after"; then
    printf 'push range: %s..%s\n' "$push_before" "$push_after" >&2
    check_range "$push_before" "$push_after"
  elif sha_exists "$push_after"; then
    printf 'push fallback: checking HEAD~..HEAD for %s\n' "$push_after" >&2
    check_fallback "$push_after"
  elif sha_exists HEAD; then
    printf 'event fallback: checking HEAD~..HEAD\n' >&2
    check_fallback HEAD
  else
    printf 'no reachable commit to check\n' >&2
    return 1
  fi
}

if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
  run_self_test
  run_range_self_test
elif [ "$#" -eq 2 ]; then
  check_range "$1" "$2"
elif [ "$#" -eq 0 ]; then
  select_github_range
else
  printf 'usage: %s [BASE HEAD | --self-test]\n' "$0" >&2
  exit 2
fi