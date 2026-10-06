-- 07: AI layer: Cortex Search on inspection reports, semantic view, Cortex Agent
-- ML.SYNTH_GROUND_TRUTH is deliberately NOT exposed to the semantic view or the agent.

USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE CORTEX SEARCH SERVICE PDM_DB.APP.INSPECTION_SEARCH
  ON REPORT_TEXT
  ATTRIBUTES MACHINE_ID, INSPECTION_TYPE, PLANT_ID
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 hour'
  COMMENT = 'Technician inspection notes and thermal scan findings'
AS
SELECT r.REPORT_ID, r.MACHINE_ID, m.MACHINE_NAME, l.PLANT_ID, r.INSPECTION_DATE, r.INSPECTION_TYPE,
       r.INSPECTOR, r.REPORT_TEXT
FROM PDM_DB.RAW.INSPECTION_REPORTS r
JOIN PDM_DB.RAW.MACHINES m ON m.MACHINE_ID = r.MACHINE_ID
JOIN PDM_DB.RAW.PRODUCTION_LINES l ON l.LINE_ID = m.LINE_ID;

CREATE OR REPLACE SEMANTIC VIEW PDM_DB.APP.PDM_SEMANTIC_VIEW
  TABLES (
    plants AS PDM_DB.RAW.PLANTS PRIMARY KEY (PLANT_ID) COMMENT = 'Plants and climate zone',
    lines AS PDM_DB.RAW.PRODUCTION_LINES PRIMARY KEY (LINE_ID)
      COMMENT = 'Production lines with shared power feed, UPS and surge protection',
    machines AS PDM_DB.RAW.MACHINES PRIMARY KEY (MACHINE_ID) COMMENT = 'Machine master data (ERP)',
    oee AS PDM_DB.CURATED.OEE_DAILY PRIMARY KEY (MACHINE_ID, SHIFT_DATE) COMMENT = 'Daily OEE per machine',
    failures AS PDM_DB.RAW.FAILURES PRIMARY KEY (FAILURE_ID) COMMENT = 'Historical failures with mode, root cause and downtime',
    work_orders AS PDM_DB.RAW.WORK_ORDERS PRIMARY KEY (WORK_ORDER_ID) COMMENT = 'Maintenance work orders',
    alerts AS PDM_DB.APP.ALERTS PRIMARY KEY (ALERT_ID) COMMENT = 'Predicted failure risk and rule alerts',
    redundancy AS PDM_DB.CURATED.REDUNDANCY_STATUS PRIMARY KEY (COMPONENT_ID)
      COMMENT = 'Current status of redundant components (PSU pairs, RAID disks)',
    spares AS PDM_DB.RAW.SPARE_PARTS PRIMARY KEY (PART_NUMBER, PLANT_ID) COMMENT = 'Spare parts stock per plant'
  )
  RELATIONSHIPS (
    lines_to_plants AS lines (PLANT_ID) REFERENCES plants,
    machines_to_lines AS machines (LINE_ID) REFERENCES lines,
    oee_to_machines AS oee (MACHINE_ID) REFERENCES machines,
    failures_to_machines AS failures (MACHINE_ID) REFERENCES machines,
    work_orders_to_machines AS work_orders (MACHINE_ID) REFERENCES machines,
    alerts_to_machines AS alerts (MACHINE_ID) REFERENCES machines,
    redundancy_to_machines AS redundancy (MACHINE_ID) REFERENCES machines,
    spares_to_plants AS spares (PLANT_ID) REFERENCES plants
  )
  FACTS (
    oee.oee_value AS OEE COMMENT = 'OEE 0-1',
    oee.availability_value AS AVAILABILITY,
    oee.performance_value AS PERFORMANCE,
    oee.quality_value AS QUALITY,
    oee.planned_min AS PLANNED_MINUTES,
    oee.run_min AS RUN_MINUTES,
    oee.good_units_value AS GOOD_UNITS,
    oee.total_units_value AS TOTAL_UNITS,
    failures.downtime_min AS DOWNTIME_MINUTES,
    work_orders.cost AS COST_USD,
    work_orders.labor AS LABOR_HOURS,
    alerts.risk AS RISK_SCORE,
    spares.qty_on_hand AS QTY_ON_HAND,
    spares.reorder_point AS REORDER_POINT,
    spares.unit_cost AS UNIT_COST_USD,
    spares.lead_time AS LEAD_TIME_DAYS
  )
  DIMENSIONS (
    plants.plant_id AS PLANT_ID,
    plants.plant_name AS PLANT_NAME,
    plants.city AS CITY,
    plants.country AS COUNTRY,
    plants.climate_zone AS CLIMATE_ZONE COMMENT = 'HUMID, DRY, TEMPERATE',
    lines.line_id AS LINE_ID,
    lines.line_name AS LINE_NAME,
    lines.power_feed_id AS POWER_FEED_ID,
    lines.has_ups AS HAS_UPS,
    lines.has_surge_protection AS HAS_SURGE_PROTECTION,
    machines.machine_id AS MACHINE_ID WITH SYNONYMS = ('asset', 'equipment id'),
    machines.machine_name AS MACHINE_NAME,
    machines.machine_type AS MACHINE_TYPE COMMENT = 'PUMP, PRESS, MIXER, CONVEYOR, COMPRESSOR',
    machines.manufacturer AS MANUFACTURER,
    machines.criticality AS CRITICALITY COMMENT = 'A (most critical), B, C',
    machines.install_date AS INSTALL_DATE,
    oee.shift_date AS SHIFT_DATE,
    failures.failure_id AS FAILURE_ID,
    failures.failure_ts AS FAILURE_TS,
    failures.failure_mode AS FAILURE_MODE
      COMMENT = 'MECHANICAL, MOISTURE, POWER_QUALITY, POWER_SHOCK, WIRING, REDUNDANCY_LOSS, OVERLOAD, RANDOM',
    failures.root_cause AS ROOT_CAUSE,
    failures.component_id AS FAILED_COMPONENT_ID,
    work_orders.work_order_id AS WORK_ORDER_ID,
    work_orders.wo_type AS WO_TYPE COMMENT = 'CORRECTIVE, PREVENTIVE, PREDICTIVE, INSPECTION',
    work_orders.priority AS PRIORITY COMMENT = 'P1 urgent to P4',
    work_orders.wo_status AS STATUS COMMENT = 'OPEN, IN_PROGRESS, COMPLETED, CANCELLED',
    work_orders.created_ts AS CREATED_TS,
    work_orders.description AS DESCRIPTION,
    work_orders.created_by AS CREATED_BY COMMENT = 'HUMAN or AI_AGENT',
    alerts.alert_type AS ALERT_TYPE COMMENT = 'FAILURE_RISK, NO_BACKUP, POWER_EXPOSURE, SPARE_STOCKOUT',
    alerts.severity AS SEVERITY COMMENT = 'CRITICAL, HIGH, MEDIUM',
    alerts.predicted_mode AS PREDICTED_MODE,
    alerts.alert_status AS STATUS COMMENT = 'OPEN alerts are current; CLOSED are history',
    alerts.message AS MESSAGE,
    alerts.alert_created_ts AS CREATED_TS,
    redundancy.component_id AS COMPONENT_ID,
    redundancy.component_type AS COMPONENT_TYPE,
    redundancy.redundancy_group AS REDUNDANCY_GROUP,
    redundancy.component_status AS STATUS COMMENT = 'HEALTHY, DEGRADED, REBUILDING, FAILED',
    redundancy.group_state AS GROUP_STATE COMMENT = 'OK, DEGRADED, NO_BACKUP (one healthy left), DOWN',
    spares.part_number AS PART_NUMBER,
    spares.part_name AS PART_NAME,
    spares.spare_component_type AS COMPONENT_TYPE
  )
  METRICS (
    oee.avg_oee AS AVG(oee.oee_value) COMMENT = 'Average daily OEE (0-1)',
    oee.avg_availability AS AVG(oee.availability_value),
    oee.avg_performance AS AVG(oee.performance_value),
    oee.avg_quality AS AVG(oee.quality_value),
    oee.total_good_units AS SUM(oee.good_units_value),
    failures.failure_count AS COUNT(failures.failure_id),
    failures.total_downtime_minutes AS SUM(failures.downtime_min),
    failures.avg_downtime_minutes AS AVG(failures.downtime_min),
    work_orders.work_order_count AS COUNT(work_orders.work_order_id),
    work_orders.total_maintenance_cost AS SUM(work_orders.cost),
    alerts.alert_count AS COUNT(alerts.alert_type),
    alerts.max_risk AS MAX(alerts.risk),
    spares.total_qty_on_hand AS SUM(spares.qty_on_hand),
    spares.stock_value_usd AS SUM(spares.qty_on_hand * spares.unit_cost)
  )
  COMMENT = 'Predictive maintenance & OEE: assets, OEE, failures, work orders, alerts, redundancy, spares';

-- Agent-facing wrapper: parameter names match the tool schema, empty component -> NULL, always CREATED_BY = AI_AGENT
CREATE OR REPLACE PROCEDURE PDM_DB.APP.CREATE_WORK_ORDER_TOOL(
    MACHINE_ID VARCHAR, COMPONENT_ID VARCHAR, PRIORITY VARCHAR, DESCRIPTION VARCHAR, WO_TYPE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Agent tool: create a work order via CREATE_WORK_ORDER guardrails'
EXECUTE AS OWNER
AS
$$
DECLARE
  res VARCHAR;
  comp VARCHAR;
  wtype VARCHAR;
  mach VARCHAR;
BEGIN
  mach := UPPER(TRIM(MACHINE_ID));
  comp := NULLIF(TRIM(COMPONENT_ID), '');
  wtype := COALESCE(NULLIF(TRIM(WO_TYPE), ''), 'PREDICTIVE');
  CALL PDM_DB.APP.CREATE_WORK_ORDER(:mach, :comp, :PRIORITY, :DESCRIPTION, :wtype, 'AI_AGENT') INTO :res;
  RETURN res;
END;
$$;

CREATE OR REPLACE AGENT PDM_DB.APP.PDM_AGENT
  COMMENT = 'Predictive maintenance command center assistant'
  FROM SPECIFICATION $$
models:
  orchestration: auto
instructions:
  orchestration: >
    You are a reliability engineer assistant for a manufacturing fleet.
    Use PDM_Analyst for numbers: OEE, failures, downtime, work orders, open alerts, redundancy status, spare stock.
    Use Inspection_Search for technician notes and thermal scans (seals, corrosion, loose terminals, hot spots).
    For root cause, combine both: check open alerts and failure history for the machine, then search its inspection notes.
    Only call Create_Work_Order when the user explicitly asks to create or raise a work order.
    Before creating one, confirm the machine, component (if known), priority and a clear description.
    Priority guide: P1 = critical machine with CRITICAL alert or no redundancy, P2 = HIGH, P3 = MEDIUM, P4 = routine.
    If the procedure returns ERROR or DUPLICATE, report it and do not retry with different values.
  response: >
    Be concise. Lead with the answer, then the evidence (machine IDs, numbers, dates, report IDs).
    Express OEE as a percentage. Say clearly when data is missing instead of guessing.
  sample_questions:
    - question: "Which machines are most at risk of failing this week and why?"
    - question: "What is the root cause of the repeat failures on M002?"
    - question: "Which machines are running without a backup power supply and do we have spares?"
    - question: "Show average OEE by plant for the last 30 days"
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: PDM_Analyst
      description: "Structured data: machines, lines, plants, daily OEE, failures, work orders, alerts, redundancy status, spare parts"
  - tool_spec:
      type: cortex_search
      name: Inspection_Search
      description: "Search technician inspection reports and thermal scan notes by machine"
  - tool_spec:
      type: generic
      name: Create_Work_Order
      description: "Create a maintenance work order. Returns CREATED with the ID, or an ERROR / DUPLICATE message."
      input_schema:
        type: object
        properties:
          machine_id:
            type: string
            description: "Machine ID, e.g. M037"
          component_id:
            type: string
            description: "Component ID on that machine, e.g. M041-PSU-A. Empty string if unknown."
          priority:
            type: string
            description: "P1, P2, P3 or P4"
          description:
            type: string
            description: "What to do and why (at least 10 characters)"
          wo_type:
            type: string
            description: "PREDICTIVE (default), CORRECTIVE, PREVENTIVE or INSPECTION"
        required: ["machine_id", "component_id", "priority", "description", "wo_type"]
tool_resources:
  PDM_Analyst:
    semantic_view: "PDM_DB.APP.PDM_SEMANTIC_VIEW"
    execution_environment:
      type: warehouse
      warehouse: "COMPUTE_WH"
  Inspection_Search:
    name: "PDM_DB.APP.INSPECTION_SEARCH"
    max_results: 5
    id_column: "REPORT_ID"
    title_column: "MACHINE_NAME"
  Create_Work_Order:
    type: procedure
    identifier: "PDM_DB.APP.CREATE_WORK_ORDER_TOOL"
    execution_environment:
      type: warehouse
      warehouse: "COMPUTE_WH"
$$;
