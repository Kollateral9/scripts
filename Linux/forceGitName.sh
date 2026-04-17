#!/bin/bash

# Force git commit name on entire history on a given repo. Modify as needed
# Note: to use this script you must be in the root of the repo
# Note: on Windows use it in Git Bash

git filter-branch -f --env-filter '

export GIT_COMMITTER_NAME="klt9"
export GIT_COMMITTER_EMAIL="claudio.rosson91@gmail.com"
export GIT_AUTHOR_NAME="klt9"
export GIT_AUTHOR_EMAIL="claudio.rosson91@gmail.com"
' --tag-name-filter cat -- --branches --tags