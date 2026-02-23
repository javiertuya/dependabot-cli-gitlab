#!/bin/bash

# Performs the full update process by running Dependabot CLI and then creating/updating GitLab MRs.

# See examples and descriptions of parameters in .github/workflows/update.yml

if [ $# -ne 8 ]; then
  echo "Usage: $0 <result-json-file> <hostname-with> <path> <repo> <directories> <base-branch> <assignee-id-or-0> <dry-run>"
  exit 1
fi

if [ -f "dependabot" ]; then # Dependabot command a local downloaded file in CI
  DEPENDABOT_CMD=./dependabot
else # But a global command that must be installed using go (in windows)
  DEPENDABOT_CMD=dependabot
fi

echo "Dependabot CLI command: $DEPENDABOT_CMD"
# Clean temporary work files from previous executions
rm -f update-result.json
rm -f update-job.yml

# The job configuration file must be preprocessed because dependabot CLI does not replaces
# environment variables, except the credentials.password
# Multiple directories are allowed if separated with comma and without blank spaces
sed -e "s|\$GL_HOST|$2|" \
    -e "s|\$GL_PATH|$3|" \
    -e "s|\$GL_REPO|$4|" \
    -e "s|\$GL_DIRECTORY|$5|" \
    -e "s|\$GL_BRANCH|$6|" \
    $1 > update-job.yml

# Get the package manager name from the job file for later use when creating the MR
ECOSYSTEM=$(grep "package-manager:" update-job.yml | sed 's/.*: //' | xargs)

echo "" >> update-log.log
echo "**************************************************************************************************"
echo "*** Dependabot CLI job: $1, server: $2$3, package manager: $ECOSYSTEM" | tee -a update-log.log
echo "*** Repository: $4, directory: $5, branch: $6, assignee id: $7" | tee -a update-log.log
echo "*** Using this job description:"
cat update-job.yml
echo "**************************************************************************************************"

# Dependabot will set the result in a json that will be used later to create the MRs
# Workaround for nuget: in this case we need to clone the repo first because dependabot CLI seems to have an issue
# (https://github.com/dependabot/cli/issues/517) that makes the update fail because it cannnot find Microsoft.Build, Version=15.1.0.0
# Note1: this does not work in windows, but does in GitHub Actions linux runners
# Note2: the log produced does not show a summary of the updates, but the update-result.json file is correctly created
if [ "$ECOSYSTEM" = "nuget" ]; then
  rm -rf update-workdir
  git clone "https://oauth2:$GITLAB_TOKEN@$2$3/$4.git" update-workdir || exit 1
  # Feb 21th 2026: Updating coverlet.collector from v6.0.4 to v8.0.0 fails the dependabot update command,
  # but generates a (mostly) valid update-result.json that includes an object to create this PR where all attributes are empty.
  # The log shows a message like "cli | (date) yaml: found invalid Unicode character escape code" when processing coverlet.
  # To fix this issue, we remove the "|| exit 1" condition in the below command tp allow continue by executing create.sh.
  # In create.sh we check for empty attributes to ignore the problematic PR.
  # If for any other reason the update-result.json file is not created, the create.sh script will fail when trying to read it 
  # and exit with error, so we are covered in that case.
  $DEPENDABOT_CMD update -f update-job.yml --local update-workdir --timeout 20m > update-result.json
  cat update-result.json
else
  $DEPENDABOT_CMD update -f update-job.yml --timeout 20m > update-result.json || exit 1
fi

# Create the MR, retry once if fails
./create.sh update-result.json $2$3 $4 $6 $ECOSYSTEM $7 $8
if [ $? -ne 0 ]; then
  echo "*** Error executing create.sh, retry after a delay"  | tee -a update-log.log
  sleep 10
  ./create.sh update-result.json $2$3 $4 $6 $ECOSYSTEM $7 $8
  if [ $? -ne 0 ]; then
    echo "*** Error executing create.sh after retry, exiting with error" | tee -a update-log.log
    exit 1
  fi
fi
