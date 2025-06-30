#!/bin/sh -l

git_setup() {
  cat <<- EOF > $HOME/.netrc
    machine github.com
    login $GITHUB_ACTOR
    password $GITHUB_TOKEN
    machine api.github.com
    login $GITHUB_ACTOR
    password $GITHUB_TOKEN
EOF
  chmod 600 $HOME/.netrc

  git config --global user.email "$GITBOT_EMAIL"
  git config --global user.name "$GITHUB_ACTOR"
  git config --global --add safe.directory /github/workspace
}

git_cmd() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo $@
  else
    eval $@
  fi
}

[ "$ACTIONS_STEP_DEBUG" == "true" ] && set -x

git_setup
git remote add upstream ${INPUT_UPSTREAM}
git fetch --all

last_sha=$(git rev-list -1 upstream/${INPUT_UPSTREAM_BRANCH})
echo "Last commited SHA: ${last_sha}"

up_to_date=$(git rev-list origin/${INPUT_BRANCH} | grep ${last_sha} | wc -l)
pr_branch="${INPUT_SYNC_BRANCH_PREFIX}-${last_sha}"

if [[ "${up_to_date}" -eq 0 ]]; then

  git checkout -b "${pr_branch}" --track "upstream/${INPUT_UPSTREAM_BRANCH}"
  if [ "${INPUT_DENOISE_MESSAGE}" != "" ]; then
    echo "@ denoise enabled."
    if git merge "origin/${INPUT_BRANCH}"; then
        echo "@ denoised: merge commit"
    else
        echo "@ denoised: empty commit"
        git merge --abort
        git commit --allow-empty -m "${INPUT_DENOISE_MESSAGE}"
    fi
  fi

  git remote remove upstream
  hub pr list
  pr_exists=$(hub pr list | grep ${last_sha} | wc -l)

  if [[ "${pr_exists}" -gt 0 ]]; then
    echo "PR Already exists!!!"
    exit 0
  else
    git_cmd git push -u origin "${pr_branch}"
    git_cmd hub pull-request -b "${INPUT_BRANCH}" -h "${pr_branch}" -l "${INPUT_PR_LABELS}" -m "\"${INPUT_PR_TITLE}: ${last_sha}\""
  fi
else
  echo "Branch up-to-date"
fi

if [ "${INPUT_CLEANUP}" == "true" ];then
  echo "@ cleanup"
  gh pr list -l "${INPUT_PR_LABELS}" -S "in:title ${INPUT_PR_TITLE}" --json number -q '.[].number'
  for PR_NUMBER in gh pr list -l "${INPUT_PR_LABELS}" -S "in:title ${INPUT_PR_TITLE}" --json number -q '.[].number'; do
     pr_sha=$(gh pr view $PR_NUMBER --json title -q '.title' | sed 's/.*://')
     echo "cleanup $PR_NUMBER; sha: $pr_sha"
     if git log --oneline "$pr_sha" ;then
       base=$(git merge-base ${INPUT_BRANCH} ${pr_sha})
       if [ "$base" == "$pr_sha" ]; then
         git_cmd gh pr close "$PR_NUMBER" --comment "Content was already merged." --delete-branch
       fi
     fi
  done
fi
