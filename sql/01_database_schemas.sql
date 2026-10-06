-- Predictive Maintenance & OEE Command Center
-- 01: database and schemas
CREATE DATABASE IF NOT EXISTS PDM_DB COMMENT = 'Predictive Maintenance and OEE Command Center';

CREATE SCHEMA IF NOT EXISTS PDM_DB.RAW     COMMENT = 'Raw OT sensor, power, ERP and maintenance data';
CREATE SCHEMA IF NOT EXISTS PDM_DB.CURATED COMMENT = 'Cleaned, joined features and OEE';
CREATE SCHEMA IF NOT EXISTS PDM_DB.ML      COMMENT = 'Models, predictions, risk scores';
CREATE SCHEMA IF NOT EXISTS PDM_DB.APP     COMMENT = 'Semantic views, agent, Streamlit, alerts';
