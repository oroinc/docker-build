# Jenkins Configuration as Code

- [Overview](#overview)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [Usage](#usage)
- [Additional reading](#additional-reading)

## Overview

Welcome to the Jenkins Configuration as Code tool! This repository provides you with everything you need to set up [Jenkins CI](https://jenkins.io) using Docker Compose. By leveraging these tools, you can run Jenkins in a container and execute jobs effortlessly. The same setup is used internally in Oro.

## Requirements

Before you start, ensure you have the following requirements are met:

- Docker
- Docker Compose

This setup works on any operating system with Docker support, but we recommend using a Linux-based OS for optimal performance.

## Configuration

Before launching Jenkins, follow these configuration steps:

### Jenkins Configuration

1. **Specify Docker Group GID**: Open the `.env` file and set the `DOCKER_GROUP_ID` variable to the GID of the docker group on your system. To find the GID, run the following command:
    ```
    getent group docker | cut -d: -f3
    ```
2. **Set UID and GID Variables**: Determine the `UID` and `GID` of your user account and set them as variables in the `.env` file. Use the following commands to find them:
   ```
    id -u
    # 1000
   
    id -g
    # 1000
   ```
   
3. **Set GitLab and GitHub credentials**: Create [GitLab Personal access token](https://git.oroinc.com/-/profile/personal_access_tokens) with `api`, `read_api`, `read_user` and `read_repository` scopes and [GitHub Personal access token](https://github.com/settings/tokens) with `read` scope. Then, fill in the following data in `.env` file:
   ```
   GITHUB_USER_NAME=github_user
   GITHUB_USER_TOKEN=ghp_xxxxxxxxxxxxx
   
   GITLAB_USER_NAME=gitlab_user
   GITLAB_USER_TOKEN=glpat-xxxxxxxxxxxxx
   ```
4. **Configure GitLab repository**: Configure your project in the `.env` file
   ```
   # Example for https://gitlab.com/gitlab-org/gitlab-foss
   
   GITLAB_DOMAIN=https://gitlab.com
   GITLAB_PROJECT_OWNER=gitlab-org
   GITLAB_PROJECT_PATH=gitlab-org/gitlab-foss
   ```

### Project Configuration

@slava - please describe required changes in `.env-build` and `Jenkinsfile`.

## Usage

Once both Jenkins and your project are configured, you can start the Jenkins instance, by running the following command: 

```
docker compose up -d
```

The Jenkins instance will be accessible at http://localhost:8080. Open this URL in your browser to access the Jenkins GUI and start running jobs.

### Jobs
Two jobs are created by default:
- [docker-pipeline-example](http://localhost:8080/job/docker-pipeline) - Pipeline job example
- [orocommerce-application](http://localhost:8080/job/orocommerce-application) - The pipeline to run `Jenkinsfile` from repository https://github.com/oroinc/orocommerce-application.git. The job clones the repository's 5.1.0 tag, builds the application, creates the application runtime, test, init, and init-test images, runs code style and unit tests. The Jenkinsfile also provides an example of how to run functional tests and Behat tests (commented out).

For more information, see [Advanced configuration](./doc/configuration.md).
