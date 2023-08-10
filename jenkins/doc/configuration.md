## Additional Configuration

### Configuration for Private Repositories
Several credentials may be required if you use private repositories, depending on what resources you require access to.

#### Use Gitlab for Project Code

Two credentials need to be configured:

1. A type of `GitLab Personal Access Token` with scope `api` via which communication with the API is carried out. Used in global settings.  Note: Make sure to give the `sudo`  capability to an admin  as it is required for the configuration of systemhooks and triggering of MRs).

2. A type of `User Name with Password` used to clone the git repository. Used in a job. See more here: https://plugins.jenkins.io/gitlab-branch-source/

#### Use Github for Project Code

To use a private repository from github, we recommend using the credentials type `GitHub Application`. For more information, see https://github.com/jenkinsci/github-branch-source-plugin/blob/master/docs/github-app.adoc

#### Composer Authentication

Composer must be authorized to install vendors from private repositories. Because vendors can be located both on GitLab and/or on GitHub, we authorize both and provide http-basic authentication for composer. To do this, use the `GitHub Application` credentials type or a `Username with password`, where a personal access token is used as the password.

#### Access to the Docker Registry

After building the images, the job pushes them into the registry. If this is a private registry, then you also need to provide credentials for access. This is typically done using the credentials type `User Name and Password`.
Alternatively, if the registry is in GCP, then you need to create a service account and get a json file with an authorization key. For more information, see https://cloud.google.com/iam/docs/service-account-creds

**Note:** The credentials ID you create must match the credentials ID in the `Jenkinsfile`.

You can specify credentials in `.env` and use `jcasc/credentials.yaml` as an example. For a more detailed example, see https://github.com/jenkinsci/configuration-as-code-plugin/blob/master/demos/credentials/README.md and https://github.com/jenkinsci/configuration-as-code-plugin/blob/master/docs/features/secrets.adoc
