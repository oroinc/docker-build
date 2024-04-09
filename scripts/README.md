# Scripts for source code

Scripts to build application and run some types of tests that not require addon services.

## Application Source Code

Access to the application source code is required to run scripts. Use `git clone <application repository>`. Scripts can be used with any Oro application located in any folder.

```bash
git clone http://github/laboro/dev
cd dev/application/commerce-crm-ee
```

## Common options for all scripts

- `-s` | `--source` parameter can be used to define the path to the the application source code.

If the script runs from the application source code directory, it automatically determine the location as current.

- `-b` | `--baseline` docker images baseline version

You must specify the baseline version depending on the version of your application. See `baseline/README.md` for more details about versioning.

- `-h` | `--help` show help

## Scripts:
### `composer.sh`
Script wraps the execution of dependency management tools (composer and npm) to the application builder container, so no additional software should be installed on the host. It runs the installation of dependencies by default.
The user's home folder is mounted in the container to provide access to the composer and npm cache, configs, and credentials required for the composer. If access is not configured, specify the `COMPOSER_AUTH='{"http-basic": {"github.com": {"username": "x-access-token", "password": "$GITHUB_TOKEN"}}, "gitlab-oauth": {"$GITLAB_DOMAIN": "$GITLAB_TOKEN"}}'`
where:
- `GITHUB_TOKEN` - to access private composer repositories with the http-basic authentication
- `GITLAB_TOKEN` - to access private composer repositories in GitLab with the gitlab-oauth authentication
- `GITLAB_DOMAIN` - domain name for GitLab. Example: `git.oroinc.com`

All composer environment variables are supported: https://getcomposer.org/doc/03-cli.md#environment-variables

If you use a monolithic repository, specify `COMPOSER_MIRROR_PATH_REPOS=1` to copy packages to the vendors folder rather than creating links.

On weak computers, increase the timeout for webpack to be able to build assets: `COMPOSER_PROCESS_TIMEOUT=600`

For ODP applications, specify the database version: `ORO_DB_VERSION=15`


```bash
ORO_DB_VERSION=15 COMPOSER_PROCESS_TIMEOUT=600 COMPOSER_MIRROR_PATH_REPOS=1 ../../docker-build/scripts/composer.sh  -b 6.0-latest -r "../.."
```

**Note:** After installing the composer bundles, you can run other scripts that do not require the installation of the application.

### `test_unit.sh`
This script starts phpunit. By default, the script runs all tests it finds in the `Tests/Unit` folders in parallel. Failed tests are displayed at the end after all other tests.
```bash
../../docker-build/scripts/test_unit.sh -b 6.0-latest
```
You can check tests or specify other options for phpunit after the script:
```bash
../../docker-build/scripts/test_unit.sh -b 6.0-latest -- vendor/oro/redis-config/Tests/Unit/Service/Setup
```

### `test_php-cs-fixer.sh`, `test_phpcs.sh`, `test_phpmd.sh`
These are scripts to run php-cs-fixer or phpcs or phpmd. If you do not specify a file (by setting it in variables DIR_DIFF and FILE_DIFF) with a list of files, then it checks all found php files. Otherwise, it only checks the files from the list.
```bash
../../docker-build/scripts/test_php-cs-fixer.sh -b 6.0-latest
```
or with diff file:
```bash
DIR_DIFF=. FILE_DIFF=diff_file.txt ../../docker-build/scripts/test_php-cs-fixer.sh -b 6.0-latest
```
**Note:** The results of tests are in docker instance. You can copy it to host from instance.

