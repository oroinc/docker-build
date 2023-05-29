#!/bin/bash

mongosh --username=$MONGO_INITDB_ROOT_USERNAME --password=$MONGO_INITDB_ROOT_PASSWORD --eval "db=db.getSiblingDB('public_$ORO_MONGO_DATABASE'); db.createUser({user: '$ORO_MONGO_USER', pwd: '$ORO_MONGO_PASSWORD', roles: [{role: 'dbOwner', db: 'public_$ORO_MONGO_DATABASE'}]}); db=db.getSiblingDB('private_$ORO_MONGO_DATABASE'); db.createUser({user: '$ORO_MONGO_USER', pwd: '$ORO_MONGO_PASSWORD', roles: [{role: 'dbOwner', db: 'private_$ORO_MONGO_DATABASE'}]})"
