#!/bin/bash
set -uo pipefail
export PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

LOCK_FILE="/opt/little-check/job.lock"
SCRIPT_PATH="/opt/little-check/generate_feed.py"
LOG_FILE="/opt/little-check/hourly.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting hourly feed update..." >> "$LOG_FILE"
# The flock parent owns the lock; children cannot inherit its descriptor.
flock -n -E 75 -o "$LOCK_FILE" /usr/bin/timeout --signal=TERM --kill-after=10s 10m /opt/little-check/.venv/bin/python "$SCRIPT_PATH" >> "$LOG_FILE" 2>&1
result=$?
if [ "$result" -eq 75 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another feed update job is currently running, skipping." >> "$LOG_FILE"
    exit 0
fi
if [ "$result" -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Feed update failed (exit $result); previous feed retained." >> "$LOG_FILE"
    exit "$result"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Hourly feed update finished." >> "$LOG_FILE"
/usr/bin/timeout --signal=TERM --kill-after=10s 75s /opt/little-check/.venv/bin/python -B /opt/little-check/trigger_github_workflow.py >> "$LOG_FILE" 2>&1
trigger_result=$?
if [ "$trigger_result" -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Feed published, but GitHub trigger failed (exit $trigger_result)." >> "$LOG_FILE"
    exit "$trigger_result"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] GitHub workflow dispatch accepted." >> "$LOG_FILE"
