# Handoff

Status of the project as of 2026-10-07. See README.md for layout, deploy steps and model results.

## In place (Snowflake account NQ18136)
- `PDM_DB` with schemas RAW, CURATED, ML, APP; synthetic data, dynamic tables, failure model, alerts,
  Cortex Search, semantic view, Cortex Agent and the Streamlit command center (`sql/01`–`09`).
- `PDM_DB.ML.SYNTH_GROUND_TRUTH`: answer key for evaluation only, never use as model or agent input.
- Git: `GITHUB_INTEGRATION` + `PDM_DB.APP.PDM_REPO` → https://github.com/puneetxp/pdm-command-center (public,
  so no `GITHUB_SECRET`; add one to the integration and repo if it goes private).
- Push-to-deploy via GitHub Actions (OIDC service user `GITHUB_DEPLOY`, role `PDM_DEPLOYER`) with smoke test.
- Judges use the in-Snowflake app with read-only role `PDM_JUDGE`.
- Scheduled tasks `LIVE_FEED_TASK` and `ALERTS_TASK` are created suspended.

## Optional / open
- Public demo on Streamlit Community Cloud: code and `deploy/setup_public_demo.sql` are ready; needs the key
  pair, the app on share.streamlit.io and repo variable `PUBLIC_DEMO=true` (see README).
- Jira/Slack MCP for work orders and alerts (needs credentials).
- Resume the scheduled tasks when live data is wanted (or set repo variable `RESUME_TASKS=true`).
