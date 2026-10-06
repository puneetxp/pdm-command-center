# Handoff: continue in CoCo CLI

Context for CoCo. This project was started in CoCo in Snowsight and continues in the CLI.

## Already done (in Snowflake account, role ACCOUNTADMIN, warehouse COMPUTE_WH)
- Database `PDM_DB`, schemas RAW, CURATED, ML, APP.
- 15 RAW tables filled with synthetic data (see README.md): 1.3M sensor rows, 50 failures, 8 failure modes.
- `PDM_DB.ML.SYNTH_GROUND_TRUTH`: answer key for evaluation only, never use as model or agent input.
- Functions in `PDM_DB.APP`: `DEW_POINT`, `OEE`, `CREATE_WORK_ORDER` (with guardrails), `RESET_DEMO_DATA`.
- SQL scripts are on stage `@PDM_DB.APP.PDM_CODE/sql/`.

## Next task: connect GitHub
- Repo: https://github.com/puneetxp/pdm-command-center (empty), branch `main`
- Token: local CoCo secret `github_token` (fine-grained PAT, Contents read/write)

Steps:
1. Push this folder to the repo (git init if needed, commit, push to main over HTTPS using the token).
   Do not write the token into any file or the git remote URL.
2. Create `PDM_DB.APP.GITHUB_SECRET` (TYPE=PASSWORD, USERNAME='puneetxp', PASSWORD=token).
3. Create API integration `GITHUB_INTEGRATION` (API_PROVIDER=git_https_api,
   API_ALLOWED_PREFIXES=('https://github.com/puneetxp'), ALLOWED_AUTHENTICATION_SECRETS=(PDM_DB.APP.GITHUB_SECRET)).
4. Create git repository `PDM_DB.APP.PDM_REPO` with ORIGIN https://github.com/puneetxp/pdm-command-center.git, then FETCH.
5. Verify: `LS @PDM_DB.APP.PDM_REPO/branches/main/sql/` shows the 4 SQL files.
6. Test: `CALL PDM_DB.APP.RESET_DEMO_DATA('@PDM_DB.APP.PDM_REPO/branches/main/sql/03_synthetic_data.sql');`

## After that (project plan)
- Step 3: CURATED dynamic tables (hourly features, daily OEE, redundancy status) + stream/task for live data
- Step 4: failure prediction model, ALERTS table
- Step 5: semantic view + Cortex Agent (root cause, can call CREATE_WORK_ORDER), Cortex Search on inspection reports
- Step 6: Streamlit command center
- Step 7: testing, accuracy vs ground truth, scheduled automation, Jira/Slack MCP
