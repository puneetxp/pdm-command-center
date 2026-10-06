import json

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="PDM Command Center", layout="wide")
session = get_active_session()


@st.cache_data(ttl=300)
def q(sql: str, params: tuple = ()) -> pd.DataFrame:
    return session.sql(sql, params=list(params)).to_pandas()


def run(sql: str, params: tuple = ()) -> str:
    return str(session.sql(sql, params=list(params)).collect()[0][0])


st.title("Predictive Maintenance & OEE Command Center")

tab_overview, tab_machine, tab_agent, tab_model = st.tabs(
    ["Command center", "Machine", "Ask the agent", "Model accuracy"])

# ---------------------------------------------------------------- overview
with tab_overview:
    k = q("""
        SELECT
          (SELECT COUNT(*) FROM PDM_DB.APP.ALERTS WHERE STATUS = 'OPEN' AND SEVERITY = 'CRITICAL') AS CRIT,
          (SELECT COUNT(*) FROM PDM_DB.APP.ALERTS WHERE STATUS = 'OPEN') AS OPEN_ALERTS,
          (SELECT COUNT(DISTINCT MACHINE_ID) FROM PDM_DB.CURATED.REDUNDANCY_STATUS
             WHERE GROUP_STATE IN ('NO_BACKUP', 'DOWN')) AS NO_BACKUP,
          (SELECT AVG(OEE) FROM PDM_DB.CURATED.OEE_DAILY
             WHERE SHIFT_DATE > (SELECT MAX(SHIFT_DATE) FROM PDM_DB.CURATED.OEE_DAILY) - 30) AS OEE30,
          (SELECT COUNT(*) FROM PDM_DB.RAW.FAILURES
             WHERE FAILURE_TS > DATEADD('DAY', -30, (SELECT MAX(FAILURE_TS) FROM PDM_DB.RAW.FAILURES))) AS FAIL30,
          (SELECT COUNT(*) FROM PDM_DB.RAW.WORK_ORDERS WHERE STATUS IN ('OPEN', 'IN_PROGRESS')) AS OPEN_WO
    """).iloc[0]
    c = st.columns(6)
    c[0].metric("Critical alerts", int(k.CRIT))
    c[1].metric("Open alerts", int(k.OPEN_ALERTS))
    c[2].metric("Machines without backup", int(k.NO_BACKUP))
    c[3].metric("OEE (30 days)", f"{k.OEE30:.1%}")
    c[4].metric("Failures (30 days)", int(k.FAIL30))
    c[5].metric("Open work orders", int(k.OPEN_WO))

    st.subheader("Open alerts")
    alerts = q("""
        SELECT SEVERITY, ALERT_TYPE, MACHINE_ID, PREDICTED_MODE, RISK_SCORE, MESSAGE, DATA_TS
        FROM PDM_DB.APP.ALERTS WHERE STATUS = 'OPEN'
        ORDER BY DECODE(SEVERITY, 'CRITICAL', 1, 'HIGH', 2, 3), RISK_SCORE DESC NULLS LAST
    """)
    types = st.multiselect("Alert type", sorted(alerts.ALERT_TYPE.unique()),
                           default=sorted(alerts.ALERT_TYPE.unique()))
    st.dataframe(alerts[alerts.ALERT_TYPE.isin(types or [])], hide_index=True, use_container_width=True,
                 column_config={"RISK_SCORE": st.column_config.ProgressColumn("Risk", min_value=0, max_value=1)})

    left, right = st.columns(2)
    with left:
        st.subheader("Daily OEE by plant")
        oee = q("""
            SELECT o.SHIFT_DATE, p.PLANT_NAME, AVG(o.OEE) AS OEE
            FROM PDM_DB.CURATED.OEE_DAILY o JOIN PDM_DB.RAW.PLANTS p ON p.PLANT_ID = o.PLANT_ID
            GROUP BY ALL ORDER BY 1
        """)
        st.line_chart(oee, x="SHIFT_DATE", y="OEE", color="PLANT_NAME", height=320)
    with right:
        st.subheader("Downtime by failure mode (minutes)")
        dt = q("SELECT FAILURE_MODE, SUM(DOWNTIME_MINUTES) AS DOWNTIME FROM PDM_DB.RAW.FAILURES GROUP BY 1 ORDER BY 2 DESC")
        st.bar_chart(dt, x="FAILURE_MODE", y="DOWNTIME", height=320)

# ---------------------------------------------------------------- machine drill-down
with tab_machine:
    machines = q("""
        SELECT m.MACHINE_ID, m.MACHINE_ID || ' - ' || m.MACHINE_NAME AS LABEL
        FROM PDM_DB.RAW.MACHINES m
        LEFT JOIN (SELECT MACHINE_ID, MAX(RISK_SCORE) R FROM PDM_DB.APP.ALERTS WHERE STATUS = 'OPEN' GROUP BY 1) a
          ON a.MACHINE_ID = m.MACHINE_ID
        ORDER BY a.R DESC NULLS LAST, m.MACHINE_ID
    """)
    label = st.selectbox("Machine (highest risk first)", machines.LABEL)
    mid = machines.loc[machines.LABEL == label, "MACHINE_ID"].iloc[0]

    info = q("""
        SELECT m.MACHINE_TYPE, m.CRITICALITY, l.LINE_ID, l.PLANT_ID, l.HAS_SURGE_PROTECTION, l.HAS_UPS,
               p.FAILURE_RISK, p.TOP_MODE
        FROM PDM_DB.RAW.MACHINES m JOIN PDM_DB.RAW.PRODUCTION_LINES l ON l.LINE_ID = m.LINE_ID
        LEFT JOIN (SELECT * FROM PDM_DB.ML.PREDICTIONS QUALIFY ROW_NUMBER() OVER (PARTITION BY MACHINE_ID ORDER BY SCORED_AT DESC) = 1) p
          ON p.MACHINE_ID = m.MACHINE_ID
        WHERE m.MACHINE_ID = ?
    """, (mid,)).iloc[0]
    c = st.columns(5)
    c[0].metric("Type", info.MACHINE_TYPE)
    c[1].metric("Criticality", info.CRITICALITY)
    c[2].metric("Line / plant", f"{info.LINE_ID} / {info.PLANT_ID}")
    risk = info.FAILURE_RISK if pd.notna(info.FAILURE_RISK) else 0.0
    c[3].metric("7-day failure risk", f"{risk:.0%}")
    c[4].metric("Most likely mode", info.TOP_MODE if risk >= 0.5 else "-")

    signals = {
        "Vibration (mm/s)": "VIBRATION_AVG", "Bearing temp (C)": "BEARING_TEMP_AVG",
        "Winding temp (C)": "WINDING_TEMP_AVG", "Load (%)": "LOAD_PCT_AVG",
        "Cabinet humidity (%)": "HUMIDITY_AVG", "Dew margin (C)": "DEW_MARGIN_MIN_C",
        "Insulation (MOhm)": "INSULATION_MIN_MOHM", "Terminal temp (C)": "TERMINAL_TEMP_MAX",
        "Controller memory (%)": "MEMORY_MAX", "Voltage imbalance": "VOLTAGE_IMBALANCE_MAX",
    }
    picked = st.multiselect("Signals (last 21 days, hourly)", list(signals),
                            default=["Vibration (mm/s)", "Bearing temp (C)", "Cabinet humidity (%)"])
    hist = q("""
        SELECT * FROM PDM_DB.CURATED.MACHINE_FEATURES_HOURLY
        WHERE MACHINE_ID = ? AND HOUR_TS > (SELECT DATEADD('DAY', -21, MAX(HOUR_TS)) FROM PDM_DB.CURATED.MACHINE_FEATURES_HOURLY)
        ORDER BY HOUR_TS
    """, (mid,))
    cols = st.columns(2)
    for i, name in enumerate(picked):
        with cols[i % 2]:
            st.caption(name)
            st.line_chart(hist, x="HOUR_TS", y=signals[name], height=200)

    left, right = st.columns(2)
    with left:
        st.subheader("Failure history")
        st.dataframe(q("""SELECT FAILURE_TS, FAILURE_MODE, COMPONENT_ID, ROOT_CAUSE, DOWNTIME_MINUTES
                          FROM PDM_DB.RAW.FAILURES WHERE MACHINE_ID = ? ORDER BY FAILURE_TS DESC""", (mid,)),
                     hide_index=True, use_container_width=True)
        st.subheader("Work orders")
        st.dataframe(q("""SELECT WORK_ORDER_ID, WO_TYPE, PRIORITY, STATUS, CREATED_TS, DESCRIPTION, CREATED_BY
                          FROM PDM_DB.RAW.WORK_ORDERS WHERE MACHINE_ID = ? ORDER BY CREATED_TS DESC""", (mid,)),
                     hide_index=True, use_container_width=True)
    with right:
        st.subheader("Inspection notes")
        notes = q("""SELECT INSPECTION_DATE, INSPECTION_TYPE, INSPECTOR, REPORT_TEXT
                     FROM PDM_DB.RAW.INSPECTION_REPORTS WHERE MACHINE_ID = ? ORDER BY INSPECTION_DATE DESC""", (mid,))
        if notes.empty:
            st.info("No inspection reports for this machine.")
        for n in notes.itertuples():
            with st.expander(f"{n.INSPECTION_DATE} - {n.INSPECTION_TYPE} ({n.INSPECTOR})"):
                st.write(n.REPORT_TEXT)

        st.subheader("Create work order")
        comps = q("SELECT COMPONENT_ID FROM PDM_DB.RAW.COMPONENTS WHERE MACHINE_ID = ? ORDER BY 1", (mid,))
        with st.form("wo", clear_on_submit=True):
            comp = st.selectbox("Component", ["(none)"] + comps.COMPONENT_ID.tolist())
            a, b = st.columns(2)
            prio = a.selectbox("Priority", ["P1", "P2", "P3", "P4"], index=1)
            wtype = b.selectbox("Type", ["PREDICTIVE", "CORRECTIVE", "PREVENTIVE", "INSPECTION"])
            desc = st.text_area("Description", placeholder="What to do and why")
            if st.form_submit_button("Create work order", type="primary"):
                res = run("CALL PDM_DB.APP.CREATE_WORK_ORDER(?, ?, ?, ?, ?, 'HUMAN')",
                          (mid, None if comp == "(none)" else comp, prio, desc, wtype))
                (st.success if res.startswith("CREATED") else st.warning)(res)
                st.cache_data.clear()

# ---------------------------------------------------------------- agent chat
with tab_agent:
    st.caption("Cortex Agent PDM_DB.APP.PDM_AGENT: analyst over OEE / failures / alerts, inspection search, "
               "and a guarded work-order tool. It only creates work orders when you ask it to.")
    if "msgs" not in st.session_state:
        st.session_state.msgs = []
    if st.button("Clear chat"):
        st.session_state.msgs = []
    for m in st.session_state.msgs:
        with st.chat_message(m["role"]):
            st.markdown(m["text"])

    prompt = st.chat_input("e.g. Which machines are most at risk this week and why?")
    if prompt:
        st.session_state.msgs.append({"role": "user", "text": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)
        body = {"messages": [{"role": m["role"], "content": [{"type": "text", "text": m["text"]}]}
                             for m in st.session_state.msgs]}
        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                raw = run("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('PDM_DB.APP.PDM_AGENT', ?)", (json.dumps(body),))
                resp = json.loads(raw)
                parts = resp.get("content", [])
                text = "".join(p.get("text", "") for p in parts if p.get("type") == "text") or "_No answer returned._"
                used = [p["tool_use"]["name"] for p in parts if p.get("type") == "tool_use"]
            st.markdown(text)
            if used:
                st.caption("Tools used: " + ", ".join(dict.fromkeys(used)))
        st.session_state.msgs.append({"role": "assistant", "text": text})

# ---------------------------------------------------------------- model accuracy
with tab_model:
    st.caption("Out-of-time test (2026-09-15 onward). Labels come from RAW.FAILURES; "
               "ground truth (ML.SYNTH_GROUND_TRUTH) is used only for the evaluation below.")
    try:
        ev = q("SELECT * FROM PDM_DB.ML.MODEL_EVALUATION ORDER BY 1")
        st.dataframe(ev, hide_index=True, use_container_width=True)
    except Exception:
        st.info("Run sql/08_evaluation.sql to populate PDM_DB.ML.MODEL_EVALUATION.")
