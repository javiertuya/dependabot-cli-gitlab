# dependabot-cli-gitlab

Scripts to run Dependabot CLI for GitLab repos.

- Prerequisites and inputs:
  - Dependabot command: Either download the dependabot binary to the root folder or install it with the command 
    `go install github.com/dependabot/cli/cmd/dependabot@latest`
  - Job descriptions: Located in the `jobs` folder. Each yml file includes placeholders that will be replaced by command line parameters
  - Environment variables GITLAB_USERNAME, GITLAB_EMAIL and GITLAB_TOKEN with read/write permission to the repo to be updated
- Run the main script `update.sh` with parameters (See the description of parameters in .github/workflows/update.yml):
  - Copies the job description file indicated by the first parameter to `update-job.yml` and replaces the placeholders by the parameters (except gitlab username and token)
  - Runs the dependabot cli command to produce the `update-result.json` that contains the required info about the MRs to to update
  - Runs the `create.sh` script to create the GitLab MRs
