# Docker Compose configurations to run and test the application

Below is the configuration for docker compose and configuration files for services, in addition to `.env`, where all the variables required for the services and the application are specified.

## Types of compose configuration
1. `compose.yaml` - for the enterprise version of the application. The services used are PostgreSQL, Redis, RMQ, Elasticsearch, Mongo DB.
1. `compose-orocommerce-application.yaml` - for the community version of the application. Only PostgreSQL is used.
1. `compose_ee_services.yaml` - used together with `compose-orocommerce-application.yaml` and allow run enterprise version of the application with all services except mongo DB. Used to launch enterprise version of the application in VirtualBox on OS windows and iOS.

> **NOTE:** `compose.yaml` is used by default and should not be specified in commands. If it is necessary to use `compose-orocommerce-application.yaml`, it must be specified using the `-f` option. Example: `-f compose-orocommerce-application.yaml`

This configuration allows you to perform the following actions:

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
All configuration of scripts and applications is described using variables specified in `.env`. Additionally, the application has `.env-build` , which keeps specific settings for every application. You can also set some variables through the environment variables. In case of using `compose-orocommerce-application.yaml` configuration, `.env-orocommerce-application` is used in addition to `.env`, and has a higher priority.

The file contains several sections of variables:

1. Common variables used in the CI to specify the names of images, versions, the application name, users, folders, timeouts, etc.
2. Variables used to configure the application.
3. Variables used to configure a specific service: database, Elasticsearch, RMQ, Redis, mail, etc.

### SSL certificate
For SSL, a special web service `proxy-behat` or `proxy` is used. Its image is `oroinc/nginx-proxy`.
You can use your own key and certificate. To do this, they must be located along the paths `/etc/nginx/certs/webserver.crt` and `/etc/nginx/certs/webserver.key` respectively.
If you do not have a certificate, a self-signed one will be generated for testing.
It is possible to use a CAROOT certificate which will be used to sign a self-signed certificate. Uncomment variable CAROOT in `.env` file and point it to folder where CAROOT locate. More details can be found at https://web.dev/articles/how-to-use-local-https.

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
docker compose up -d web
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

### Run functional test
> **NOTE:** To run functional tests, the application must be ready: - the `restore-test` or `install-test` action must be performed.

For functional and behat tests, it is possible to connect to the mysql statistics database and run tests in parallel on several nodes. This is the default mode of operation on CI. And before running tests on different nodes, you need to initialize them once. During initialization, a list of tests is created and written to the database. When running a test on a node, each node selects one test from the database, executes it, and the test time and the result is written to the database. And so it goes until all the tests are completed.

Mysql database, user, password must be pre-created and specified in `.env`. The necessary tables are created automatically.
Example:
```
ORO_DB_STAT_HOST=jenkins.dev.oroinc.com
ORO_DB_STAT_NAME_FUNCTIONAL=dev_functional_stats
ORO_DB_STAT_NAME_BEHAT=dev_behat_stats
ORO_DB_STAT_USER=dev
# Password for access to statistic DB
# ORO_DB_STAT_PASSWORD
```

> **NOTE:**
build_tag = '${ORO_IMAGE_TAG}${ORO_LOCAL_RUN}'

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

After running the tests, if you need logs, junit reports, or other artifacts, you must copy them from the instance to the host:
```
docker ps -a --format '{{.Names}}' -f "name=.*_.*-behat-.*" | xargs -r -I {} bash -c "docker cp {}:/var/www/oro//var/logs ."
```


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
