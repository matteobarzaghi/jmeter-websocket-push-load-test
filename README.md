# Push Terminals – WebSocket Load Test (JMeter)

JMeter test plan that load-tests a push notification system for payment/field terminals.
Each JMeter thread simulates one terminal that keeps a long-lived **WSS** connection open,
while the test sends commands to it over **HTTP** and measures whether (and how fast) the
matching push message (`WAKE`) reaches the terminal.

The plan was built for a real customer engagement; all customer-specific names, hosts,
credentials and payloads have been replaced with generic placeholders (`ExampleCorp`, `example.com`).

## Test architecture

```
setUp thread group "0 - Login"
  0.1  build Basic Auth header from TEST_USER / TEST_PASSWORD
  0.2  POST ${AUTH_PATH}              -> JWT + refresh_token stored as JMeter properties
  0.4  count terminals in device_ids.csv
  0.5  init shared counters, command plan and summary renderer
       (any failure here stops the test)

thread group "1 - Terminals"  (1 thread = 1 terminal, id from device_ids.csv)
  1.1  open WSS  ${WS_PATH}?id=<terminalId>   (Bearer JWT)
  1.1.2 send {"type":"AUTH","payload":<JWT>}, wait for AUTH_OK
  1.2  listening loop:
         read frames (timeout = time until next PING or command)
         reply PONG to server PING, send PING every PING_INTERVAL_MS
         when a command is due: POST ${COMMAND_PATH} (sendCommand)
           - command is registered as "waiting for WAKE" before sending
           - assertion: HTTP 2xx + result_code "00"
         every WAKE frame is matched FIFO to the oldest pending command -> latency
  1.2.9 drain remaining frames, 1.3 close (1000), 1.4 optional reconnect

listener "3 - Live summary"     rewrites results/connection_summary_<start>.txt once per second
tearDown "3.1 - Final summary"  writes the FINAL summary; sample fails if the result is KO
```

A single JSR223 post-processor (`1.0`) acts as the state machine for each terminal:
it classifies frames, updates the shared counters and drives the controllers through
JMeter variables (`wsAlive`, `wsContinue`, `pingDue`, `cmdDue`, `closeNeeded`, ...).

**Pass/fail criterion:** lost messages (failed POSTs + commands never delivered) must stay
below `LOSS_THRESHOLD_PCT` (default 3.5%) of the commands sent.

### Repository contents

| File | Purpose |
|---|---|
| `push-terminals-websocket.jmx` | The test plan |
| `.env.example` | Configuration template (copy to `.env`) |
| `jmeter_injector_tuning.sh` | Linux OS tuning for an injector holding thousands of WebSocket connections (fd limits, ephemeral ports, TIME_WAIT, conntrack, socket buffers) |
| `prepara_vm.sh` | Idempotent setup of an injector VM (Java, NTP, JMeter, tuning, test plan, `device_ids.csv`) |
| `check_vm.sh` | Read-only health check of an injector VM |

## Prerequisites

- **Java 17+** (Java 21 used in practice)
- **Apache JMeter 5.6.3**
- **WebSocket Samplers** plugin by Peter Doornbosch (`eu.luminis.jmeter.wssampler`),
  installable via the JMeter Plugins Manager or by dropping the jar in `lib/ext`
- For large runs: a Linux injector tuned with `jmeter_injector_tuning.sh`
  (2,000–5,000 connections per JMeter JVM is a realistic ceiling)

## Configuration

All environment-specific values are read as JMeter properties (`${__P(...)}`).

1. Copy the template and fill in real values:
   ```bash
   cp .env.example .env
   ```
   `.env` uses plain `KEY=value` lines, so JMeter can load it directly as a properties file
   with `-q .env`. It is git-ignored. Alternatively, put the same keys in JMeter's
   `bin/user.properties`.

   | Key | Meaning |
   |---|---|
   | `WS_HOST` / `WS_PORT` | Host and port for the WSS connection and `sendCommand` |
   | `TOKEN_HOST` | Host for the login |
   | `AUTH_PATH` / `WS_PATH` / `COMMAND_PATH` | Endpoint paths for login, WebSocket upgrade and `sendCommand` (defaults `/auth/token`, `/ws`, `/commands`) |
   | `TEST_USER` / `TEST_PASSWORD` | Login credentials |
   | `TENANT_ID` / `STATION_ID` / `REAL_HOST` | Values of the `X-Tenant-Id`, `X-Station-Id`, `X-Real-Host` login headers |

2. Create `device_ids.csv` next to the `.jmx`: one numeric terminal id per line, no header.
   The number of lines is the number of simulated terminals.
   ```bash
   seq 1 100 > device_ids.csv
   ```

Load-profile parameters (all optional, set in `.env` or with `-J`):

| Key | Default | Meaning |
|---|---|---|
| `DEVICE_COUNT` | CSV lines | Terminals to start (capped at the CSV size) |
| `RAMPUP_SEC` | 1 | Ramp-up of the connections |
| `CMD_PER_TERMINAL` | 5 | Commands per terminal |
| `CMD_INTERVAL_MS` | 60000 | Interval between commands of a terminal |
| `CMD_TERMINALS` | all | Only the last N started terminals send commands |
| `CMD_STEPS` / `CMD_STEP_SEC` | 1 / 0 | Start command groups in steps |
| `CMD_RAMP1_SEC`, `CMD_HOLD1_SEC`, `CMD_RAMP2_SEC`, `CMD_HOLD2_SEC`, `CMD_TERMINALS_L1`, `CMD_START_DELAY_SEC` | 0 / 60 | Two-plateau command profile (enabled when `CMD_RAMP1_SEC` > 0) |
| `PING_INTERVAL_MS` | 25000 | Application keepalive |
| `WS_MIN_DURATION_SEC` / `WS_MAX_DURATION_SEC` | 0 / computed | Per-terminal connection duration bounds |
| `WAKE_GRACE_SEC` | 30 | Time to wait for WAKE after the last command |
| `MATCH_WINDOW_SEC` | 300 | A command not matched within this window counts as expired |
| `AUTH_TIMEOUT_MS` / `AUTH_STRICT` / `AUTH_OK_MATCH` | 10000 / false / `AUTH_OK` | AUTH handshake |
| `WAKE_MATCH` | `"type":"WAKE"` | Substring that identifies a WAKE frame |
| `CHECK_RESULT_CODE` | true | Also require `result_code` = `00` in the POST response |
| `WS_RECONNECT` / `RECONNECT_DELAY_MS` | false / 5000 | Reconnect after a drop |
| `LOSS_THRESHOLD_PCT` | 3.5 | Pass/fail threshold |

## Running (non-GUI)

```bash
jmeter -n -t push-terminals-websocket.jmx -q .env \
       -l results/run.jtl -e -o results/report
```

Override any value inline, e.g. a quick smoke test:

```bash
jmeter -n -t push-terminals-websocket.jmx -q .env \
       -JDEVICE_COUNT=10 -JCMD_PER_TERMINAL=2 -JCMD_INTERVAL_MS=10000 \
       -l results/smoke.jtl
```

Use the GUI only to edit the plan or debug with a handful of threads
(the *View Results Tree* and *Summary Report* listeners are disabled on purpose).

## Reading the results

- **`results/connection_summary_<start>.txt`** – the main output. Updated live during the run,
  rewritten as `FINAL` at the end. Sections:
  - *Connections*: opened / failed / active, AUTH confirmed, unexpected disconnections, reconnects
  - *Keepalive*: PING/PONG in both directions
  - *Commands / WAKE*: POSTs OK/failed, WAKEs matched to a command, unmatched WAKEs,
    expired commands, estimated POST→WAKE latency (avg / max)
  - *Result*: `OK` if lost messages < `LOSS_THRESHOLD_PCT`; with no commands, `OK` if there were
    no failed opens, drops or AUTH failures
- **`results/run.jtl` / `results/report/`** – standard JMeter samples and HTML dashboard
  (response times and errors per sampler: login, WSS open, reads, `sendCommand`).
- **Exit status**: the `3.1 - Final summary and result` sample fails when the result is KO,
  so it shows up as an error in the `.jtl` and in the dashboard.

Note: the POST→WAKE latency is measured by the same thread that sends the POST, so it can
never be lower than the POST response time.
