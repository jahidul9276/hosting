#!/bin/bash
set -e

docker compose up -d --build

echo "Wolf Host started successfully!"
docker compose psps
