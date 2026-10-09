#!/bin/bash
# Mounted as /usr/local/bin/mongod, ahead of /usr/bin/mongod in PATH, so the image entrypoint calls it instead of mongod.
# The entrypoint stops its temporary initdb mongod with "mongod --shutdown", which can return before that process has
# exited and released port 27017. The main mongod then fails with "Address already in use", the container restarts,
# and compose aborts on the unhealthy dependency. Start the main mongod only after the initdb one is gone.

case " $* " in
  *" --fork "* | *" --shutdown "*) exec /usr/bin/mongod "$@" ;;
esac

for i in $(seq 300); do
  # Match the real binary by its command line: this script and its subshells are also named mongod
  pids=$(pgrep -f '^/usr/bin/mongod( |$)')
  [ -z "$pids" ] && exec /usr/bin/mongod "$@"
  [ "$i" -eq 1 ] && echo >&2 "mongod-wait: waiting for the initdb mongod (PID $pids) to exit"
  sleep 0.1
done

echo >&2 "mongod-wait: the initdb mongod is still running after 30s, starting anyway"
exec /usr/bin/mongod "$@"
