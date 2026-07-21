#!/bin/bash
# Launch Mus Online against the cloud server (75.119.142.247).
# NOTE: production is now the DEFAULT — a plain `love .` connects to the VPS too.
# These env vars are kept so you can point at a different IP/port if needed.
# For localhost dev instead, run: MUS_DEV=true love .

export MUS_PRODUCTION=true
export MUS_SERVER_IP=75.119.142.247
love .
