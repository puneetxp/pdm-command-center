# Predictive Maintenance & OEE Command Center

Snowflake solution that joins OT sensor data (vibration, temperature, RPM, moisture, power, controller load)
with IT data (ERP assets, spare parts, maintenance work orders) to predict failures, explain root cause
and raise OEE. Built end to end with Snowflake CoCo.

## Layout

| File | What it does |
|---|---|
| `sql/01_database_schemas.sql` | Database `PDM_DB` and schemas RAW, CURATED, ML, APP |
| `sql/02_raw_tables.sql` | 15 raw tables (drops and recreates them) |
| `sql/03_synthetic_data.sql` | Re-runnable synthetic data: 50 machines, 90 days, about 2M rows |
| `sql/04_functions.sql` | `DEW_POINT`, `OEE`, `CREATE_WORK_ORDER`, `RESET_DEMO_DATA` |
| `sql/05_curated.sql` | CURATED dynamic tables (hourly sensor/power/system/fault features, `MACHINE_FEATURES_HOURLY`, `OEE_DAILY`, `REDUNDANCY_STATUS`) + live-feed simulator task |
| `sql/06_ml.sql` | `ML.FEATURES_V`, `ML.TRAINING_DATA`, `ML.FAILURE_MODEL` (7-day failure-mode classifier), `ML.PREDICTIONS`, `APP.ALERTS`, `APP.REFRESH_ALERTS`, hourly `ALERTS_TASK` |
| `sql/07_ai.sql` | Cortex Search `APP.INSPECTION_SEARCH`, semantic view `APP.PDM_SEMANTIC_VIEW`, agent tool `APP.CREATE_WORK_ORDER_TOOL`, Cortex Agent `APP.PDM_AGENT` |
| `sql/08_evaluation.sql` | Event-level accuracy vs ground truth: `ML.MODEL_EVAL_EVENTS`, `ML.MODEL_EVALUATION` |
| `sql/09_streamlit.sql` | Deploys `APP.PDM_COMMAND_CENTER` from the Git repo |
| `streamlit/streamlit_app.py` | Command center: KPIs + alerts, machine drill-down + work-order form, agent chat, model accuracy |

## Run from scratch

```bash
snow sql -f sql/01_database_schemas.sql
snow sql -f sql/02_raw_tables.sql
snow sql -f sql/04_functions.sql
snow sql -f sql/03_synthetic_data.sql      # or: CALL PDM_DB.APP.RESET_DEMO_DATA();
snow sql -f sql/05_curated.sql
snow sql -f sql/06_ml.sql                  # trains the model (a few minutes)
snow sql -f sql/07_ai.sql
snow sql -f sql/08_evaluation.sql
snow sql -f sql/09_streamlit.sql
```

Or from Snowflake, after `ALTER GIT REPOSITORY PDM_DB.APP.PDM_REPO FETCH`:
`EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/05_curated.sql;` (and so on).

Scheduled jobs are created **suspended** (they use warehouse credits):
```sql
ALTER TASK PDM_DB.APP.LIVE_FEED_TASK RESUME;   -- new sensor/power readings every 5 min
ALTER TASK PDM_DB.APP.ALERTS_TASK RESUME;      -- score + refresh alerts hourly
```

## Model results (out-of-time test, 2026-09-15 onward, vs ground truth)

| Mode | Events | Detected | Detector | Median lead time |
|---|---|---|---|---|
| MECHANICAL | 4 | 4 | model | 168 h |
| MOISTURE | 3 | 3 | model | 168 h |
| WIRING | 2 | 2 | model | 168 h |
| OVERLOAD | 2 | 2 | model | 111 h |
| POWER_SHOCK | 5 | 5 | rule (unprotected spikes / restart inrush) | 203 h |
| RANDOM | 1 | 0 | not predictable by design | - |
| **All** | **17** | **16 (94%)** | | **168 h** |

The 4 future failures (M037, M042, M014, M039) are flagged with the correct mode 7 days ahead.
False alarms: 56 of about 25k test hours (0.22%) across 9 machines.
REDUNDANCY_LOSS is handled by the `NO_BACKUP` status rule (M041, M044 today), not the model.

## Failure model

| Mode | Predictable? | Leading signals |
|---|---|---|
| MECHANICAL | Yes | Vibration, bearing temperature |
| MOISTURE | Yes (with cabinet sensor) | Humidity, dew point vs cabinet temperature, insulation resistance, leak |
| WIRING | Partly | Terminal temperature, contact and insulation resistance, thermal scan notes |
| REDUNDANCY_LOSS | Yes (status) | PSU A or RAID disk failed silently, machine runs with no backup |
| OVERLOAD | Yes | Motor: load %, winding temperature. Controller: memory and disk filling up, watchdog resets |
| POWER_QUALITY | Partly | Phase voltage imbalance, THD, winding temperature |
| POWER_SHOCK | Exposure only | Transient spikes without surge protection, restart inrush after outage |
| RANDOM | No | Use MTBF and spare-parts planning instead |

## Demo scenarios in the data
- Line 8 (no surge protection): 6 transient spikes, then 2 drive failures (M036, M038).
- Line 10: outage at 10:12 and restart inrush at 10:45 on 2026-09-23, then 3 drive failures.
- M002 / M009: repeat moisture failures; inspection notes flagged a cracked door seal that was never fixed.
- Degrading now, not yet failed: M037 (bearing), M042 (overload), M014 (moisture), M039 (wiring).
- Running on PSU B only: M041, M044. Plant P05 has 0 spare PSUs.

## Guardrails
- `CREATE_WORK_ORDER` validates machine, component ownership, priority, type and description,
  and refuses duplicate open orders on the same component.
- `RESET_DEMO_DATA` only runs `03_synthetic_data.sql` from a `PDM_DB` stage or Git repository.
- `PDM_DB.ML.SYNTH_GROUND_TRUTH` is the answer key for evaluation only. Never use it as model or agent input.
