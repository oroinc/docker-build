# Docker build configs to create images with the application
## Requirements

1. The application must be built. Use `scripts/composer.sh` and see `scripts/README.md` for more details.
2. Files `.rsync-exclude-prod` and `.rsync-exclude-test` are located in aplication source folder and indicate which files should be included in the image.  File `.rsync-exclude-prod` is used for the runtime image and `.rsync-exclude-test` for the test image.
3. File `.env-build` is located in aplication source folder and has specific variables for this application indicating the name of the image, locale, and whether to use demo data.

## Types of application images
### Application runtime image
Application runtime image allows to run application as different services:

- Application console (CLI) - docker run --env-file=.env application_image console oro:cron
- PHP-FPM
- Web server

Image name example: `us.gcr.io/oro-product-development/orocommerce-enterprise-application`

> **NOTE:** Before create application image, you should build application. Look to `scripts/README.md`

Create image:
```
docker buildx build --load --pull --rm -t us.gcr.io/oro-product-development/orocommerce-enterprise-application:master-latest -f ../../docker/image/application/Dockerfile .
```
### Application test image
Application test image allows to run behat and functional tests and services for CI:

- Application console (CLI)
- Run behat test
- Behat init
- Get behat statistics
- Run functional test
- Functional init
- Get functional statistics

Image name example: `us.gcr.io/oro-product-development/orocommerce-enterprise-application-test`

Create image:
```
docker buildx build --load --pull --rm -t us.gcr.io/oro-product-development/orocommerce-enterprise-application-test:master-latest -f ../../docker/image/application/Dockerfile-test .
```

### Application init images
Application init images contains data of PostgreSQL and MongoDB. They allow to restore data quickly and avoid running the installation procedure. It can also be used to create a backup and restore data. To build this image, a previously built image with the application is used. Installing additional packages and entrypoint.

> **NOTE:** To create init images, you need to create application image and install the application. See `docker-compose/README.md` for details.
> **NOTE:** An init image is built. Due to the isolation of the instance in which the build is made (docker limitation) with other services specified in the composer, it is necessary to pass the IP of the `db` and `file-storage` services through external variables DB_IP and FILE_STORAGE_IP. And use host network for build instance.

We make 2 types of images. Because we need 2 datasets installed with different `--env=prod` and `--env=test` options.
#### Init image for the runtime (prod) application.
Image name example: `us.gcr.io/oro-product-development/orocommerce-enterprise-application-init`

Create image:
```
DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod_${EXECUTOR_NUMBER}-db-1) FILE_STORAGE_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod_${EXECUTOR_NUMBER}-file-storage-1) docker compose -p prod_${EXECUTOR_NUMBER} --project-directory ../../build/docker-compose build --progress plain backup
```

#### Init test image for run test.
Image name example: `us.gcr.io/oro-product-development/orocommerce-enterprise-application-init-test`

Create image:
```
DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' test_${EXECUTOR_NUMBER}-db-1) FILE_STORAGE_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' test_${EXECUTOR_NUMBER}-file-storage-1) docker compose -p test_${EXECUTOR_NUMBER} --project-directory ../../build/docker-compose build --progress plain backup-test
```

#### Init image for community application.
If the `compose-orocommerce-application.yaml` configuration is used, the files are stored in the file system, not in the file-storage service (mongodb). And before building, they need to be copied from the installation instance to the host. Set FILE_STORAGE_IP variable not required.

Copy files from public and private storages from instance to host:
```
docker cp compose-install-1:/var/www/oro/public/media/ ../image/application/public_storage
docker cp compose-install-1:/var/www/oro/var/data/ ../image/application/private_storage
```

Create image:
```
DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' compose-db-1) docker compose -p prod_${EXECUTOR_NUMBER} --project-directory ../../build/docker-compose -f ../../build/docker-compose/compose-orocommerce-application.yaml build --progress plain backup
```
