#!/bin/sh
# Crucible runtime entrypoint.
# Runs DB migrations before starting the OTP release so first-boot works out of the box.
set -eu

echo "[entrypoint] running migrations"
bin/crucible eval "Crucible.Release.migrate()"

echo "[entrypoint] starting crucible"
exec bin/crucible start
