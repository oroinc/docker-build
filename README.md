# Docker-based build for OroPlatform based applications

Scripts and configurations that allow to automate application build and test processes to support continuous integration (CI) and continuous deployment (CD) based on docker images

- `scripts` folder contains scripts to build the application and run tests (code style, unit); addon services are not required  (PostgreSQL, RMQ, Redis, MongoDB, Elasticsearch). You can use it in the Continuous Integration process in remote and local environments. For more details, see scripts/README.md
- `docker` folder contains files to build all types of images for the ORO application. For more details, see  docker/README.md
- `docker-compose` folder contains the docker compose configuration to install, run, init, and tests the ORO application with required services (PostgreSQL, RMQ, Redis, MongoDB, Elasticsearch, Mail). For more details, see `docker-compose/README.md`

## Environment Requirements

The main requirement is docker. You can use any operating system with docker support, but a Linux-based OS is recommended.

In addition, we recommend using git.

### Docker

1. Install [Docker](https://docs.docker.com/engine/install/)
1. Install [Docker Compose V2 Plugin](https://docs.docker.com/compose/cli-command/#installing-compose-v2)

**Note:** Please note that you need install docker compose plugin v2, not docker compose V1 python library.

### Git

1. Install [git](https://git-scm.com/downloads)



License
-------

[MIT][1] Copyright (c) 2013 - 2023, Oro, Inc.

[1]:    LICENSE

