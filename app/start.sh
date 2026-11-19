#!/bin/sh
# 1) Initialise the database schema (retries until the DB is reachable).
#    set -e: if initialize() gives up, the container exits before Gunicorn starts.
set -eu
python -c "import app; app.initialize()"
# 2) Start the web server. exec so Gunicorn becomes PID 1 and gets signals.
exec gunicorn --bind 0.0.0.0:8080 \
  --workers "${GUNICORN_WORKERS:-2}" \
  --access-logfile - \
  app:app
