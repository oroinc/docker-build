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
docker buildx build --load --pull --rm -t us.gcr.io/oro-product-development/orocommerce-enterprise-application:master-latest -f ../../docker-build/docker/Dockerfile .
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
docker buildx build --load --pull --rm --build-context test="../../docker-build/docker" -t us.gcr.io/oro-product-development/orocommerce-enterprise-application-test:master-latest -f ../../docker-build/docker/Dockerfile-test .
```

### Application init images
Application init images contains data of PostgreSQL and MongoDB. They allow to restore data quickly and avoid running the installation procedure. It can also be used to create a backup and restore data. To build this image, a previously built image with the application is used. Installing additional packages and entrypoint.

> **NOTE:** To create init images, you need to create application image and install the application. See `docker-compose/README.md` for details.
> **NOTE:** An init image is built. Due to the isolation of the instance in which the build is made (docker limitation) with other services specified in the composer, it is necessary to pass the IP of the `db` and `file-storage` services through external variables DB_IP and FILE_STORAGE_IP. And use host network for build instance.

We make 2 types of images. Because we need 2 datasets installed with different `--env=prod` and `--env=test` options.
#### The warmed cache in the init images
The init images can carry the warmed cache of the installation. The `backup` and `backup-files` targets copy the named build context `oro-cache` to `/oro_init/cache`. The build of `backup` / `backup-test` takes it from the cache folder of its own compose project, `${ORO_CACHE_TMPFS_PATH:-/dev/shm/oro-cache}/<project>` (`compose-tmpfs-cache.yaml`), which holds `<ORO_ENV>` of the install (`prod` for the runtime image, `test` for the test image), so no step outside `docker compose build` is needed. Build the backup in the same project in which `install` (or `install-test`) ran, after it. With `ORO_SERVICES_TMPFS` empty the cache is a Docker volume, not a folder of the host: the init image is then built without the cache (the stage `oro-cache` of the Dockerfile is empty) and `restore` warms the cache up as before. In the tmpfs mode, when the cache folder of the project does not exist (nothing was started in this project, or the host was rebooted), `docker compose build backup` stops with an error that asks for `--allow=fs.read=...`; start the project first (`docker compose up` runs `cache-init`, which creates the folder). The cache must be written with the same `ORO_IMAGE_TAG` as the init image is built from: `restore` copies it without a check. `restore` and `restore-test` copy `/oro_init/cache/$ORO_ENV` to `var/cache/$ORO_ENV` before the first console command, so the application does not compile the cache again. The files go through the mount of `var/cache`, so into the volume `cache`, which is a folder in memory with `ORO_SERVICES_TMPFS=tmpfs`. Nothing is copied if the image has no such folder (an older image, an environment with another `ORO_ENV`, other callers that build the image without the cache), or if the cache folder of the environment is not empty (a second restore of the project), or with `ORO_IMAGE_TAG_OLD` (the init image of another tag: its cache was built for other code). A failed copy is a warning, and the cache is warmed up as before. The cache is built by the install of the same build and travels inside the init image of that build. It is copied only when the database dump is loaded, never in the dev folder mode (`ORO_DOCKER_FOLDER_MODE=dev`, where the tree is a folder of the host), and the copy is made into a temporary folder that is renamed, so an interrupted restore leaves no partial cache.

#### Init image for the runtime (prod) application.
Image name example: `us.gcr.io/oro-product-development/orocommerce-enterprise-application-init`

Create image:
```
DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod_${EXECUTOR_NUMBER}-db-1) FILE_STORAGE_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod_${EXECUTOR_NUMBER}-file-storage-1) docker compose -p prod_${EXECUTOR_NUMBER} --project-directory ../../docker-build/docker-compose build --progress plain backup
```

#### Init test image for run test.
Image name example: `us.gcr.io/oro-product-development/orocommerce-enterprise-application-init-test`

Create image:
```
DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' test_${EXECUTOR_NUMBER}-db-1) FILE_STORAGE_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' test_${EXECUTOR_NUMBER}-file-storage-1) docker compose -p test_${EXECUTOR_NUMBER} --project-directory ../../docker-build/docker-compose build --progress plain backup-test
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
DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' compose-db-1) docker compose -p prod_${EXECUTOR_NUMBER} --project-directory ../../docker-build/docker-compose -f ../../docker-build/docker-compose/compose-orocommerce-application.yaml build --progress plain backup
```
