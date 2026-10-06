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

## Run from scratch

```bash
snow sql -f sql/01_database_schemas.sql
snow sql -f sql/02_raw_tables.sql
snow sql -f sql/04_functions.sql
snow sql -f sql/03_synthetic_data.sql      # or: CALL PDM_DB.APP.RESET_DEMO_DATA();
```

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
