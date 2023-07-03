# Jenkins configurations to run CI/CD

This folder contains docker compose configuration and Jenkins Configuration as Code. This allows you to run the [Jenkins CI](https://jenkins.io) in a container and run jobs. That will allow you to quickly and easily deploy the CI/CD environment used by ORO. And use it locally for easy testing, or as an example to deploy on your servers.

## Requirements

The main requirement is docker and docker compose plugin. You can use any operating system with docker support, but a Linux-based OS is recommended.

## Configuration

Before you start, you need to specify the GID of the docker group in the DOCKER_GROUP_ID variable in the `.env` file. To determine the GID, use the following command:
```
getent group docker | cut -d: -f3
```
You also need to set the UID and GID variables. To determine the UID and GID, use the following command:
```
$ id -u
1000
$ id -g
1000
```

### Configuration for private repositories
Several credentials may be required if you use private repositories, depending on what resources you require access to.

#### Use gitlab for project code
Two credentials need to be configured:
1. A type of `GitLab Personal Access Token` with scope `api` via which communication with the API is carried out. Used in global settings.  Note: Make sure to give the `sudo`  capability to an admin  as it is required for the configuration of systemhooks and triggering of MRs). 
2. A type of `User Name with Password` used to clone the git repository. Used in a job.
More details https://plugins.jenkins.io/gitlab-branch-source/

#### Use github for project code
To use a private repository from github, we  recommend using the credentials type `GitHub Application`. For more information, see https://github.com/jenkinsci/github-branch-source-plugin/blob/master/docs/github-app.adoc

#### Composer authentication
Composer must be authorized to install vendors from private repositories. Because vendors can be located both on GitLab and/or on GitHub, we authorize both and provide http-basic authentication for composer. To do this, use the `GitHub Application` credentials type or a `Username with password`, where a personal access token is used as the password.

#### Access to the docker registry where the images should be stored.
After building the images, the job pushes them into the registry. If this is a private registry, then you also need to provide credentials for access. This is typically done using the credentials type `User Name and Password`.
Alternatively, if the registry is in GCP, then you need to create a service account and get a json file with an authorization key. For more information, see https://cloud.google.com/iam/docs/service-account-creds

**Note:** The credentials ID you create must match the credentials ID in the `Jenkinsfile`.

You can specify credentials in `.env` and use `jcasc/credentials.yaml` as an example. For a more detailed example, see https://github.com/jenkinsci/configuration-as-code-plugin/blob/master/demos/credentials/README.md and https://github.com/jenkinsci/configuration-as-code-plugin/blob/master/docs/features/secrets.adoc

## Run jenkins master

To launch a jenkins instance, run:
```
docker compose up -d
```

The instance will start at http://localhost:8080 . You can open Jenkins GUI in your browser. The system is completely ready to work.

## Jobs
Two jobs are created by default:
- [docker-pipeline-example](http://localhost:8080/job/docker-pipeline) - Pipeline job example
- [orocommerce-application](http://localhost:8080/job/orocommerce-application) - The pipeline to run `Jenkinsfile` from repository https://github.com/oroinc/orocommerce-application.git. The job clones the repository's `5.1.0` tag, builds the application, creates the application runtime, test, init and init-test images, runs code style and unit tests. The `Jenkinsfile` also provides an example of how to run functional tests and behat tests (commented out).
