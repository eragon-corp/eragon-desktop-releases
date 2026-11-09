#!/usr/bin/env bash
# The `ai-review` check on a pull request into main.
#
# This is our SOC 2 change-management control (CC8.1): every change that
# reaches main has an independent review on record, and auditors sample pull
# requests to confirm it. It is the same rule and the same script as Eragon_s
# (scripts/ai-review-gate.sh there). A review counts only when it is on the
# pull request itself, because that is the one place an auditor can find it
# later:
#
#   - a review by Greptile, CodeRabbit, or Codex,
#   - a Greptile summary comment: an issue comment by greptile-apps[bot] with
#     its summary marker, a confidence score and the commit it last reviewed,
#   - a review by a person other than the author, or
#   - a review whose body starts with `<!-- ai-review -->`, which is how an
#     agent records its own adversarial review (AGENTS.md says how).
#
# This repository is public, so anyone with a GitHub account can post a
# review. A person's review, and a review with the marker, count only from
# someone with write access to the repository.
#
# A CodeRabbit summary comment does not count: it is posted even when
# CodeRabbit reviewed nothing ("Review limit reached", no review seat).
#
# The verdict is about the pull request, not its head commit: a fix pushed
# after a review keeps that review. It is posted as a check run on the head
# commit by this script rather than by the job that runs it, so a review
# submitted later lands on the commit the merge button looks at.
#
#   scripts/ai-review-gate.sh <pr-number>            evaluate and post
#   scripts/ai-review-gate.sh <pr-number> --dry-run  evaluate and print
#   scripts/ai-review-gate.sh <pr-number> --list     print the reviews that
#       count, one per line, for a pull request in any state; nothing is
#       posted.
#
# Needs: gh (authenticated; GH_REPO set outside Actions).
set -euo pipefail

CHECK_NAME="ai-review"

pr="${1:?pull request number}"
mode="${2:-post}"

# Captured, not read from a process substitution: that hides a failed lookup
# from `set -e`, and empty fields would read as a closed pull request here and
# as "no review" in release notes.
pr_fields="$(gh pr view "$pr" --json headRefOid,baseRefName,state,author \
  --jq '[.headRefOid, .baseRefName, .state, .author.login] | @tsv')"
IFS=$'\t' read -r head base state author <<<"$pr_fields"

post() {
  # $1 conclusion, $2 title, $3 summary
  echo "ai-review: $1 — $2"
  echo "$3"
  [ "$mode" = "--dry-run" ] && return 0
  # Update every earlier verdict on this commit rather than add one. In this
  # public repository each run's check lands in that run's own check suite,
  # and branch protection keeps reading an old red one next to a new green.
  local ids id
  ids="$(gh api "repos/{owner}/{repo}/commits/$head/check-runs?check_name=$CHECK_NAME&filter=all" \
    --jq '.check_runs[] | select(.app.slug == "github-actions") | .id')"
  if [ -z "$ids" ]; then
    gh api "repos/{owner}/{repo}/check-runs" \
      -f name="$CHECK_NAME" -f head_sha="$head" -f status=completed -f conclusion="$1" \
      -f "output[title]=$2" -f "output[summary]=$3" >/dev/null
    return 0
  fi
  for id in $ids; do
    gh api -X PATCH "repos/{owner}/{repo}/check-runs/$id" \
      -f status=completed -f conclusion="$1" \
      -f "output[title]=$2" -f "output[summary]=$3" >/dev/null
  done
}

# Dismissed reviews do not count: dismissing one is how a reviewer withdraws it.
# This repository is public, so a person's review and a marker review count
# only from someone with write access. Access is read from the collaborator
# permission API: `author_association` depends on who reads it, and the
# Actions token sees private org members as CONTRIBUTOR.
# shellcheck disable=SC2016 # `$author` is spliced in; the rest is jq, not shell.
counted_reviews() {
  local login kind line perm
  gh api --paginate "repos/{owner}/{repo}/pulls/$pr/reviews" --jq '
    .[]
    | select(.state != "DISMISSED")
    | (if .user.login == "greptile-apps[bot]"
          or .user.login == "coderabbitai[bot]"
          or .user.login == "chatgpt-codex-connector[bot]" then "bot"
       elif .user.type == "User" and .user.login != "'"$author"'" then "person"
       elif ((.body // "") | test("^\\s*<!-- ai-review -->")) then "person"
       else "none" end) as $kind
    | select($kind != "none")
    | [.user.login, $kind, "- \(.user.login) reviewed `\(.commit_id[0:9])`: \(.html_url)"]
    | @tsv' |
  while IFS=$'\t' read -r login kind line; do
    if [ "$kind" = person ]; then
      perm="$(gh api "repos/{owner}/{repo}/collaborators/$login/permission" --jq .permission 2>/dev/null || true)"
      case "$perm" in admin | maintain | write) ;; *) continue ;; esac
    fi
    printf '%s\n' "$line"
  done
}

# Greptile's summary comment: its marker, score and last reviewed commit.
greptile_summaries() {
  gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" --jq '
    .[]
    | select(.user.login == "greptile-apps[bot]")
    | (.body // "") as $body
    | select($body | contains("<!-- greptile_summary -->"))
    | ([$body | match("<!-- greptile_confidence_score:([0-9]+) -->").captures[0].string] | first) as $score
    | ([$body | match("Last reviewed commit:[^\\n]*?/commit/([0-9a-f]{40})").captures[0].string] | first) as $commit
    | select($score != null and $commit != null)
    | "- greptile-apps[bot] summarized `\($commit[0:9])` at \($score)/5: \(.html_url)"'
}

reviews_on_record() {
  counted_reviews
  greptile_summaries
}

if [ "$mode" = "--list" ]; then
  reviews_on_record
  exit 0
fi

if [ "$state" != "OPEN" ]; then
  echo "#$pr is $state, nothing to gate"
  exit 0
fi
if [ "$base" != "main" ]; then
  post success "not a pull request into main" \
    "#$pr targets \`$base\`; the review rule applies to \`main\`."
  exit 0
fi
reviews="$(reviews_on_record)"
if [ -n "$reviews" ]; then
  count="$(printf '%s\n' "$reviews" | wc -l | tr -d ' ')"
  post success "$count review(s) on record" "$reviews"
else
  # Exit 0 after posting the failure: this job's work is posting the check,
  # and a red job next to the red check would say the same thing twice.
  post failure "no review on record" \
    "No Greptile, CodeRabbit, Codex, or teammate review, no Greptile summary comment, and no review starting with \`<!-- ai-review -->\`. If you ran your own review, post it with \`gh pr review $pr --comment --body-file <file>\` and start the body with that marker. AGENTS.md has the rule."
fi
