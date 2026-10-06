-- Post-deploy smoke test, run by .github/workflows/deploy.yml. Every row must have OK = TRUE.
SELECT 'curated_features_rows' AS check_name, COUNT(*) AS val, COUNT(*) > 0 AS ok FROM PDM_DB.CURATED.MACHINE_FEATURES_HOURLY
UNION ALL SELECT 'curated_oee_daily_rows',       COUNT(*), COUNT(*) > 0 FROM PDM_DB.CURATED.OEE_DAILY
UNION ALL SELECT 'curated_redundancy_rows',      COUNT(*), COUNT(*) > 0 FROM PDM_DB.CURATED.REDUNDANCY_STATUS
UNION ALL SELECT 'ml_predictions_rows',          COUNT(*), COUNT(*) > 0 FROM PDM_DB.ML.PREDICTIONS
UNION ALL SELECT 'app_alerts_rows',              COUNT(*), COUNT(*) > 0 FROM PDM_DB.APP.ALERTS
UNION ALL SELECT 'ml_evaluation_rows',           COUNT(*), COUNT(*) > 0 FROM PDM_DB.ML.MODEL_EVALUATION;
