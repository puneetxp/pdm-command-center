-- 04: reusable functions and procedures

-- Dew point (Magnus formula). Condensation risk when a surface is colder than this.
CREATE OR REPLACE FUNCTION PDM_DB.APP.DEW_POINT(TEMP_C FLOAT, HUMIDITY_PCT FLOAT)
RETURNS FLOAT
COMMENT = 'Dew point in C from air temperature (C) and relative humidity (%). NULL for invalid humidity.'
AS
$$
  CASE WHEN HUMIDITY_PCT IS NULL OR TEMP_C IS NULL OR HUMIDITY_PCT <= 0 OR HUMIDITY_PCT > 100 THEN NULL
  ELSE ROUND(243.04 * (LN(HUMIDITY_PCT/100) + 17.625*TEMP_C/(243.04+TEMP_C))
           / (17.625 - (LN(HUMIDITY_PCT/100) + 17.625*TEMP_C/(243.04+TEMP_C))), 2) END
$$;

-- OEE = Availability x Performance x Quality (0..1). Performance capped at 1.
CREATE OR REPLACE FUNCTION PDM_DB.APP.OEE(PLANNED_MIN FLOAT, RUN_MIN FLOAT, TOTAL_UNITS FLOAT, GOOD_UNITS FLOAT, IDEAL_CYCLE_SEC FLOAT)
RETURNS FLOAT
COMMENT = 'Overall Equipment Effectiveness (0-1) = availability * performance * quality. NULL if inputs invalid.'
AS
$$
  CASE WHEN PLANNED_MIN IS NULL OR PLANNED_MIN <= 0 OR IDEAL_CYCLE_SEC IS NULL OR IDEAL_CYCLE_SEC <= 0 THEN NULL
       WHEN RUN_MIN <= 0 OR TOTAL_UNITS <= 0 THEN 0
  ELSE ROUND( (RUN_MIN/PLANNED_MIN)
            * LEAST(1, (TOTAL_UNITS*IDEAL_CYCLE_SEC)/(RUN_MIN*60))
            * (GOOD_UNITS/TOTAL_UNITS), 4) END
$$;

CREATE SEQUENCE IF NOT EXISTS PDM_DB.APP.WORK_ORDER_SEQ START = 10001 INCREMENT = 1;

-- Creates a work order. Used by the agent and the Streamlit app as a real action.
-- Guardrails: validates machine/component/priority, blocks duplicate open orders on the same component.
CREATE OR REPLACE PROCEDURE PDM_DB.APP.CREATE_WORK_ORDER(
    MACHINE_ID VARCHAR, COMPONENT_ID VARCHAR, PRIORITY VARCHAR, DESCRIPTION VARCHAR,
    WO_TYPE VARCHAR DEFAULT 'PREDICTIVE', CREATED_BY VARCHAR DEFAULT 'AI_AGENT')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Create a maintenance work order. PRIORITY: P1 (urgent) to P4. Returns the work order ID or a validation error.'
EXECUTE AS OWNER
AS
$$
DECLARE
  n INTEGER;
  existing VARCHAR;
  part VARCHAR;
  wo_id VARCHAR;
  prio VARCHAR;
  wtype VARCHAR;
BEGIN
  prio := UPPER(TRIM(PRIORITY));
  wtype := UPPER(TRIM(COALESCE(WO_TYPE, 'PREDICTIVE')));
  SELECT COUNT(*) INTO :n FROM PDM_DB.RAW.MACHINES WHERE MACHINE_ID = :MACHINE_ID;
  IF (n = 0) THEN RETURN 'ERROR: unknown machine ' || COALESCE(MACHINE_ID, 'NULL'); END IF;

  IF (prio NOT IN ('P1','P2','P3','P4')) THEN RETURN 'ERROR: priority must be P1, P2, P3 or P4'; END IF;
  IF (wtype NOT IN ('CORRECTIVE','PREVENTIVE','PREDICTIVE','INSPECTION')) THEN
    RETURN 'ERROR: WO_TYPE must be CORRECTIVE, PREVENTIVE, PREDICTIVE or INSPECTION'; END IF;
  IF (DESCRIPTION IS NULL OR LENGTH(TRIM(DESCRIPTION)) < 10) THEN
    RETURN 'ERROR: description must be at least 10 characters'; END IF;

  IF (COMPONENT_ID IS NOT NULL) THEN
    SELECT COUNT(*), MAX(PART_NUMBER) INTO :n, :part FROM PDM_DB.RAW.COMPONENTS
      WHERE COMPONENT_ID = :COMPONENT_ID AND MACHINE_ID = :MACHINE_ID;
    IF (n = 0) THEN RETURN 'ERROR: component ' || COMPONENT_ID || ' does not belong to machine ' || MACHINE_ID; END IF;

    SELECT MAX(WORK_ORDER_ID) INTO :existing FROM PDM_DB.RAW.WORK_ORDERS
      WHERE COMPONENT_ID = :COMPONENT_ID AND STATUS IN ('OPEN','IN_PROGRESS') AND WO_TYPE <> 'PREVENTIVE';
    IF (existing IS NOT NULL) THEN
      RETURN 'DUPLICATE: open work order ' || existing || ' already exists for ' || COMPONENT_ID || ' - not creating another';
    END IF;
  END IF;

  SELECT 'WO' || PDM_DB.APP.WORK_ORDER_SEQ.NEXTVAL INTO :wo_id;
  INSERT INTO PDM_DB.RAW.WORK_ORDERS
    (WORK_ORDER_ID, MACHINE_ID, COMPONENT_ID, FAILURE_ID, WO_TYPE, PRIORITY, STATUS, CREATED_TS,
     COMPLETED_TS, DESCRIPTION, TECHNICIAN, PART_NUMBER, LABOR_HOURS, COST_USD, CREATED_BY)
  VALUES (:wo_id, :MACHINE_ID, :COMPONENT_ID, NULL, :wtype, :prio, 'OPEN', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
     NULL, TRIM(:DESCRIPTION), NULL, :part, NULL, NULL, UPPER(COALESCE(:CREATED_BY,'AI_AGENT')));
  RETURN 'CREATED: ' || wo_id || ' (' || prio || ', ' || wtype || ') for ' || MACHINE_ID || COALESCE(' / ' || COMPONENT_ID, '');
END;
$$;

-- Regenerates all synthetic data by running 03_synthetic_data.sql from a stage or Git repository.
-- Guardrail: only scripts stored under PDM_DB are allowed.
CREATE OR REPLACE PROCEDURE PDM_DB.APP.RESET_DEMO_DATA(
    SCRIPT_PATH VARCHAR DEFAULT '@PDM_DB.APP.PDM_CODE/sql/03_synthetic_data.sql')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Truncate and regenerate all synthetic RAW data and ground truth. Takes about 1-2 minutes.'
EXECUTE AS CALLER
AS
$$
DECLARE
  sensors INTEGER;
  failures INTEGER;
BEGIN
  IF (NOT STARTSWITH(UPPER(SCRIPT_PATH), '@PDM_DB.') OR NOT ENDSWITH(LOWER(SCRIPT_PATH), '03_synthetic_data.sql')) THEN
    RETURN 'ERROR: script path must be the 03_synthetic_data.sql file under a PDM_DB stage or Git repository';
  END IF;
  EXECUTE IMMEDIATE 'EXECUTE IMMEDIATE FROM ' || SCRIPT_PATH;
  SELECT COUNT(*) INTO :sensors FROM PDM_DB.RAW.SENSOR_READINGS;
  SELECT COUNT(*) INTO :failures FROM PDM_DB.RAW.FAILURES;
  RETURN 'RESET OK: ' || sensors || ' sensor readings, ' || failures || ' failures';
END;
$$;
