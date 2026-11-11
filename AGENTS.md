# Agent instructions

## Code review

Every pull request into `main` needs a code review on record before it merges. This is our SOC 2 change-management control (CC8.1), and auditors sample pull requests to check it. The rule is the same as in Eragon_s.

1. A review that counts is one of these, on the pull request itself: a Greptile, CodeRabbit, or Codex review, a Greptile summary comment, or a review from a teammate other than the author.
2. A CodeRabbit summary comment alone does not count. It appears even when CodeRabbit reviewed nothing ("Review limit reached").
3. If you ran your own review, post it with `gh pr review <pr> --comment --body-file <file>`. Start the body with `<!-- ai-review -->`, and list the reviewer, the commit reviewed, and the findings.

The `ai-review` check (`scripts/ai-review-gate.sh`) stays red until one exists. A fix pushed after the review keeps the check green.

When a review that counts covers the head commit, the gate also approves the pull request as `github-actions[bot]`. A push after that dismisses the approval until the new head is reviewed, and a request for changes that still stands blocks it until that reviewer approves or the request is dismissed. Branch protection on `main` requires the check and one approval, and admins are held to both. The gate's approval is that one approval, so a pull request merges once a review covers its head.

To see which reviews count on a pull request, run `GH_REPO=eragon-corp/eragon-desktop-releases scripts/ai-review-gate.sh <pr> --list`.
