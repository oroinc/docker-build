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

The script also passes the credentials of a private npm registry to the container:
- `NPM_TOKEN` - for a project `.npmrc` that refers to it as `${NPM_TOKEN}`. Only npm expands it: pnpm 12 does not expand variables in the credentials of a project `.npmrc`, unless the same file is set as `PNPM_CONFIG_NPMRC_AUTH_FILE`.
- `PNPM_CONFIG_NPMRC_AUTH_FILE` (or `pnpm_config_npmrc_auth_file`) - the path to a user-level auth file for pnpm with lines such as `//<registry>/:_authToken=${NPM_TOKEN}`, where pnpm expands the variables. The file replaces `~/.npmrc` for pnpm, and a `registry` line in it applies where the project `.npmrc` does not set a registry. The file must be in a folder mounted in the container: the home folder, the application, or the repository (`-r`).
- `pnpm_config__auth` (or `PNPM_CONFIG__AUTH`) - the tokens of the registries for pnpm as JSON: `'{"https://<registry>":{"@":{"authToken":"<token>"}}}'`. The `"@"` entry also makes this registry the default one instead of the `registry` setting of the project `.npmrc`.

The `pnpm_config_//<registry>/:_authToken` variables of pnpm are not supported: PHP does not pass a variable with a dot in its name to the scripts that composer runs.

If you use a monolithic repository, specify `COMPOSER_MIRROR_PATH_REPOS=1` to copy packages to the vendors folder rather than creating links.

On weak computers, increase the timeout for webpack to be able to build assets: `COMPOSER_PROCESS_TIMEOUT=600`

For ODP applications, specify the database version: `ORO_DB_VERSION=15`


```bash
ORO_DB_VERSION=15 COMPOSER_PROCESS_TIMEOUT=600 COMPOSER_MIRROR_PATH_REPOS=1 ../../docker-build/scripts/composer.sh  -b master-latest -r "../.."
```

**Note:** After installing the composer bundles, you can run other scripts that do not require the installation of the application.

### `test_unit.sh`
This script starts phpunit. By default, the script runs all tests it finds in the `Tests/Unit` folders in parallel. Failed tests are displayed at the end after all other tests.
```bash
../../docker-build/scripts/test_unit.sh -b master-latest
```
You can check tests or specify other options for phpunit after the script:
```bash
../../docker-build/scripts/test_unit.sh -b master-latest -- vendor/oro/redis-config/Tests/Unit/Service/Setup
```

### `test_php-cs-fixer.sh`, `test_phpcs.sh`, `test_phpmd.sh`
These are scripts to run php-cs-fixer or phpcs or phpmd. If you do not specify a file (by setting it in variables DIR_DIFF and FILE_DIFF) with a list of files, then it checks all found php files. Otherwise, it only checks the files from the list, or all of them when the list has a change of the linter config (`package/platform/build/`) or of the PHP dependencies (`composer.json`, `dev.json` or `dev.lock` of `application/*`).
```bash
../../docker-build/scripts/test_php-cs-fixer.sh -b master-latest
```
or with diff file:
```bash
DIR_DIFF=. FILE_DIFF=diff_file.txt ../../docker-build/scripts/test_php-cs-fixer.sh -b master-latest
```
**Note:** The results of tests are in docker instance. You can copy it to host from instance.

### `test_deptrac.sh`
This script executes Deptrac to analyze dependencies in PHP files specified in the [deptrac.yaml](../../package/platform/build/deptrac.yaml) configuration. It helps enforce architectural rules and detect violations.
```bash
../../docker-build/scripts/test_deptrac.sh -b master-latest
```

### `test_behat_wiring_cs.sh`
This script runs a Code Style (CS) check for Behat .feature files. It filters the relevant feature files and runs a CS validation checkup.
```bash
../../docker-build/scripts/test_behat_wiring_cs.sh -b master-latest
```

### `test_javascript_eslint.sh`
This script performs ESLint analysis on JavaScript files located in Oro bundles. With `var/logs/diff.txt` it checks only the changed `.js` files, or all of them when the change touches the ESLint config (`application/*/.eslint*`) or the JS dependencies (`package.json` or `pnpm-lock.yaml` of `application/*` or `application/*/dev`).
```bash
../../docker-build/scripts/test_javascript_eslint.sh -b master-latest
```

### `test_javascript_stylelint.sh`
This script performs SCSS linting for Oro bundles using Stylelint. It analyzes only ```.scss``` files that were changed and not excluded by ```.stylelint``` ignore, or all of them when the change touches the Stylelint config (`npm-package/stylelint-config`, `application/*/.stylelint*`) or the JS dependencies (`package.json` or `pnpm-lock.yaml` of `application/*` or `application/*/dev`).
```bash
../../docker-build/scripts/test_javascript_stylelint.sh -b master-latest
```

### `test_validate_css.sh`
This script runs CSS validation using Stylelint for compiled assets.
It builds the frontend with Webpack in production mode and then lints the resulting CSS files.
```bash
../../docker-build/scripts/test_validate_css.sh -b master-latest
```
