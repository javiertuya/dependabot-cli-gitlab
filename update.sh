#!/bin/bash

# Performs the full update process by running Dependabot CLI and then creating/updating GitLab MRs.

# See example usaes in .github/workflows/update.yml

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

# Get language label (to ad in the MR) from package manager name
ECOSYSTEM=$(grep "package-manager:" update-job.yml | sed 's/.*: //' | xargs)

echo "**************************************************************************************************"
echo "*** Dependabot CLI server: $2$3, package manager: $ECOSYSTEM"
echo "*** Repository: $4, directory: $5, branch: $6, assignee id: $7"
echo "*** Using this job description:"
cat update-job.yml
echo "**************************************************************************************************"

# Dependabot will set the result in a json that will be used later to create the MRs
$DEPENDABOT_CMD update -f update-job.yml --timeout 20m > update-result.json
#cat update-result.json

# Create the MR,
./create.sh update-result.json $2$3 $4 $6 $ECOSYSTEM $7
