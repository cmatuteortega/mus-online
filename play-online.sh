#!/bin/bash
# Quick script to launch Mus Online in production mode
# Connected to cloud server at 75.119.142.247

export MUS_PRODUCTION=true
export MUS_SERVER_IP=75.119.142.247
love .
