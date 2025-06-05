#!/bin/bash

# Benchmark configuration
PORT=8080
DURATION=5
CONNECTIONS=64
THREADS=4

SRC_MT="${PWD}/webserver-mt.c"
PY_SERVER="${PWD}/baseline.py"
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR" || exit 1

# Check CPU core count
NUM_CORES=$(getconf _NPROCESSORS_ONLN)
if [[ "$NUM_CORES" -lt 2 ]]; then
  echo "FAIL: At least 2 CPU cores required (found: $NUM_CORES)"
  exit 1
fi

# Cleanup on exit
cleanup() {
  pkill -f "webserver_mt" 2>/dev/null
  pkill -f "baseline.py" 2>/dev/null
  cd /
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Prepare working files
cp "$SRC_MT" ./webserver-mt.c
cp "$PY_SERVER" ./baseline.py
mkdir -p www
echo "[INFO] Generating large index.html..."
python3 -c "with open('www/index.html', 'w') as f: f.write('<html><body><h1>Benchmark</h1>' + '<p>line</p>' * 10000 + '</body></html>')"

# Build C multi-threaded server
echo "[INFO] Compiling webserver-mt.c..."
if ! gcc webserver-mt.c -o webserver_mt -lpthread -O3 -Wno-unused-result; then
  echo "FAIL: Failed to build webserver-mt.c"
  exit 1
fi

# Functional test
run_functional_test() {
  echo "[TEST] Functional test for $1"
  "$1" > /dev/null 2>&1 &
  pid=$!
  sleep 1
  http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/index.html)
  if ps -p "$pid" > /dev/null; then kill "$pid"; fi
  sleep 1

  if [[ "$http_code" == "200" ]]; then
    echo "PASS: $1 served index.html successfully."
  else
    echo "FAIL: $1 failed to serve index.html (HTTP $http_code)"
    exit 1
  fi
  echo ""
}

run_functional_test "./webserver_mt"

# Benchmark Python baseline
echo "[INFO] Benchmarking Python baseline server..."
python3 baseline.py > /dev/null 2>&1 &
pid_py=$!
sleep 1
wrk -t"$THREADS" -c"$CONNECTIONS" -d"${DURATION}s" http://localhost:$PORT/index.html > py_wrk.log
if ps -p "$pid_py" > /dev/null; then kill "$pid_py"; fi
sleep 1

# Benchmark C multi-threaded server
echo "[INFO] Benchmarking multi-threaded C server..."
./webserver_mt > /dev/null 2>&1 &
pid_mt=$!
sleep 1
wrk -t"$THREADS" -c"$CONNECTIONS" -d"${DURATION}s" http://localhost:$PORT/index.html > mt_wrk.log
if ps -p "$pid_mt" > /dev/null; then kill "$pid_mt"; fi
sleep 1

# Parse results
req_py=$(grep "Requests/sec" py_wrk.log | awk '{print $2}')
req_mt=$(grep "Requests/sec" mt_wrk.log | awk '{print $2}')
threshold=$(echo "$req_py * 1.0" | bc)
is_faster=$(echo "$req_mt >= $threshold" | bc)

echo ""
echo "=== PERFORMANCE RESULTS ==="
printf "Python (single-threaded):  %s req/sec\n" "$req_py"
printf "C (multi-threaded):        %s req/sec\n" "$req_mt"

if [[ "$is_faster" -eq 1 ]]; then
  echo "PASS: Multi-threaded C server outperforms the single-threaded Python baseline."
else
  echo "FAIL: Multi-threaded C server did not outperform the single-threaded Python baseline."
  exit 1
fi

echo ""
echo "SUCCESS: All tests PASS!"
