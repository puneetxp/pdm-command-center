-- 03: synthetic data generation (re-runnable: truncates and regenerates everything)
-- Period: 2026-07-08 to 2026-10-05 (90 days). 5 plants, 10 lines, 50 machines.
-- Failure modes: MECHANICAL, MOISTURE, WIRING, REDUNDANCY_LOSS, OVERLOAD, POWER_QUALITY, POWER_SHOCK, RANDOM.
-- PDM_DB.ML.SYNTH_GROUND_TRUTH is the hidden answer key: use ONLY for evaluation, never as model input.

TRUNCATE TABLE PDM_DB.RAW.PLANTS;
TRUNCATE TABLE PDM_DB.RAW.PRODUCTION_LINES;
TRUNCATE TABLE PDM_DB.RAW.MACHINES;
TRUNCATE TABLE PDM_DB.RAW.COMPONENTS;
TRUNCATE TABLE PDM_DB.RAW.SPARE_PARTS;
TRUNCATE TABLE PDM_DB.RAW.SENSOR_READINGS;
TRUNCATE TABLE PDM_DB.RAW.POWER_READINGS;
TRUNCATE TABLE PDM_DB.RAW.POWER_EVENTS;
TRUNCATE TABLE PDM_DB.RAW.COMPONENT_HEALTH;
TRUNCATE TABLE PDM_DB.RAW.SYSTEM_METRICS;
TRUNCATE TABLE PDM_DB.RAW.FAULT_LOGS;
TRUNCATE TABLE PDM_DB.RAW.FAILURES;
TRUNCATE TABLE PDM_DB.RAW.WORK_ORDERS;
TRUNCATE TABLE PDM_DB.RAW.INSPECTION_REPORTS;
TRUNCATE TABLE PDM_DB.RAW.PRODUCTION_OUTPUT;

-- ---------- Master data ----------
INSERT INTO PDM_DB.RAW.PLANTS VALUES
 ('P01','Chennai Works','Chennai','India','HUMID','Asia/Kolkata'),
 ('P02','Houston Plant','Houston','USA','HUMID','America/Chicago'),
 ('P03','Stuttgart Werk','Stuttgart','Germany','TEMPERATE','Europe/Berlin'),
 ('P04','Monterrey Planta','Monterrey','Mexico','DRY','America/Monterrey'),
 ('P05','Phoenix Plant','Phoenix','USA','DRY','America/Phoenix');

-- Lines 8 and 10 have no UPS / surge protection (power shock scenarios)
INSERT INTO PDM_DB.RAW.PRODUCTION_LINES
SELECT 'L'||LPAD(l,2,'0'), 'P'||LPAD(CEIL(l/2),2,'0'), 'Line '||l, 'PF-'||LPAD(l,2,'0'),
       l NOT IN (8,10), l NOT IN (8,10)
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) l FROM TABLE(GENERATOR(ROWCOUNT=>10)));

INSERT INTO PDM_DB.RAW.MACHINES
SELECT 'M'||LPAD(k,3,'0'), 'L'||LPAD(CEIL(k/5),2,'0'),
  INITCAP(t)||'-'||LPAD(k,3,'0'), t,
  DECODE(t,'PUMP','Grundfos','PRESS','Schuler','MIXER','Ekato','CONVEYOR','Interroll','Atlas Copco'),
  DECODE(t,'PUMP','CR-64','PRESS','MSD-400','MIXER','UNIMIX-2','CONVEYOR','RM-8400','GA-37'),
  DATEADD(day, MOD(k*97,3000), '2015-01-01'::DATE),
  DECODE(t,'PUMP',2950,'PRESS',1480,'MIXER',980,'CONVEYOR',1450,2960),
  DECODE(t,'PUMP',28,'PRESS',55,'MIXER',40,'CONVEYOR',15,62),
  DECODE(t,'PUMP',2.0,'PRESS',12,'MIXER',30,'CONVEYOR',1.5,3.0),
  DECODE(t,'PRESS','A','COMPRESSOR','A','CONVEYOR','C','B')
FROM (SELECT k, GET(ARRAY_CONSTRUCT('PUMP','PRESS','MIXER','CONVEYOR','COMPRESSOR'), MOD(k-1,5))::VARCHAR t
      FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) k FROM TABLE(GENERATOR(ROWCOUNT=>50))));

INSERT INTO PDM_DB.RAW.COMPONENTS
SELECT m.MACHINE_ID||'-'||c.sfx, m.MACHINE_ID, c.ctype, c.grp, c.part, m.INSTALL_DATE, c.mtbf
FROM PDM_DB.RAW.MACHINES m CROSS JOIN (VALUES
 ('BEARING','BRG',NULL,'BRG-6310-2RS',30000),('MOTOR','MTR',NULL,'MTR-IE3-30KW',80000),
 ('DRIVE','DRV',NULL,'DRV-VFD-30KW',60000),('PLC','PLC',NULL,'PLC-S7-1500',100000),
 ('PSU','PSU-A','PSU_PAIR','PSU-24VDC-20A',50000),('PSU','PSU-B','PSU_PAIR','PSU-24VDC-20A',50000),
 ('RAID_DISK','DSK-1','RAID1','SSD-IND-480G',40000),('RAID_DISK','DSK-2','RAID1','SSD-IND-480G',40000),
 ('CONTROL_BOARD','CB',NULL,'CB-IO-MAIN-01',70000),('NETWORK_SWITCH','NSW',NULL,'NSW-IND-8P',90000),
 ('CABLE','CBL',NULL,'CBL-PWR-4X16',150000)) c(ctype,sfx,grp,part,mtbf);

-- P05 has zero spare PSUs (demo: degraded machines with no spare)
INSERT INTO PDM_DB.RAW.SPARE_PARTS
SELECT p.part, p.pname, p.ctype, p.cost, p.lead,
  CASE WHEN p.part='PSU-24VDC-20A' AND pl.PLANT_ID='P05' THEN 0
       WHEN p.part='BRG-6310-2RS' AND pl.PLANT_ID='P01' THEN 1
       ELSE MOD(ABS(HASH(p.part||pl.PLANT_ID)),6)+1 END,
  2, pl.PLANT_ID
FROM PDM_DB.RAW.PLANTS pl CROSS JOIN (VALUES
 ('BRG-6310-2RS','Deep groove ball bearing 6310','BEARING',85,5),
 ('MTR-IE3-30KW','IE3 induction motor 30kW','MOTOR',4200,28),
 ('DRV-VFD-30KW','Variable frequency drive 30kW','DRIVE',3100,21),
 ('PLC-S7-1500','PLC CPU S7-1500','PLC',2600,14),
 ('PSU-24VDC-20A','Power supply 24VDC 20A','PSU',320,10),
 ('SSD-IND-480G','Industrial SSD 480GB','RAID_DISK',240,7),
 ('CB-IO-MAIN-01','Main I/O control board','CONTROL_BOARD',1450,30),
 ('NSW-IND-8P','Industrial Ethernet switch 8-port','NETWORK_SWITCH',690,10),
 ('CBL-PWR-4X16','Power cable 4x16mm2 (per 10m)','CABLE',180,3)) p(part,pname,ctype,cost,lead);

-- ---------- Ground truth failure plan ----------
-- Slot A failures on days 20-40, slot B on days 65-88 (non-overlapping precursor windows).
-- IS_FUTURE rows: degradation in progress at end of data, not yet failed (live alert demo).
CREATE OR REPLACE TABLE PDM_DB.ML.SYNTH_GROUND_TRUTH COMMENT='Synthetic ground truth used to generate data and test model accuracy. IS_FUTURE=TRUE means degradation in progress, not yet failed.' AS
WITH plan AS (
  SELECT column1 k, column2 slot, column3 mode, column4 sub FROM VALUES
  (1,'A','MECHANICAL',NULL),(2,'A','MOISTURE',NULL),(3,'A','WIRING',NULL),(4,'A','MECHANICAL',NULL),(5,'A','MOISTURE',NULL),
  (6,'A','REDUNDANCY_LOSS','PSU'),(7,'A','MECHANICAL',NULL),(8,'A','OVERLOAD','MOTOR'),(9,'A','MOISTURE',NULL),(10,'A','MECHANICAL',NULL),
  (11,'A','POWER_QUALITY',NULL),(12,'A','MECHANICAL',NULL),(13,'A','MOISTURE',NULL),(14,'A','WIRING',NULL),(15,'A','MECHANICAL',NULL),
  (16,'A','REDUNDANCY_LOSS','RAID'),(17,'A','MOISTURE',NULL),(18,'A','MECHANICAL',NULL),(19,'A','OVERLOAD','SYSTEM'),(20,'A','MOISTURE',NULL),
  (21,'A','MECHANICAL',NULL),(22,'A','WIRING',NULL),(23,'A','POWER_QUALITY',NULL),(24,'A','MECHANICAL',NULL),(25,'A','REDUNDANCY_LOSS','PSU'),
  (26,'A','OVERLOAD','MOTOR'),(27,'A','MECHANICAL',NULL),(28,'A','WIRING',NULL),(29,'A','RANDOM',NULL),(30,'A','MECHANICAL',NULL),
  (31,'A','REDUNDANCY_LOSS','RAID'),(32,'A','OVERLOAD','SYSTEM'),(33,'A','MECHANICAL',NULL),(34,'A','WIRING',NULL),(35,'A','RANDOM',NULL),
  (1,'B','MECHANICAL',NULL),(2,'B','MOISTURE',NULL),(3,'B','MECHANICAL',NULL),(4,'B','WIRING',NULL),(5,'B','REDUNDANCY_LOSS','PSU'),
  (6,'B','OVERLOAD','SYSTEM'),(7,'B','MECHANICAL',NULL),(8,'B','RANDOM',NULL),(9,'B','MOISTURE',NULL),(10,'B','MECHANICAL',NULL)
),
base AS (
  SELECT k, mode, sub, FALSE is_future,
    DATEADD(hour, MOD(k*13,24), DATEADD(day, IFF(slot='A', 20+MOD(k*7,21), 65+MOD(k*5,24)), '2026-07-08 00:00:00'::TIMESTAMP_NTZ)) fts
  FROM plan
  UNION ALL SELECT * FROM VALUES
   (36,'POWER_SHOCK','SPIKE',FALSE,'2026-09-18 03:10:00'::TIMESTAMP_NTZ),
   (38,'POWER_SHOCK','SPIKE',FALSE,'2026-09-19 15:40:00'::TIMESTAMP_NTZ),
   (46,'POWER_SHOCK','INRUSH',FALSE,'2026-09-23 10:47:00'::TIMESTAMP_NTZ),
   (47,'POWER_SHOCK','INRUSH',FALSE,'2026-09-23 10:52:00'::TIMESTAMP_NTZ),
   (49,'POWER_SHOCK','INRUSH',FALSE,'2026-09-24 06:05:00'::TIMESTAMP_NTZ),
   (37,'MECHANICAL',NULL,TRUE,'2026-10-08 09:00:00'::TIMESTAMP_NTZ),
   (42,'OVERLOAD','MOTOR',TRUE,'2026-10-09 14:00:00'::TIMESTAMP_NTZ),
   (14,'MOISTURE',NULL,TRUE,'2026-10-10 04:00:00'::TIMESTAMP_NTZ),
   (39,'WIRING',NULL,TRUE,'2026-10-11 11:00:00'::TIMESTAMP_NTZ)
)
SELECT
  'M'||LPAD(k,3,'0') MACHINE_ID, mode FAILURE_MODE, sub SUB_MODE, is_future IS_FUTURE, fts FAILURE_TS,
  DATEADD(minute, CASE mode WHEN 'MECHANICAL' THEN 480+MOD(k*37,480) WHEN 'MOISTURE' THEN 240+MOD(k*37,360)
      WHEN 'WIRING' THEN 180+MOD(k*37,300) WHEN 'REDUNDANCY_LOSS' THEN 120+MOD(k*37,240) WHEN 'OVERLOAD' THEN 240+MOD(k*37,480)
      WHEN 'POWER_QUALITY' THEN 300+MOD(k*37,300) WHEN 'POWER_SHOCK' THEN 360+MOD(k*37,1080) ELSE 120+MOD(k*37,360) END, fts) RESTORED_TS,
  CASE mode WHEN 'MECHANICAL' THEN 10 WHEN 'MOISTURE' THEN 18 WHEN 'WIRING' THEN 14 WHEN 'REDUNDANCY_LOSS' THEN 20
      WHEN 'OVERLOAD' THEN 21 WHEN 'POWER_QUALITY' THEN 7 WHEN 'POWER_SHOCK' THEN IFF(sub='SPIKE',20,0) ELSE 0 END WINDOW_DAYS,
  'M'||LPAD(k,3,'0')||'-'||CASE mode WHEN 'MECHANICAL' THEN 'BRG' WHEN 'MOISTURE' THEN 'CB' WHEN 'WIRING' THEN 'CBL'
      WHEN 'REDUNDANCY_LOSS' THEN IFF(sub='PSU','PSU-B','DSK-2') WHEN 'OVERLOAD' THEN IFF(sub='MOTOR','MTR','PLC')
      WHEN 'POWER_QUALITY' THEN 'MTR' WHEN 'POWER_SHOCK' THEN 'DRV' ELSE IFF(MOD(k,2)=0,'CB','NSW') END COMPONENT_ID,
  CASE mode
    WHEN 'MECHANICAL' THEN 'Bearing outer race spalling due to wear and lubrication breakdown'
    WHEN 'MOISTURE' THEN 'Condensation inside control cabinet caused short circuit on main I/O board (degraded door seal)'
    WHEN 'WIRING' THEN 'Loose power terminal overheated, insulation melted, phase-to-ground fault'
    WHEN 'REDUNDANCY_LOSS' THEN IFF(sub='PSU','Redundant PSU A failed silently; PSU B failed later and machine lost 24VDC control power',
                                         'RAID disk 1 failed unnoticed; disk 2 failed, HMI/controller storage lost')
    WHEN 'OVERLOAD' THEN IFF(sub='MOTOR','Sustained operation above 110% rated load overheated motor windings',
                                       'Controller memory leak and full disk caused repeated watchdog resets and crash')
    WHEN 'POWER_QUALITY' THEN 'Supply phase imbalance (L3 low voltage) overheated motor windings'
    WHEN 'POWER_SHOCK' THEN IFF(sub='SPIKE','Repeated transient voltage spikes (no surge protection) damaged VFD IGBT module',
                                          'Restart inrush after plant power outage blew VFD DC bus capacitors')
    ELSE 'No precursor detected; component failed at end of life (random failure)' END ROOT_CAUSE
FROM base;

INSERT INTO PDM_DB.RAW.FAILURES
SELECT 'F'||LPAD(ROW_NUMBER() OVER (ORDER BY FAILURE_TS),4,'0'), MACHINE_ID, COMPONENT_ID, FAILURE_TS, RESTORED_TS,
       FAILURE_MODE, ROOT_CAUSE, DATEDIFF(minute, FAILURE_TS, RESTORED_TS)
FROM PDM_DB.ML.SYNTH_GROUND_TRUTH WHERE NOT IS_FUTURE;

-- ---------- Machine sensors (5-min, ~1.3M rows) ----------
-- p = 0..1 progress through the precursor window; each mode degrades its own signals.
INSERT INTO PDM_DB.RAW.SENSOR_READINGS
WITH ts AS (
  SELECT DATEADD(minute, 5*(ROW_NUMBER() OVER (ORDER BY SEQ4())-1), '2026-07-08 00:00:00'::TIMESTAMP_NTZ) t
  FROM TABLE(GENERATOR(ROWCOUNT=>25920))
), grid AS (
  SELECT m.MACHINE_ID, m.RATED_RPM, m.RATED_CURRENT_AMPS, t.t,
    DECODE(p.CLIMATE_ZONE,'HUMID',62,'TEMPERATE',45,22) hbase,
    SIN(2*PI()*(HOUR(t.t)+MINUTE(t.t)/60-8)/24) diur,
    IFF(HOUR(t.t) BETWEEN 0 AND 6,1,0) night
  FROM PDM_DB.RAW.MACHINES m
  JOIN PDM_DB.RAW.PRODUCTION_LINES l ON l.LINE_ID=m.LINE_ID
  JOIN PDM_DB.RAW.PLANTS p ON p.PLANT_ID=l.PLANT_ID
  CROSS JOIN ts t
), s AS (
  SELECT g.*, gt.FAILURE_MODE fm, gt.SUB_MODE sm,
    IFF(gt.MACHINE_ID IS NOT NULL AND g.t>=gt.FAILURE_TS, 1, 0) down,
    IFF(gt.MACHINE_ID IS NOT NULL AND g.t<gt.FAILURE_TS AND gt.WINDOW_DAYS>0,
        GREATEST(0, 1-DATEDIFF(minute,g.t,gt.FAILURE_TS)/(gt.WINDOW_DAYS*1440)), 0) p
  FROM grid g LEFT JOIN PDM_DB.ML.SYNTH_GROUND_TRUTH gt
    ON gt.MACHINE_ID=g.MACHINE_ID
   AND g.t >= DATEADD(day,-gt.WINDOW_DAYS,gt.FAILURE_TS) AND g.t < gt.RESTORED_TS
), f AS (
  SELECT *,
    IFF(fm='MECHANICAL',p,0) pM, IFF(fm='MOISTURE',p,0) pMo, IFF(fm='WIRING',p,0) pW,
    IFF(fm='OVERLOAD' AND sm='MOTOR',p,0) pOV, IFF(fm='POWER_QUALITY',p,0) pPQ,
    IFF(fm='REDUNDANCY_LOSS' AND sm='PSU',p,0) pR, IFF(fm='POWER_SHOCK',p,0) pS,
    75 + 5*NORMAL(0,1,RANDOM()) + 40*IFF(fm='OVERLOAD' AND sm='MOTOR',p,0) loadv,
    LEAST(99, GREATEST(5, hbase - 8*diur + 3*NORMAL(0,1,RANDOM()) + 40*IFF(fm='MOISTURE',p,0))) hum,
    32 + 5*diur + NORMAL(0,1,RANDOM()) - 6*IFF(fm='MOISTURE',p,0)*night cab
  FROM s
)
SELECT MACHINE_ID, t,
  ROUND(IFF(down=1, 0.2, GREATEST(0.3, 2.0 + 0.3*NORMAL(0,1,RANDOM()) + 6*POW(pM,2) + 1.0*pPQ + 0.8*pOV)),2),
  ROUND(IFF(down=1, 35, 55 + 3*diur + 1.5*NORMAL(0,1,RANDOM()) + 25*POW(pM,2) + 10*pOV),2),
  ROUND(IFF(down=1, 35, 70 + 4*diur + 2*NORMAL(0,1,RANDOM()) + 30*pOV + 25*pPQ),2),
  ROUND(IFF(down=1, 0, RATED_RPM*(0.985 + 0.005*NORMAL(0,1,RANDOM()))),1),
  ROUND(IFF(down=1, 0, RATED_CURRENT_AMPS*loadv/100*(1+0.1*pPQ)*(1+0.02*NORMAL(0,1,RANDOM()))),2),
  ROUND(IFF(down=1, 0, RATED_CURRENT_AMPS*loadv/100*(1+0.1*pPQ)*(1+0.02*NORMAL(0,1,RANDOM()))),2),
  ROUND(IFF(down=1, 0, RATED_CURRENT_AMPS*loadv/100*(1-0.25*pPQ)*(1+0.02*NORMAL(0,1,RANDOM()))),2),
  ROUND(IFF(down=1, 0, GREATEST(0,loadv)),1),
  ROUND(hum,1),
  ROUND(cab,2),
  ROUND((cab + 6*pMo*night) - (100-hum)/5, 2),
  (pMo>0.85 AND UNIFORM(0::FLOAT,1::FLOAT,RANDOM())<0.2),
  ROUND(GREATEST(1, 500*(1-0.9*pMo)*(1-0.6*pW) + 20*NORMAL(0,1,RANDOM())),1),
  ROUND(IFF(down=1, 30, 40 + 3*diur + 1.5*NORMAL(0,1,RANDOM()) + 50*POW(pW,1.5) + 8*pOV),2),
  ROUND(GREATEST(0.1, 0.5 + 0.05*NORMAL(0,1,RANDOM()) + 4*POW(pW,2)),3),
  ROUND(GREATEST(1, 20 + 2*NORMAL(0,1,RANDOM()) + 40*pR + 60*pS),1)
FROM f;

-- ---------- Power events: background + scenarios ----------
-- Line 8: 6 transient spikes (no SPD) before 2 drive failures. Line 10: outage + restart inrush.
-- Phase-loss events are placed 25 min before each POWER_QUALITY failure.
INSERT INTO PDM_DB.RAW.POWER_EVENTS
WITH bg AS (
  SELECT UNIFORM(1,10,RANDOM()) l, UNIFORM(0::FLOAT,1::FLOAT,RANDOM()) r,
    DATEADD(second, UNIFORM(0, 7776000, RANDOM()), '2026-07-08 00:00:00'::TIMESTAMP_NTZ) ts
  FROM TABLE(GENERATOR(ROWCOUNT=>260))
), bg2 AS (
  SELECT 'PF-'||LPAD(l,2,'0') feed, ts,
    CASE WHEN r<0.5 THEN 'SAG' WHEN r<0.75 THEN 'TRANSIENT_SPIKE' WHEN r<0.85 THEN 'SURGE'
         WHEN r<0.9 THEN 'OUTAGE' WHEN r<0.95 THEN 'ESD' ELSE 'GROUND_FAULT' END et, l
  FROM bg
), allev AS (
  SELECT feed, ts, et,
    CASE et WHEN 'SAG' THEN UNIFORM(40,400,RANDOM()) WHEN 'TRANSIENT_SPIKE' THEN UNIFORM(1,5,RANDOM())/10
      WHEN 'SURGE' THEN UNIFORM(5,80,RANDOM()) WHEN 'OUTAGE' THEN UNIFORM(60000,900000,RANDOM())
      WHEN 'ESD' THEN 1 ELSE UNIFORM(20,200,RANDOM()) END dur,
    CASE et WHEN 'SAG' THEN UNIFORM(65,90,RANDOM()) WHEN 'TRANSIENT_SPIKE' THEN UNIFORM(600,1400,RANDOM())
      WHEN 'SURGE' THEN UNIFORM(260,320,RANDOM()) WHEN 'OUTAGE' THEN 0 WHEN 'ESD' THEN UNIFORM(2000,8000,RANDOM())
      ELSE UNIFORM(5,40,RANDOM()) END mag,
    (et IN ('TRANSIENT_SPIKE','SURGE') AND l NOT IN (8,10)) spd
  FROM bg2
  UNION ALL SELECT * FROM VALUES
   ('PF-08','2026-08-30 14:02:11'::TIMESTAMP_NTZ,'TRANSIENT_SPIKE',0.3,1350,FALSE),
   ('PF-08','2026-09-03 02:47:40'::TIMESTAMP_NTZ,'TRANSIENT_SPIKE',0.2,1180,FALSE),
   ('PF-08','2026-09-07 16:20:05'::TIMESTAMP_NTZ,'TRANSIENT_SPIKE',0.4,1520,FALSE),
   ('PF-08','2026-09-11 11:09:33'::TIMESTAMP_NTZ,'TRANSIENT_SPIKE',0.3,1290,FALSE),
   ('PF-08','2026-09-14 19:55:18'::TIMESTAMP_NTZ,'TRANSIENT_SPIKE',0.5,1610,FALSE),
   ('PF-08','2026-09-17 23:31:02'::TIMESTAMP_NTZ,'TRANSIENT_SPIKE',0.4,1440,FALSE),
   ('PF-10','2026-09-23 10:12:00'::TIMESTAMP_NTZ,'OUTAGE',1980000,0,FALSE),
   ('PF-10','2026-09-23 10:45:00'::TIMESTAMP_NTZ,'RESTART_INRUSH',850,640,FALSE)
  UNION ALL
  SELECT l.POWER_FEED_ID, DATEADD(minute,-25,gt.FAILURE_TS), 'PHASE_LOSS', 3500, 0, FALSE
  FROM PDM_DB.ML.SYNTH_GROUND_TRUTH gt
  JOIN PDM_DB.RAW.MACHINES m ON m.MACHINE_ID=gt.MACHINE_ID JOIN PDM_DB.RAW.PRODUCTION_LINES l ON l.LINE_ID=m.LINE_ID
  WHERE gt.FAILURE_MODE='POWER_QUALITY'
)
SELECT 'PE'||LPAD(ROW_NUMBER() OVER (ORDER BY ts),5,'0'), feed, ts, et, dur, mag, spd FROM allev;

-- ---------- Power readings (5-min per feed) ----------
INSERT INTO PDM_DB.RAW.POWER_READINGS
WITH ts AS (
  SELECT DATEADD(minute, 5*(ROW_NUMBER() OVER (ORDER BY SEQ4())-1), '2026-07-08 00:00:00'::TIMESTAMP_NTZ) t
  FROM TABLE(GENERATOR(ROWCOUNT=>25920))
), pq AS (
  SELECT l.POWER_FEED_ID feed, gt.FAILURE_TS, gt.RESTORED_TS FROM PDM_DB.ML.SYNTH_GROUND_TRUTH gt
  JOIN PDM_DB.RAW.MACHINES m ON m.MACHINE_ID=gt.MACHINE_ID JOIN PDM_DB.RAW.PRODUCTION_LINES l ON l.LINE_ID=m.LINE_ID
  WHERE gt.FAILURE_MODE='POWER_QUALITY'
), g AS (
  SELECT l.POWER_FEED_ID feed, t.t,
    MAX(IFF(pq.feed IS NOT NULL, GREATEST(0,1-DATEDIFF(minute,t.t,pq.FAILURE_TS)/(7*1440)),0)) p,
    MAX(IFF(o.EVENT_ID IS NOT NULL,1,0)) outage
  FROM PDM_DB.RAW.PRODUCTION_LINES l CROSS JOIN ts t
  LEFT JOIN pq ON pq.feed=l.POWER_FEED_ID AND t.t BETWEEN DATEADD(day,-7,pq.FAILURE_TS) AND pq.RESTORED_TS
  LEFT JOIN PDM_DB.RAW.POWER_EVENTS o ON o.POWER_FEED_ID=l.POWER_FEED_ID AND o.EVENT_TYPE='OUTAGE'
       AND t.t BETWEEN o.EVENT_TS AND DATEADD(millisecond,o.DURATION_MS,o.EVENT_TS)
  GROUP BY 1,2
)
SELECT feed, t,
  ROUND(IFF(outage=1,0,400+3*NORMAL(0,1,RANDOM())),1),
  ROUND(IFF(outage=1,0,400+3*NORMAL(0,1,RANDOM())),1),
  ROUND(IFF(outage=1,0,400*(1-0.12*p)+3*NORMAL(0,1,RANDOM())),1),
  ROUND(IFF(outage=1,0,50+0.02*NORMAL(0,1,RANDOM())),3),
  ROUND(IFF(outage=1,0,GREATEST(0.5,3.2+0.6*NORMAL(0,1,RANDOM())+4*p)),2)
FROM g;

-- ---------- Redundant component health ----------
-- M041/M044 currently running on PSU B only (silent risk); M027 RAID degraded then rebuilt.
INSERT INTO PDM_DB.RAW.COMPONENT_HEALTH
SELECT COMPONENT_ID, '2026-07-08 00:00:00'::TIMESTAMP_NTZ, 'HEALTHY', 'Baseline status'
FROM PDM_DB.RAW.COMPONENTS WHERE REDUNDANCY_GROUP IS NOT NULL
UNION ALL
SELECT MACHINE_ID||IFF(SUB_MODE='PSU','-PSU-A','-DSK-1'), DATEADD(day,-WINDOW_DAYS,FAILURE_TS),
  'FAILED', IFF(SUB_MODE='PSU','PSU A output lost - running on PSU B only (no redundancy)','RAID member disk 1 failed - array DEGRADED, running on disk 2 only')
FROM PDM_DB.ML.SYNTH_GROUND_TRUTH WHERE FAILURE_MODE='REDUNDANCY_LOSS'
UNION ALL
SELECT COMPONENT_ID, FAILURE_TS, 'FAILED', IFF(SUB_MODE='PSU','PSU B failed - 24VDC control power lost','RAID disk 2 failed - array FAILED')
FROM PDM_DB.ML.SYNTH_GROUND_TRUTH WHERE FAILURE_MODE='REDUNDANCY_LOSS'
UNION ALL
SELECT MACHINE_ID||s.sfx, RESTORED_TS, 'HEALTHY', 'Replaced during corrective maintenance'
FROM PDM_DB.ML.SYNTH_GROUND_TRUTH gt
CROSS JOIN (SELECT column1 sfx, column2 sub FROM VALUES ('-PSU-A','PSU'),('-PSU-B','PSU'),('-DSK-1','RAID'),('-DSK-2','RAID')) s
WHERE gt.FAILURE_MODE='REDUNDANCY_LOSS' AND s.sub=gt.SUB_MODE
UNION ALL SELECT * FROM VALUES
 ('M041-PSU-A','2026-09-27 05:14:00'::TIMESTAMP_NTZ,'FAILED','PSU A output lost - running on PSU B only (no redundancy)'),
 ('M044-PSU-A','2026-10-01 22:40:00'::TIMESTAMP_NTZ,'FAILED','PSU A output lost - running on PSU B only (no redundancy)'),
 ('M027-DSK-1','2026-09-30 12:05:00'::TIMESTAMP_NTZ,'FAILED','RAID member disk 1 failed - array DEGRADED'),
 ('M027-DSK-1','2026-10-01 09:30:00'::TIMESTAMP_NTZ,'REBUILDING','Disk replaced - RAID rebuilding (no redundancy until complete)'),
 ('M027-DSK-1','2026-10-01 15:10:00'::TIMESTAMP_NTZ,'HEALTHY','RAID rebuild complete');

-- ---------- Controller / edge PC utilization (15-min) ----------
INSERT INTO PDM_DB.RAW.SYSTEM_METRICS
WITH ts AS (
  SELECT DATEADD(minute, 15*(ROW_NUMBER() OVER (ORDER BY SEQ4())-1), '2026-07-08 00:00:00'::TIMESTAMP_NTZ) t
  FROM TABLE(GENERATOR(ROWCOUNT=>8640))
), g AS (
  SELECT m.MACHINE_ID, t.t,
    IFF(gt.MACHINE_ID IS NOT NULL AND t.t<gt.FAILURE_TS, GREATEST(0,1-DATEDIFF(minute,t.t,gt.FAILURE_TS)/(21*1440)),0) p,
    IFF(gt.MACHINE_ID IS NOT NULL AND t.t>=gt.FAILURE_TS,1,0) down,
    MOD(ABS(HASH(m.MACHINE_ID)),20) d0
  FROM PDM_DB.RAW.MACHINES m CROSS JOIN ts t
  LEFT JOIN PDM_DB.ML.SYNTH_GROUND_TRUTH gt ON gt.MACHINE_ID=m.MACHINE_ID AND gt.FAILURE_MODE='OVERLOAD' AND gt.SUB_MODE='SYSTEM'
    AND t.t BETWEEN DATEADD(day,-21,gt.FAILURE_TS) AND gt.RESTORED_TS
)
SELECT MACHINE_ID, t, 'EDGE_PC',
  ROUND(IFF(down=1,0,LEAST(100,GREATEST(2, 35+8*NORMAL(0,1,RANDOM())+55*POW(p,2)))),1),
  ROUND(IFF(down=1,0,LEAST(100, 42+3*NORMAL(0,1,RANDOM())+56*p)),1),
  ROUND(LEAST(100, 45+d0+0.05*DATEDIFF(day,'2026-07-08',t)+52*p),1),
  IFF(UNIFORM(0::FLOAT,1::FLOAT,RANDOM())<0.02+0.3*p, UNIFORM(1,5,RANDOM()), 0),
  IFF(p>0.8 AND UNIFORM(0::FLOAT,1::FLOAT,RANDOM())<0.25, 1, 0)
FROM g;

-- ---------- Fault logs: failure faults, early warnings, background noise ----------
INSERT INTO PDM_DB.RAW.FAULT_LOGS
SELECT MACHINE_ID, FAILURE_TS,
  CASE FAILURE_MODE WHEN 'MECHANICAL' THEN 'DRIVE' WHEN 'REDUNDANCY_LOSS' THEN IFF(SUB_MODE='PSU','PSU','PLC') WHEN 'WIRING' THEN 'BREAKER'
    WHEN 'OVERLOAD' THEN IFF(SUB_MODE='MOTOR','DRIVE','PLC') WHEN 'MOISTURE' THEN 'PLC' ELSE 'DRIVE' END,
  CASE FAILURE_MODE WHEN 'MECHANICAL' THEN 'F0039' WHEN 'MOISTURE' THEN 'E-IO-SHORT' WHEN 'WIRING' THEN 'GF-TRIP'
    WHEN 'REDUNDANCY_LOSS' THEN IFF(SUB_MODE='PSU','PSU-B-LOST','RAID-FAIL') WHEN 'OVERLOAD' THEN IFF(SUB_MODE='MOTOR','F0011','WDT-CRASH')
    WHEN 'POWER_QUALITY' THEN 'F0022' WHEN 'POWER_SHOCK' THEN IFF(SUB_MODE='SPIKE','F0005','F0030') ELSE 'E-HW-UNKNOWN' END,
  CASE FAILURE_MODE WHEN 'MECHANICAL' THEN 'Mechanical overload / high vibration trip' WHEN 'MOISTURE' THEN 'I/O board short circuit detected'
    WHEN 'WIRING' THEN 'Ground fault breaker trip' WHEN 'REDUNDANCY_LOSS' THEN IFF(SUB_MODE='PSU','All 24VDC supplies lost','Storage array failed')
    WHEN 'OVERLOAD' THEN IFF(SUB_MODE='MOTOR','Motor overtemperature','Controller crash after repeated watchdog resets')
    WHEN 'POWER_QUALITY' THEN 'Input phase loss / imbalance' WHEN 'POWER_SHOCK' THEN IFF(SUB_MODE='SPIKE','IGBT desaturation / overcurrent','DC bus overvoltage')
    ELSE 'Unknown hardware fault' END,
  'CRITICAL'
FROM PDM_DB.ML.SYNTH_GROUND_TRUTH WHERE NOT IS_FUTURE
UNION ALL
SELECT gt.MACHINE_ID,
  DATEADD(minute, -(60 + UNIFORM(0::FLOAT,1::FLOAT,RANDOM())*gt.WINDOW_DAYS*1440*0.6)::INT, LEAST(gt.FAILURE_TS,'2026-10-05 23:00:00'::TIMESTAMP_NTZ)),
  CASE gt.FAILURE_MODE WHEN 'MECHANICAL' THEN 'DRIVE' WHEN 'WIRING' THEN 'DRIVE' WHEN 'MOISTURE' THEN 'PLC' WHEN 'REDUNDANCY_LOSS' THEN 'PSU' ELSE 'PLC' END,
  CASE gt.FAILURE_MODE WHEN 'MECHANICAL' THEN 'A0501' WHEN 'WIRING' THEN 'A0910' WHEN 'MOISTURE' THEN 'W-IO-LEAK' WHEN 'REDUNDANCY_LOSS' THEN 'W-PSU-RED'
    WHEN 'OVERLOAD' THEN IFF(gt.SUB_MODE='MOTOR','A0504','W-MEM-HIGH') ELSE 'W-GEN' END,
  CASE gt.FAILURE_MODE WHEN 'MECHANICAL' THEN 'Vibration warning threshold exceeded' WHEN 'WIRING' THEN 'Output phase current asymmetry'
    WHEN 'MOISTURE' THEN 'I/O channel leakage current warning' WHEN 'REDUNDANCY_LOSS' THEN 'Redundancy lost on power supply/storage'
    WHEN 'OVERLOAD' THEN IFF(gt.SUB_MODE='MOTOR','Motor thermal model > 90%','Memory usage high') ELSE 'General warning' END,
  'WARNING'
FROM PDM_DB.ML.SYNTH_GROUND_TRUTH gt CROSS JOIN TABLE(GENERATOR(ROWCOUNT=>4))
WHERE gt.WINDOW_DAYS>0
UNION ALL
SELECT 'M'||LPAD(UNIFORM(1,50,RANDOM()),3,'0'), DATEADD(second, UNIFORM(0,7776000,RANDOM()), '2026-07-08'::TIMESTAMP_NTZ),
  'PLC', 'I-COMM-RETRY', 'Fieldbus communication retry', 'INFO'
FROM TABLE(GENERATOR(ROWCOUNT=>400));

-- ---------- Work orders: corrective, preventive, inspection ----------
INSERT INTO PDM_DB.RAW.WORK_ORDERS
WITH techs AS (SELECT ARRAY_CONSTRUCT('R. Kumar','A. Iyer','J. Martinez','S. Okafor','K. Weber','L. Chen','M. Rossi','D. Patel') a),
corr AS (
  SELECT f.MACHINE_ID, f.COMPONENT_ID, f.FAILURE_ID, 'CORRECTIVE' t, 'P1' pr, 'COMPLETED' st,
    DATEADD(minute,10,f.FAILURE_TS) c, f.RESTORED_TS d,
    'Breakdown repair: '||f.ROOT_CAUSE descr, c.PART_NUMBER part,
    ROUND(f.DOWNTIME_MINUTES/60*0.8,2) hrs
  FROM PDM_DB.RAW.FAILURES f JOIN PDM_DB.RAW.COMPONENTS c ON c.COMPONENT_ID=f.COMPONENT_ID
),
prev AS (
  SELECT m.MACHINE_ID, m.MACHINE_ID||'-BRG', NULL, 'PREVENTIVE', 'P3', IFF(n.n=3 AND m.MACHINE_ID IN ('M037','M039'),'OPEN','COMPLETED'),
    DATEADD(day, 30*(n.n-1)+MOD(ABS(HASH(m.MACHINE_ID)),25), '2026-07-08 07:00:00'::TIMESTAMP_NTZ),
    IFF(n.n=3 AND m.MACHINE_ID IN ('M037','M039'),NULL,DATEADD(hour,3,DATEADD(day, 30*(n.n-1)+MOD(ABS(HASH(m.MACHINE_ID)),25), '2026-07-08 07:00:00'::TIMESTAMP_NTZ))),
    'Monthly PM: lubrication, belt check, filter clean, terminal re-torque', NULL, 2.5
  FROM PDM_DB.RAW.MACHINES m CROSS JOIN (SELECT column1 n FROM VALUES (1),(2),(3)) n
),
insp AS (
  SELECT MACHINE_ID, MACHINE_ID||'-CBL', NULL, 'INSPECTION', 'P3', 'COMPLETED',
    DATEADD(day,-UNIFORM(4,9,RANDOM()),LEAST(FAILURE_TS,'2026-10-05'::TIMESTAMP_NTZ)), NULL,
    'Electrical / thermal inspection of control cabinet', NULL, 1.5
  FROM PDM_DB.ML.SYNTH_GROUND_TRUTH WHERE FAILURE_MODE IN ('WIRING','MOISTURE')
),
u AS (SELECT * FROM corr UNION ALL SELECT * FROM prev UNION ALL SELECT * FROM insp)
SELECT 'WO'||LPAD(ROW_NUMBER() OVER (ORDER BY u.c),5,'0'), u.MACHINE_ID, u.COMPONENT_ID, u.FAILURE_ID, u.t, u.pr, u.st, u.c,
  COALESCE(u.d, IFF(u.t='INSPECTION', DATEADD(hour,2,u.c), NULL)), u.descr,
  GET(techs.a, MOD(ABS(HASH(u.MACHINE_ID||u.c)),8))::VARCHAR, u.part, u.hrs,
  ROUND(u.hrs*65 + COALESCE(sp.UNIT_COST_USD,0),2), 'HUMAN'
FROM u CROSS JOIN techs
LEFT JOIN PDM_DB.RAW.MACHINES m ON m.MACHINE_ID=u.MACHINE_ID
LEFT JOIN PDM_DB.RAW.PRODUCTION_LINES l ON l.LINE_ID=m.LINE_ID
LEFT JOIN PDM_DB.RAW.SPARE_PARTS sp ON sp.PART_NUMBER=u.part AND sp.PLANT_ID=l.PLANT_ID;

-- ---------- Inspection reports (unstructured text) ----------
-- Wiring/moisture reports flag the problem days before failure but "Machine left in service".
INSERT INTO PDM_DB.RAW.INSPECTION_REPORTS
WITH techs AS (SELECT ARRAY_CONSTRUCT('R. Kumar','A. Iyer','J. Martinez','S. Okafor','K. Weber','L. Chen','M. Rossi','D. Patel') a),
risk AS (
  SELECT gt.MACHINE_ID, gt.FAILURE_MODE, DATEADD(day,-UNIFORM(4,9,RANDOM()),LEAST(gt.FAILURE_TS,'2026-10-05'::TIMESTAMP_NTZ))::DATE d,
    IFF(gt.FAILURE_MODE='WIRING','THERMAL_SCAN','VISUAL') typ,
    CASE gt.FAILURE_MODE
    WHEN 'WIRING' THEN 'Thermal scan of main power cabinet. Terminal L2 on main contactor K1 measured '||UNIFORM(68,84,RANDOM())||
      'C vs '||UNIFORM(38,44,RANDOM())||'C on L1/L3. Slight discoloration of insulation near lug. Possible loose connection. '||
      'Recommended re-torque at next planned stop. Machine left in service.'
    ELSE 'Visual inspection of control cabinet. Door gasket cracked on lower edge, water marks on cabinet floor. '||
      'Light corrosion visible on I/O terminal strip X2. Cabinet heater not working. Humidity felt high inside panel. '||
      'Recommended gasket replacement and heater repair - parts to be ordered. Machine left in service.' END txt
  FROM PDM_DB.ML.SYNTH_GROUND_TRUTH gt WHERE gt.FAILURE_MODE IN ('WIRING','MOISTURE')
),
routine AS (
  SELECT m.MACHINE_ID, NULL fm, DATEADD(day, 20+MOD(ABS(HASH(m.MACHINE_ID)),60), '2026-07-08'::DATE) d,
    IFF(MOD(ABS(HASH(m.MACHINE_ID)),2)=0,'THERMAL_SCAN','ELECTRICAL') typ,
    IFF(MOD(ABS(HASH(m.MACHINE_ID)),2)=0,
      'Routine thermal scan. All terminals within 5C of each other, max '||UNIFORM(36,45,RANDOM())||'C. No hot spots. No action required.',
      'Routine electrical check. Insulation resistance '||UNIFORM(400,650,RANDOM())||' MOhm, phase currents balanced, PSU A/B both OK, grounding verified. No action required.') txt
  FROM PDM_DB.RAW.MACHINES m
),
spike AS (
  SELECT column1, NULL, column2::DATE, 'ELECTRICAL', column3 FROM VALUES
  ('M036','2026-09-20','Post-failure electrical inspection Line 8. VFD IGBT module burnt. No surge protective device installed on line 8 incoming feed. Power quality meter shows 6 transient spikes >1100V in last 3 weeks. Recommend SPD installation on all Line 8 drives.'),
  ('M046','2026-09-24','Post-outage inspection Line 10. After utility outage at 10:12 all drives restarted simultaneously at 10:45. Three VFDs failed with DC bus overvoltage. No UPS and no staggered restart sequence configured. Recommend soft-start sequencing and UPS for PLC.')
),
u AS (SELECT * FROM risk UNION ALL SELECT * FROM routine UNION ALL SELECT * FROM spike)
SELECT 'IR'||LPAD(ROW_NUMBER() OVER (ORDER BY d),4,'0'), MACHINE_ID, d, typ,
  GET(techs.a, MOD(ABS(HASH(MACHINE_ID||d)),8))::VARCHAR, txt
FROM u CROSS JOIN techs;

-- ---------- Shift production output (for OEE) ----------
INSERT INTO PDM_DB.RAW.PRODUCTION_OUTPUT
WITH sh AS (
  SELECT DATEADD(day, d.d, '2026-07-08'::DATE) dt, s.s, s.h FROM
  (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())-1 d FROM TABLE(GENERATOR(ROWCOUNT=>90))) d
  CROSS JOIN (SELECT column1 s, column2 h FROM VALUES ('A',6),('B',14),('C',22)) s
), g AS (
  SELECT m.MACHINE_ID, m.IDEAL_CYCLE_TIME_SEC ict, sh.dt, sh.s,
    DATEADD(hour, sh.h, sh.dt::TIMESTAMP_NTZ) st, DATEADD(hour, sh.h+8, sh.dt::TIMESTAMP_NTZ) en
  FROM PDM_DB.RAW.MACHINES m CROSS JOIN sh
), j AS (
  SELECT g.MACHINE_ID, g.ict, g.dt, g.s,
    SUM(IFF(f.FAILURE_ID IS NULL,0, DATEDIFF(minute, GREATEST(g.st,f.FAILURE_TS), LEAST(g.en,f.RESTORED_TS)))) down_min,
    MAX(IFF(gt.MACHINE_ID IS NULL,0, GREATEST(0,1-DATEDIFF(minute,g.en,gt.FAILURE_TS)/(GREATEST(gt.WINDOW_DAYS,1)*1440)))) p
  FROM g
  LEFT JOIN PDM_DB.RAW.FAILURES f ON f.MACHINE_ID=g.MACHINE_ID AND f.FAILURE_TS<g.en AND f.RESTORED_TS>g.st
  LEFT JOIN PDM_DB.ML.SYNTH_GROUND_TRUTH gt ON gt.MACHINE_ID=g.MACHINE_ID AND g.en < gt.FAILURE_TS
       AND g.en >= DATEADD(day,-gt.WINDOW_DAYS,gt.FAILURE_TS)
  GROUP BY 1,2,3,4
), r AS (
  SELECT *, GREATEST(0, 480 - down_min - UNIFORM(5,35,RANDOM())) run_min,
    (0.93 + 0.04*UNIFORM(0::FLOAT,1::FLOAT,RANDOM()) - 0.12*p) perf,
    (0.985 + 0.012*UNIFORM(0::FLOAT,1::FLOAT,RANDOM()) - 0.06*p) qual
  FROM j
)
SELECT MACHINE_ID, dt, s, 480, run_min, FLOOR(run_min*60/ict*perf) tot, FLOOR(FLOOR(run_min*60/ict*perf)*qual)
FROM r;
