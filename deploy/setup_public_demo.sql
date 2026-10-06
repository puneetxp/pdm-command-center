-- One-time setup for the public demo: the same Streamlit app on Streamlit Community Cloud, open to
-- anyone without a Snowflake login. Run as ACCOUNTADMIN after deploy/setup_github_deploy.sql.
--
-- The app logs in as service user PDM_PUBLIC_APP (key pair; the private key lives only in the
-- Streamlit Cloud app's secrets). Its role can read the dashboards, create guarded work orders and
-- chat with the agent, on its own warehouse with a daily credit cap.

USE ROLE ACCOUNTADMIN;

-- 1. Own warehouse with a hard daily spend cap, so public traffic can't run up the bill
CREATE WAREHOUSE IF NOT EXISTS PDM_PUBLIC_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Public demo app (Streamlit Community Cloud)';
CREATE OR REPLACE RESOURCE MONITOR PDM_PUBLIC_MONITOR
  WITH CREDIT_QUOTA = 3 FREQUENCY = DAILY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND_IMMEDIATE;
ALTER WAREHOUSE PDM_PUBLIC_WH SET RESOURCE_MONITOR = PDM_PUBLIC_MONITOR;

-- 2. Role and service user
CREATE ROLE IF NOT EXISTS PDM_PUBLIC_DEMO COMMENT = 'Public demo app: read dashboards, guarded work orders, agent chat';
GRANT USAGE ON WAREHOUSE PDM_PUBLIC_WH TO ROLE PDM_PUBLIC_DEMO;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE PDM_PUBLIC_DEMO;

CREATE USER IF NOT EXISTS PDM_PUBLIC_APP
  TYPE = SERVICE
  RSA_PUBLIC_KEY = '<PASTE_PUBLIC_KEY_BODY>'   -- body of pdm_public_app.pub, without the BEGIN/END lines
  DEFAULT_ROLE = PDM_PUBLIC_DEMO
  DEFAULT_WAREHOUSE = PDM_PUBLIC_WH
  COMMENT = 'Public demo Streamlit app on Streamlit Community Cloud';
GRANT ROLE PDM_PUBLIC_DEMO TO USER PDM_PUBLIC_APP;

-- 3. Object grants (also re-applied by the GitHub deploy when repo variable PUBLIC_DEMO=true)
USE ROLE PDM_DEPLOYER;
ALTER GIT REPOSITORY PDM_DB.APP.PDM_REPO FETCH;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/deploy/public_demo_grants.sql;
