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
# The approval is about the head commit. When a review that counts was made
# on the head commit (see approving_reviews) and no request for changes
# stands, github-actions[bot] approves the pull request at that commit. That
# approval is what Vanta's per-PR approval test reads. A bot approval on any
# other commit, or while no review covers the head, is dismissed. A fix
# pushed after a review keeps the check green but needs a review of the new
# head before the bot approves again.
#
#   scripts/ai-review-gate.sh <pr-number>            evaluate and post
#   scripts/ai-review-gate.sh <pr-number> --dry-run  evaluate and print
#   scripts/ai-review-gate.sh <pr-number> --list     print the reviews that
#       count, one per line, for a pull request in any state; nothing is
#       posted.
#
# Needs: gh (authenticated; GH_REPO set outside Actions). Approving needs a
# token that may approve pull requests: the Actions token with
# `pull-requests: write` and the repository setting that lets Actions approve.
set -euo pipefail

CHECK_NAME="ai-review"
BOT="github-actions[bot]"

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

# Reviews that earn the bot's approval: a review object (its commit_id is
# set by GitHub, unlike a comment's text, which anyone with write access can
# edit) that counts above and was made on the full head commit, approving or
# commenting. A Greptile summary comment keeps the check green but does not
# earn an approval. A person's review earns it only when they can write to
# the repository, as GitHub requires for its own approvals. A review that
# counts only through the marker was posted by the author's own agent, and
# its line says so. This repository is public, so a person's review and a
# marker review both earn it only with write access.
# shellcheck disable=SC2016
approving_reviews() {
  local candidates login kind line perm
  candidates="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/reviews" --jq '
    .[]
    | select(.state == "APPROVED" or .state == "COMMENTED")
    | select(.commit_id == "'"$head"'")
    | (if (.user.login == "greptile-apps[bot]"
            or .user.login == "coderabbitai[bot]"
            or .user.login == "chatgpt-codex-connector[bot]") then "app"
       elif (.user.type == "User" and .user.login != "'"$author"'") then "person"
       elif ((.body // "") | test("^\\s*<!-- ai-review -->")) then "own"
       else empty end) as $kind
    | "\(.user.login)\t\($kind)\t- \(.user.login) reviewed `\(.commit_id)`\(if $kind == "own" then " (posted by the author, an own AI review)" else "" end): \(.html_url)"')"
  while IFS=$'\t' read -r login kind line; do
    [ -n "$login" ] || continue
    if [ "$kind" = person ] || [ "$kind" = own ]; then
      perm="$(gh api "repos/{owner}/{repo}/collaborators/$login/permission" --jq .permission 2>/dev/null || true)"
      case "$perm" in admin|maintain|write) ;; *) continue ;; esac
    fi
    printf '%s\n' "$line"
  done <<<"$candidates"
}

# Requests for changes that still stand: a reviewer's latest review that
# approved or requested changes, on any commit, is a request for changes.
# This is how GitHub reads it: it stands until the same reviewer approves
# or someone dismisses it. This repository is public, so, as GitHub does,
# only a request from someone with write access counts.
changes_requested() {
  local reviews login url perm
  reviews="$(gh api --paginate --slurp "repos/{owner}/{repo}/pulls/$pr/reviews" | jq -r '
    [.[][] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
    | group_by(.user.login)[] | max_by(.submitted_at)
    | select(.state == "CHANGES_REQUESTED") | "\(.user.login)\t\(.html_url)"')"
  while IFS=$'\t' read -r login url; do
    [ -n "$login" ] || continue
    perm="$(gh api "repos/{owner}/{repo}/collaborators/$login/permission" --jq .permission 2>/dev/null || true)"
    case "$perm" in admin | maintain | write) printf '%s\n' "$url" ;; esac
  done <<<"$reviews"
}

# The bot's approvals that still stand, as `<review id> <commit>` lines.
bot_approvals() {
  gh api --paginate "repos/{owner}/{repo}/pulls/$pr/reviews" --jq '
    .[] | select(.user.login == "'"$BOT"'" and .state == "APPROVED")
    | "\(.id) \(.commit_id)"'
}

# $1: "keep" to keep an approval on the head commit, anything else to
# dismiss every bot approval. $2: the reason, shown on each dismissal.
# The lookup is captured first: a failure inside a here-string would not
# stop the script, and a missed dismissal leaves a stale approval standing.
dismiss_bot_approvals() {
  local id commit approvals
  approvals="$(bot_approvals)"
  while read -r id commit; do
    [ -n "$id" ] || continue
    if [ "$1" = keep ] && [ "$commit" = "$head" ]; then continue; fi
    echo "dismiss bot approval $id on ${commit:0:9}: $2"
    [ "$mode" = "--dry-run" ] && continue
    gh api -X PUT "repos/{owner}/{repo}/pulls/$pr/reviews/$id/dismissals" \
      -f message="$2" -f event=DISMISS >/dev/null
  done <<<"$approvals"
}

# Approve the head commit unless the bot already has. $1: the reviews it
# rests on, quoted in the approval.
approve_head() {
  local id commit approvals
  approvals="$(bot_approvals)"
  while read -r id commit; do
    if [ -n "$id" ] && [ "$commit" = "$head" ]; then
      echo "bot approval $id already on ${head:0:9}"
      return 0
    fi
  done <<<"$approvals"
  echo "approve ${head:0:9} as $BOT"
  [ "$mode" = "--dry-run" ] && return 0
  gh api "repos/{owner}/{repo}/pulls/$pr/reviews" \
    -f event=APPROVE -f commit_id="$head" \
    -f body="$(printf 'Approved by the ai-review gate for commit %s. It rests on these reviews of that commit:\n\n%s' "$head" "$1")" >/dev/null
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
  # The approval is settled before the check is posted: a failed lookup then
  # stops the run before a green check can stand beside a stale approval.
  on_head="$(approving_reviews)"
  blocked="$(changes_requested)"
  if [ -n "$blocked" ]; then
    dismiss_bot_approvals none "A request for changes stands; the ai-review gate withdrew its approval."
    echo "a request for changes stands; no approval"
  elif [ -n "$on_head" ]; then
    dismiss_bot_approvals keep "New commits since this approval; the ai-review gate approves only a reviewed head."
    approve_head "$on_head"
  else
    dismiss_bot_approvals none "No review covers the head commit; the ai-review gate approves only a reviewed head."
    echo "no review on ${head:0:9}; no approval"
  fi
  count="$(printf '%s\n' "$reviews" | wc -l | tr -d ' ')"
  post success "$count review(s) on record" "$reviews"
else
    dismiss_bot_approvals none "No review covers the head commit; the ai-review gate approves only a reviewed head."
    echo "no review on ${head:0:9}; no approval"
  fi
else
  dismiss_bot_approvals none "No review on record; the ai-review gate withdrew its approval."
  # Exit 0 after posting the failure: this job's work is posting the check,
  # and a red job next to the red check would say the same thing twice.
  post failure "no review on record" \
    "No Greptile, CodeRabbit, Codex, or teammate review, no Greptile summary comment, and no review starting with \`<!-- ai-review -->\`. If you ran your own review, post it with \`gh pr review $pr --comment --body-file <file>\` and start the body with that marker. AGENTS.md has the rule."
fi
