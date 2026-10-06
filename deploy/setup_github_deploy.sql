-- One-time setup so GitHub Actions (.github/workflows/deploy.yml) can deploy to Snowflake.
-- Run once as ACCOUNTADMIN (Snowsight worksheet or CoCo), after the project exists in the account.
--
-- Auth: GitHub's OIDC token -> Snowflake workload identity. Nothing secret is stored in GitHub.
-- Only the deploy job of puneetxp/pdm-command-center running in the "snowflake" environment can log in.

USE ROLE ACCOUNTADMIN;

-- 1. Deploy role ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS PDM_DEPLOYER COMMENT = 'Owns PDM_DB objects; used by GitHub Actions deploys';
GRANT ROLE PDM_DEPLOYER TO ROLE SYSADMIN;          -- SYSADMIN / ACCOUNTADMIN keep full access

GRANT USAGE, OPERATE ON WAREHOUSE COMPUTE_WH TO ROLE PDM_DEPLOYER;
GRANT USAGE ON INTEGRATION GITHUB_INTEGRATION TO ROLE PDM_DEPLOYER;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE PDM_DEPLOYER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE PDM_DEPLOYER;

-- 2. Hand PDM_DB to the deploy role ----------------------------------------------------------
-- CREATE OR REPLACE needs ownership of the existing object. Tasks must be SUSPENDED for this.
-- Each grant is tried on its own; the result lists OK / SKIP per statement.
EXECUTE IMMEDIATE $$
DECLARE
  log VARCHAR DEFAULT '';
  c CURSOR FOR
    SELECT 'GRANT OWNERSHIP ON ' || value::STRING || ' TO ROLE PDM_DEPLOYER COPY CURRENT GRANTS' AS stmt
    FROM TABLE(FLATTEN(INPUT => ARRAY_CONSTRUCT(
      'DATABASE PDM_DB',
      'ALL SCHEMAS IN DATABASE PDM_DB',
      'ALL TABLES IN DATABASE PDM_DB',
      'ALL VIEWS IN DATABASE PDM_DB',
      'ALL DYNAMIC TABLES IN DATABASE PDM_DB',
      'ALL SEQUENCES IN DATABASE PDM_DB',
      'ALL FUNCTIONS IN DATABASE PDM_DB',
      'ALL PROCEDURES IN DATABASE PDM_DB',
      'ALL TASKS IN DATABASE PDM_DB',
      'ALL STAGES IN DATABASE PDM_DB',
      'STREAMLIT PDM_DB.APP.PDM_COMMAND_CENTER',
      'ALL GIT REPOSITORIES IN DATABASE PDM_DB',
      'ALL CORTEX SEARCH SERVICES IN DATABASE PDM_DB',
      'ALL SEMANTIC VIEWS IN DATABASE PDM_DB',
      'ALL AGENTS IN DATABASE PDM_DB',
      'SNOWFLAKE.ML.CLASSIFICATION PDM_DB.ML.FAILURE_MODEL'
    ))) ORDER BY index;
BEGIN
  FOR r IN c DO
    LET s VARCHAR := r.stmt;
    BEGIN
      EXECUTE IMMEDIATE :s;
      log := log || 'OK    ' || s || '\n';
    EXCEPTION
      WHEN OTHER THEN
        log := log || 'SKIP  ' || s || '  ->  ' || SQLERRM || '\n';
    END;
  END FOR;
  RETURN log;
END;
$$;

-- 3. Service user that GitHub Actions logs in as ----------------------------------------------
CREATE USER IF NOT EXISTS GITHUB_DEPLOY
  TYPE = SERVICE
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = 'repo:puneetxp@19248561/pdm-command-center@1407210438:environment:snowflake'  -- GitHub's ID-based subject (owner@id/repo@id)
  )
  DEFAULT_ROLE = PDM_DEPLOYER
  DEFAULT_WAREHOUSE = COMPUTE_WH
  COMMENT = 'GitHub Actions deploy for puneetxp/pdm-command-center';
GRANT ROLE PDM_DEPLOYER TO USER GITHUB_DEPLOY;

-- 4. Read-only role for judges / viewers: can open the Streamlit app, nothing else ------------
CREATE ROLE IF NOT EXISTS PDM_JUDGE COMMENT = 'View the PDM Command Center app only';
GRANT USAGE ON DATABASE PDM_DB TO ROLE PDM_JUDGE;
GRANT USAGE ON SCHEMA PDM_DB.APP TO ROLE PDM_JUDGE;
GRANT USAGE ON STREAMLIT PDM_DB.APP.PDM_COMMAND_CENTER TO ROLE PDM_JUDGE;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE PDM_JUDGE;
-- To give a judge a login, set your own strong password here and share it privately:
-- CREATE USER PDM_JUDGE PASSWORD = '<choose-a-strong-password>' DEFAULT_ROLE = PDM_JUDGE
--   DEFAULT_WAREHOUSE = COMPUTE_WH MUST_CHANGE_PASSWORD = TRUE;
-- GRANT ROLE PDM_JUDGE TO USER PDM_JUDGE;

-- 5. Values for GitHub (Settings -> Secrets and variables -> Actions -> Variables) ----------
SELECT
  LOWER(CURRENT_ORGANIZATION_NAME()) || '-' || LOWER(CURRENT_ACCOUNT_NAME())      AS SNOWFLAKE_ACCOUNT,
  'https://app.snowflake.com/' || LOWER(CURRENT_ORGANIZATION_NAME()) || '/'
    || LOWER(CURRENT_ACCOUNT_NAME()) || '/#/streamlit-apps/PDM_DB.APP.PDM_COMMAND_CENTER' AS SNOWFLAKE_APP_URL;
