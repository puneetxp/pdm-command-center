-- 09: deploy the Streamlit command center from the Git repository (warehouse runtime)

ALTER GIT REPOSITORY PDM_DB.APP.PDM_REPO FETCH;

CREATE OR REPLACE STREAMLIT PDM_DB.APP.PDM_COMMAND_CENTER
  FROM '@PDM_DB.APP.PDM_REPO/branches/main/streamlit/'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = COMPUTE_WH
  TITLE = 'PDM Command Center'
  COMMENT = 'Predictive maintenance & OEE command center with Cortex Agent chat';

ALTER STREAMLIT PDM_DB.APP.PDM_COMMAND_CENTER ADD LIVE VERSION FROM LAST;
