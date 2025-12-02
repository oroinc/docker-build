# Docker Compose configurations to run and test the application

Below is the configuration for docker compose and configuration files for services, in addition to `.env`, where all the variables required for the services and the application are specified.

## Types of environment
The environments for CE (Community Edition) and EE (Enterprise Edition) are different. The `ORO_CE` variable is used to select the desired environment.
Set `ORO_CE=yes` to use the environment for CE (Community Edition). Used in conjunction with the desired application image.

Additionally, you can configure which optional services will be enabled and which implementation to use by setting service variables. These variables affect which include files are used (for example: compose-file-storage-${ORO_FILE_STORAGE:-mongo}.yaml, compose-${ORO_MQ_SERVICE:-rmq}.yaml, etc.).
Examples:

Enable services for Enterprise Edition (enabled by default)
```
ORO_FILE_STORAGE_SERVICE=mongo
ORO_MQ_SERVICE=rmq
ORO_PDF_CONVERSION_SERVICE=gotenberg
ORO_SEARCH_SERVICE=es
```

Enable and disable services for Community Edition
```
ORO_FILE_STORAGE_SERVICE=file
ORO_MQ_SERVICE=no
ORO_PDF_CONVERSION_SERVICE=no
ORO_SEARCH_SERVICE=no
```


## This configuration allows you to perform the following actions:

1. Install application
1. Create init image
1. Init application with init image
1. Run application
1. Run functional test
1. Run behat test
1. Get the total test execution time from the statistics database

## Requirements
You must have images with the application. See docker-build/docker/README.md for more details.

If you already have an init image, use it to restore data. If not, install the application. Init images allows quickly restore database, ES indexes, mongo data.
You can use images built on CI with a PR or other branches.

## Configuration
All configuration of scripts and applications is described using variables specified in `.env`. Additionally, the application has `.env-build` , which keeps specific settings for every application. You can also set some variables through the environment variables.

The file contains several sections of variables:

1. Common variables used in the CI to specify the names of images, versions, the application name, users, folders, timeouts, etc.
2. Variables used to configure the application.
3. Variables used to configure a specific service: database, Elasticsearch, RMQ, Redis, mail, etc.

### SSL certificate
For SSL, a special web service `waf-behat` or `waf` is used. For more details, [see](https://gitlab.oro.cloud/orocloud-devops/oro-cloud-docker/-/blob/master/jenkins/nginx-waf/oel8/README.md)
If you do not have a certificate, a self-signed one will be generated for testing.
You can use a CA ROOT certificate sign a self-signed certificate. Uncomment variable `CAROOT` in the `.env` file and point it to the folder where CA ROOT certificate and key are located. In this case CAROOT certificates will be located on the host and can be imported into the `nss` database and used in Chrome.
For more details, see https://web.dev/articles/how-to-use-local-https.

## Actions

> **NOTE:** Before running, edit `.env` and set the ORO_IMAGE and ORO_IMAGE_TAG variables to what image and tag to use. The name of image can get from `.env-build` in application source.

> **NOTE:** If there is a completed build on jenkins, you can specify the appropriate tag in ORO_IMAGE_TAG variables in the `.env` file and use the images built on jenkins. In this case, you can skip the installation and backup and immediately start with the restore.

### Install application
Install application in prod mode:
```
docker compose up install
```
Install application for test mode:
```
docker compose up install-test
```

### Make init image
To save application data, you can prepare an init image that contains a database dump and file storage data. This image can then be easily used for initialization or recovery.
```
   CACHEBUST=$(uuidgen) DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' docker-compose-db-1) FILE_STORAGE_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' docker-compose-file-storage-1) docker compose build backup
```

### Init application
```
docker compose up restore
```
> **NOTE:** If there is a completed build on jenkins, you can specify the appropriate tag in ORO_IMAGE_TAG variables in the `.env` file and use the images built on jenkins. In this case, you can skip the installation and backup and immediately start with the restore.

If localized images exist, you can specify the language in the ORO_LANGUAGE_SUFFIX variable to append to the init name of the restore image.
Example:
```
ORO_LANGUAGE_SUFFIX='-de' docker compose up restore
```
If you plan to run functional tests in the future, then you need to do restore-test
```
docker compose up restore-test
```

### Run application only web interface
```
docker compose up -d waf
```

### Run application with consumer and websocket services
```
docker compose up application
```

### Update application
Edit ORO_IMAGE_TAG variable in `.env`. Set new tag. Then run:
> **NOTE:** The app will be unavailable during the update. For docker compose, rollback is not supported. If there is important data, you need to make a new init image with the data included. In case the update fails, you can use it for recovery.

```
docker compose stop web php-fpm-app consumer ws cron
docker compose up -V update
docker compose up application
```

### Use local folder for development
When dealing with errors, it is important to be able to quickly edit the code and test it. Editing code in a Docker instance is inconvenient because the instances are recreated every time they are launched. To address this, a special mode (ORO_DOCKER_FOLDER_MODE=dev) is available. When activated, the code is copied to folders on the host and used from there. The file owner is set to the current user, giving developers the ability to conveniently edit the code and run tests immediately.

To enable this mode:
 - Edit the `.env` file and set variables:
```
ORO_DOCKER_FOLDER_MODE=dev
ORO_USER=1000
ORO_DOCKER_FOLDER_PATH=/home/user/tmp
```
Where 1000 is the user ID output from the`id -u` command.

 - Create two folders, `$ORO_DOCKER_FOLDER_PATH/oro_app` and `$ORO_DOCKER_FOLDER_PATH/oro_test`, into which the application will be copied. Two folders are necessary because there are two types of images used to run behat: one requires the `oro_app` folder for the application runtime image, and the other requires the `oro_test` folder for the application test images. For more details on the types of images, please refer to the `docker-build/docker/README.md` file.

> **NOTE:** In order for Docker to automatically copy the code into the folder at startup, the folders must be completely empty. If the folders are not empty, copying does not occur.
 
```
mkdir -p $ORO_DOCKER_FOLDER_PATH/oro_{app,test}
```

> **NOTE:** As a result of the operation of the application and tests, some files are created where the owner is the user `www-data`. To remove such files from the host, you must use `sudo` or delete as `root`.

### Enable xdebug

[Xdebug](https://xdebug.org) is an extension for PHP, and provides a range of features to improve the PHP development experience.

To enable the xdebug, edit the `.env` file and set variable (uncomment example):
```
ORO_DEBUGGER=-xdebug
```

It will include the required changes from `compose-xdebug.yaml`.

You can use the `XDEBUG_CONFIG` variable to setup the required options for xdebug extension. XDebug uses port 9003 to connect to IDE.

 - Install and configure in IDE:
   - [PHPStorm](https://www.jetbrains.com/help/phpstorm/configuring-xdebug.html#integrationWithProduct)
   - [VSCode](https://marketplace.visualstudio.com/items?itemName=xdebug.php-debug) For VSCode you can use example `.vscode/launch.json`


### Enable blackfire service

To enable the blackfire debugger:
 
 - Edit the `.env` file and set variables:
```
BLACKFIRE_SERVER_ID=XXXXXXXXX
BLACKFIRE_SERVER_TOKEN=XXXXXXXXXXX
```
 
 - Start the `blackfire` service:
```
docker compose up application
docker compose up -d blackfire
```

### Run functional test
> **NOTE:** To run functional tests, the application must be ready: - the `restore-test` or `install-test` action must be performed.

For functional and behat tests, it is possible to connect to the mysql statistics database and run tests in parallel on several nodes. This is the default mode of operation on CI. And before running tests on different nodes, you need to initialize them once. During initialization, a list of tests is created and written to the database. When running a test on a node, each node selects one test from the database, executes it, and the test time and the result is written to the database. And so it goes until all the tests are completed.

Mysql database, user, password must be pre-created and specified in `.env`. The necessary tables are created automatically.
Example:
```
ORO_DB_STAT_HOST=jenkins-dev.dev.oroinc.com
ORO_DB_STAT_NAME_FUNCTIONAL=dev_functional_stats
ORO_DB_STAT_NAME_BEHAT=dev_behat_stats
ORO_DB_STAT_USER=dev
# Password for access to statistic DB
# ORO_DB_STAT_PASSWORD
```

> **NOTE:**
`build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}'`

Init functional test:
```
docker compose up functional-init
```

Then you can run in parallel 2 threads:
```
docker compose -p thread_1 up functional
docker compose -p thread_2 up functional
```

If you don't have a Mysql database or don't want to use the parallel test execution feature, you should set the ORO_FUNCTIONAL_ARGS variable:
```
ORO_FUNCTIONAL_ARGS=' ' docker compose up functional
```

After running the tests, if you need logs, junit reports, or other artifacts, you must copy them from the instance to the host:
```
docker ps -a --format '{{.Names}}' -f "name=.*_.*-functional-.*" | xargs -r -I {} bash -c "docker cp {}:/var/www/oro//var/logs ."
```

### Run behat test
> **NOTE:** To run behat tests, the application must be ready: - the `restore` or `install` action must be performed.

As well as for functional tests, a mysql database can be used to run tests in parallel on different nodes. See the database requirements for running functional tests.

Init behat test:
```
docker compose up behat-init
```

Then you can run in parallel 2 threads:
```
docker compose -p thread_1 up behat
docker compose -p thread_2 up behat
```

If you don't have a Mysql database or don't want to use the parallel test execution feature, you should set the ORO_BEHAT_ARGS variable:
```
ORO_BEHAT_ARGS=' ' docker compose up behat
```

To run only one test:
```
ORO_BEHAT_ARGS='src/Tests/Behat/Features/demo_smoke_test.feature' docker compose up behat
```

After running the tests, if you need logs, junit reports, or other artifacts, you must copy them from the instance to the host (if ORO_DOCKER_FOLDER_MODE=dev is not set up):
```
docker ps -a --format '{{.Names}}' -f "name=.*_.*-behat-.*" | xargs -r -I {} bash -c "docker cp {}:/var/www/oro//var/logs ."
```
