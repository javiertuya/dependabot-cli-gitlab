#!/bin/bash

# This is a customized version of the create.sh script from Dependabot CLI examples
# https://github.com/dependabot/example-cli-usage to create GitLab Merge Requests (MRs)

# Note at this time there is minimal error handling.

set -euo pipefail

if [ $# -ne 6 ]; then
  echo "Usage: $0 <result-json-file> <hostname-with-path> <repo> <target-branch> <label> <assignee-id-or-0>"
  exit 1
fi

INPUT="$1"
HOSTNAME="$2"
REPO="$3"
TARGET_BRANCH="$4"
ECOSYSTEM="$5"
ASSIGNEE="$6"
REPO_DIR="update-workdir"

echo "using package manager: $ECOSYSTEM"
if [ "$ECOSYSTEM" = "maven" ]; then LABEL="java"
elif [ "$ECOSYSTEM" = "npm_and_yarn" ]; then LABEL="javascript"
elif [ "$ECOSYSTEM" = "nuget" ]; then LABEL=".NET"
else LABEL="$ECOSYSTEM"
fi
echo "label: $LABEL"

echo "**************************************************************************************************"
echo "*** Creating GitLab MRs in $HOSTNAME for repo: $REPO, target branch: $TARGET_BRANCH , label: $LABEL, assignee: $ASSIGNEE ***" | tee -a update-log.log
echo "**************************************************************************************************"

# In addition to the parameters, the gitlab token must be set via an environment variable
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
if [ -z "$GITLAB_TOKEN" ]; then
  echo "Error: GITLAB_TOKEN environment variable is not set or empty."
  exit 1
fi

# Commits are creted in REPO_DIR as temporary work folder and pushed to GITLAB_REPO_URL
GITLAB_REPO_URL="https://oauth2:$GITLAB_TOKEN@$HOSTNAME/$REPO.git"

# Clean and clone the GitLab repository into a subdirectory
rm -rf "$REPO_DIR"
git clone "$GITLAB_REPO_URL" "$REPO_DIR" || exit 1
cd "$REPO_DIR"

# this is required to allow git commands, the email ensures that the he commits appear authored by the right user
# If not set, the default valuees are those specified in the original create.sh script from Dependabot examples
# (default values work fine in gitlab.com, but maybe not in other gitlab servers)
GITLAB_EMAIL="${GITLAB_EMAIL:-support@github.com}"
GITLAB_USERNAME="${GITLAB_USERNAME:-Dependabot Standalone}"
git config user.email "$GITLAB_EMAIL"
git config user.name "$GITLAB_USERNAME"
git config advice.detachedHead false

# Parse each create_pull_request event
jq -c 'select(.type == "create_pull_request")' "../$INPUT" | while read -r event; do
  # Extract fields
  BASE_SHA=$(echo "$event" | jq -r '.data."base-commit-sha"')
  PR_TITLE=$(echo "$event" | jq -r '.data."pr-title"')
  PR_BODY=$(echo "$event" | jq -r '.data."pr-body"')
  COMMIT_MSG=$(echo "$event" | jq -r '.data."commit-message"')
  BRANCH_NAME="dependabot/$ECOSYSTEM/$(echo -n "$COMMIT_MSG" | sha1sum | awk '{print $1}')"

  echo "**************************************************************"
  echo "Processing PR: $PR_TITLE"
  echo "  Base SHA: $BASE_SHA"
  echo "  Branch: $BRANCH_NAME"

  # Workaround for mssql-jdbc jre version qualifier issue in maven projects: https://github.com/dependabot/dependabot-core/issues/13911
  # Since January 2025, dependabot ignores the .jre8 non standard qualifier when updating mssql-jdbc dependency, leading to wong updates
  # Check if the update is for mssql-jdbc and if the version change is only in the jre qualifier, skip the MR creation
  PATCH_JRE11=""
  dependency=$(echo "$event" | jq -r '.data.dependencies[0].name')
  if [ "$dependency" = "com.microsoft.sqlserver:mssql-jdbc" ]; then
    before=$(echo "$event" | jq -r '.data.dependencies[0]."previous-version"')
    after=$(echo "$event" | jq -r '.data.dependencies[0]."version"')
    echo "  Applying workaround for mssql-jdbc jre version qualifier:"
    echo "    Try to update dependency: $dependency from $before to $after"
    if [ "${before//jre8/}" = "${after//jre11/}" ]; then
      echo "    Update contains the same version with different jre qualifier. Skipping creation of MR."
      continue
    else
      echo "    Different versions detected. Proceeding with MR creation by setting the $after qualifier to jre8."
      PR_TITLE="${PR_TITLE//$after/${after//jre11/jre8}} (PATCHED)"
      PR_BODY="${PR_BODY//$after/${after//jre11/jre8}} (PATCHED)"
      COMMIT_MSG="${COMMIT_MSG//$after/${after//jre11/jre8}} (PATCHED)"
      PATCH_JRE11="$after" # to be used later after wrtiting the changed files
    fi
  fi

  # Create and checkout new branch from base commit
  git fetch origin
  git checkout "$BASE_SHA"
  git checkout -b "$BRANCH_NAME"

  # Apply file changes
  echo "$event" | jq -c '.data."updated-dependency-files"[]' | while read -r file; do
    FILE_PATH=$(echo "$file" | jq -r '.directory + "/" + .name' | sed 's#^/*##')
    DELETED=$(echo "$file" | jq -r '.deleted')
    if [ "$DELETED" = "true" ]; then
      git rm -f "$FILE_PATH" || true
    else
      mkdir -p "$(dirname "$FILE_PATH")"
      chmod +w "$FILE_PATH" || true
      echo "$file" | jq -r '.content' > "$FILE_PATH"
      # Workaround for mssql-jdbc jre version qualifier issue (continued)
      if [ "$PATCH_JRE11" != "" ] && [[ "$FILE_PATH" == *"pom.xml"* ]]; then
        echo "    Patching $FILE_PATH to set mssql-jdbc version to $PATCH_JRE11 with jre8 qualifier"
        sed -i "s#<version>$PATCH_JRE11</version>#<version>${PATCH_JRE11//jre11/jre8}</version>#g" "$FILE_PATH"
      fi
      git add "$FILE_PATH"
    fi
  done

  # Commit and push
  echo "Committing and pushing changes to $BRANCH_NAME"
  git commit -m "$COMMIT_MSG"
  git push -f origin "$BRANCH_NAME" || exit 1

  echo "Creating Merge Request for $BRANCH_NAME with title: $PR_TITLE" | tee -a ../update-log.log
  project_id=${REPO//\//%2F}
  # Use jq to create JSON payload (to avoid issues with special characters)
  jq -n \
    --arg title "$PR_TITLE" \
    --arg description "$PR_BODY" \
    --arg source_branch "$BRANCH_NAME" \
    --arg target_branch "$TARGET_BRANCH" \
    --arg labels "dependencies,$LABEL" \
    --arg assignee "$ASSIGNEE" \
    '{title: $title, description: $description, source_branch: $source_branch, target_branch: $target_branch, labels: $labels, assignee_id: $assignee, remove_source_branch: true}' | \
  curl -X POST \
    -H "Authorization: Bearer $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d @- \
    "https://$HOSTNAME/api/v4/projects/$project_id/merge_requests" || echo "Failed to create MR"

  echo "Returning to main branch for next PR"
  git checkout $TARGET_BRANCH
done

cd ..
