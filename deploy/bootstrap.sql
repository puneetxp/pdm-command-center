-- Build the whole solution in a fresh Snowflake account, straight from GitHub.
-- Run as ACCOUNTADMIN in a Snowsight worksheet (or CoCo). Takes several minutes (model training in 06).
-- Afterwards run deploy/setup_github_deploy.sql to turn on push-to-deploy from GitHub Actions.

USE ROLE ACCOUNTADMIN;
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS PDM_DB;
CREATE SCHEMA IF NOT EXISTS PDM_DB.APP;

-- Public repo: no secret needed. If the repo goes private, see GitHub issue #3.
CREATE API INTEGRATION IF NOT EXISTS GITHUB_INTEGRATION
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/puneetxp')
  ENABLED = TRUE;

CREATE GIT REPOSITORY IF NOT EXISTS PDM_DB.APP.PDM_REPO
  API_INTEGRATION = GITHUB_INTEGRATION
  ORIGIN = 'https://github.com/puneetxp/pdm-command-center.git';
ALTER GIT REPOSITORY PDM_DB.APP.PDM_REPO FETCH;

EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/01_database_schemas.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/02_raw_tables.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/04_functions.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/03_synthetic_data.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/05_curated.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/06_ml.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/07_ai.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/08_evaluation.sql;
EXECUTE IMMEDIATE FROM @PDM_DB.APP.PDM_REPO/branches/main/sql/09_streamlit.sql;

SELECT 'Deployed. Open Snowsight -> Projects -> Streamlit -> PDM Command Center' AS status;
