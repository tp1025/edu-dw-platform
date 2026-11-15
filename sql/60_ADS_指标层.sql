-- =====================================================================
-- ADS 层：应用指标表（面向报表/看板，直接可查）
-- 原则：只从 DWS/DWD 汇总层取数，不再回源明细表
-- 口径与 DWS 保持一致：
--   · 挂科率 = 正考<60 的比例    · 均分 = 最高分口径
--   · 出勤率 = 出勤(1)/有效考勤  · 折算缺勤 = 旷课 + 迟到>30min + 早退>30min
-- =====================================================================
USE edu_dw;


-- =====================================================================
-- 1) ads_term_kpi —— 学期 KPI 总览（看板首页）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_term_kpi;
CREATE TABLE edu_dw.ads_term_kpi (
  term_id          INT          NOT NULL,
  term_name        VARCHAR(64)  NULL,
  season           VARCHAR(8)   NULL,
  student_cnt      INT          NOT NULL COMMENT '有选课记录的学生数',
  select_cnt       INT          NOT NULL COMMENT '选课人次',
  avg_select       DECIMAL(6,2) NULL COMMENT '人均选课门数',
  avg_score        DECIMAL(5,2) NULL COMMENT '全校均分',
  fail_rate        DECIMAL(6,4) NULL COMMENT '挂科率（正考口径）',
  excellent_rate   DECIMAL(6,4) NULL COMMENT '优良率（>=80）',
  avg_attend_rate  DECIMAL(6,4) NULL COMMENT '平均出勤率',
  risk_student_cnt INT          NOT NULL COMMENT '预警学生数',
  dt               CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-学期KPI总览';

INSERT INTO edu_dw.ads_term_kpi
  (term_id, term_name, season, student_cnt, select_cnt, avg_select,
   avg_score, fail_rate, excellent_rate, avg_attend_rate, risk_student_cnt, dt)
SELECT s.term_id, MAX(t.term_name), MAX(t.season),
       COUNT(*) AS student_cnt,
       SUM(s.select_cnt) AS select_cnt,
       ROUND(AVG(s.select_cnt), 2),
       ROUND(AVG(s.avg_score), 2),
       ROUND(SUM(s.fail_cnt) / NULLIF(SUM(s.scored_cnt), 0), 4),
       ROUND(SUM(CASE WHEN s.avg_score >= 80 THEN 1 ELSE 0 END) / COUNT(*), 4),
       ROUND(AVG(s.attend_rate), 4),
       SUM(CASE WHEN s.fail_cnt >= 2 OR s.att_converted >= 8 THEN 1 ELSE 0 END),
       '2026-11-11'
FROM edu_dw.dws_student_term s
LEFT JOIN edu_dw.dim_term t ON t.term_id = s.term_id
GROUP BY s.term_id;

SELECT * FROM edu_dw.ads_term_kpi ORDER BY term_id;


-- =====================================================================
-- 2) ads_course_fail_rank —— 课程挂科率排行（教学预警）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_course_fail_rank;
CREATE TABLE edu_dw.ads_course_fail_rank (
  term_id      INT          NOT NULL,
  rank_no      INT          NOT NULL,
  course_id    INT          NOT NULL,
  course_code  VARCHAR(32)  NULL,
  course_name  VARCHAR(100) NULL,
  course_type_name VARCHAR(16) NULL,
  credit       DECIMAL(3,1) NULL,
  scored_cnt   INT          NOT NULL COMMENT '有成绩人数',
  fail_cnt     INT          NOT NULL,
  fail_rate    DECIMAL(6,4) NOT NULL,
  avg_score    DECIMAL(5,2) NULL,
  attend_rate  DECIMAL(6,4) NULL,
  dt           CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, course_id),
  KEY idx_rank (term_id, rank_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-课程挂科率排行';

INSERT INTO edu_dw.ads_course_fail_rank
  (term_id, rank_no, course_id, course_code, course_name, course_type_name,
   credit, scored_cnt, fail_cnt, fail_rate, avg_score, attend_rate, dt)
SELECT term_id,
       ROW_NUMBER() OVER (PARTITION BY term_id ORDER BY fail_rate DESC, scored_cnt DESC) AS rank_no,
       course_id, course_code, course_name, course_type_name, credit,
       scored_cnt, fail_cnt, fail_rate, avg_score, attend_rate, '2026-11-11'
FROM edu_dw.dws_course_term
WHERE scored_cnt >= 30;    -- 样本太小的课程不参与排名

SELECT COUNT(*) AS rows_ FROM edu_dw.ads_course_fail_rank;


-- =====================================================================
-- 3) ads_student_risk —— 学业预警名单（辅导员/教务直接用）
--   分级：高风险（挂科>=3 或 折算缺勤>5）/ 中风险（挂科=2 或 折算缺勤 4~5）/ 关注（挂科=1）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_student_risk;
CREATE TABLE edu_dw.ads_student_risk (
  term_id        INT          NOT NULL,
  student_id     BIGINT       NOT NULL,
  student_no     VARCHAR(32)  NULL,
  student_name   VARCHAR(64)  NULL,
  class_name     VARCHAR(64)  NULL,
  major_name     VARCHAR(100) NULL,
  college_name   VARCHAR(100) NULL,
  select_cnt     INT          NOT NULL,
  scored_cnt     INT          NOT NULL,
  fail_cnt       INT          NOT NULL,
  avg_score      DECIMAL(5,2) NULL,
  att_converted  INT          NOT NULL COMMENT '折算缺勤次数',
  attend_rate    DECIMAL(6,4) NULL,
  risk_level     VARCHAR(8)   NOT NULL COMMENT '高风险/中风险/关注',
  risk_reason    VARCHAR(128) NULL,
  dt             CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, student_id),
  KEY idx_level (term_id, risk_level)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-学业预警名单';

INSERT INTO edu_dw.ads_student_risk
  (term_id, student_id, student_no, student_name, class_name, major_name, college_name,
   select_cnt, scored_cnt, fail_cnt, avg_score, att_converted, attend_rate,
   risk_level, risk_reason, dt)
SELECT term_id, student_id, student_no, student_name, class_name, major_name, college_name,
       select_cnt, scored_cnt, fail_cnt, avg_score, att_converted, attend_rate,
       CASE WHEN fail_cnt >= 4 OR att_converted >= 12 THEN '高风险'
            WHEN fail_cnt >= 2 OR att_converted >= 8  THEN '中风险'
            ELSE '关注' END AS risk_level,
       CONCAT_WS('；',
         IF(fail_cnt >= 1, CONCAT('挂科', fail_cnt, '门'), NULL),
         IF(att_converted >= 8, CONCAT('折算缺勤', att_converted, '次'), NULL),
         IF(avg_score < 60, '均分不及格', NULL)
       ) AS risk_reason,
       '2026-11-11'
FROM edu_dw.dws_student_term
WHERE fail_cnt >= 2 OR att_converted >= 8 OR avg_score < 60;

SELECT risk_level, COUNT(*) cnt FROM edu_dw.ads_student_risk GROUP BY risk_level;


-- =====================================================================
-- 4) ads_teacher_workload —— 教师工作量与教学效果
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_teacher_workload;
CREATE TABLE edu_dw.ads_teacher_workload (
  term_id       INT          NOT NULL,
  teacher_id    BIGINT       NOT NULL,
  teacher_name  VARCHAR(64)  NULL,
  title         VARCHAR(30)  NULL,
  college_name  VARCHAR(100) NULL,
  schedule_cnt  INT          NOT NULL COMMENT '授课班次数',
  student_cnt   INT          NOT NULL COMMENT '学生人次数',
  avg_score     DECIMAL(5,2) NULL,
  fail_rate     DECIMAL(6,4) NULL,
  workload_level VARCHAR(8)  NULL COMMENT '重/中/轻（按学生人次分档）',
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, teacher_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-教师工作量';

INSERT INTO edu_dw.ads_teacher_workload
  (term_id, teacher_id, teacher_name, title, college_name,
   schedule_cnt, student_cnt, avg_score, fail_rate, workload_level, dt)
SELECT term_id, teacher_id, teacher_name, title, college_name,
       schedule_cnt, student_cnt, avg_score, fail_rate,
       CASE WHEN student_cnt >= 200 THEN '重'
            WHEN student_cnt >= 120 THEN '中'
            ELSE '轻' END,
       '2026-11-11'
FROM edu_dw.dws_teacher_term;

SELECT workload_level, COUNT(*) cnt FROM edu_dw.ads_teacher_workload GROUP BY workload_level;


-- =====================================================================
-- 5) ads_attendance_weekly —— 按教学周的到课率趋势（画折线图用）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_attendance_weekly;
CREATE TABLE edu_dw.ads_attendance_weekly (
  term_id       INT          NOT NULL,
  week_no       TINYINT      NOT NULL,
  att_total     INT          NOT NULL,
  present_cnt   INT          NOT NULL,
  late_cnt      INT          NOT NULL,
  early_cnt     INT          NOT NULL,
  leave_cnt     INT          NOT NULL,
  absent_cnt    INT          NOT NULL,
  attend_rate   DECIMAL(6,4) NULL,
  absent_rate   DECIMAL(6,4) NULL,
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, week_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-教学周到课率趋势';

INSERT INTO edu_dw.ads_attendance_weekly
  (term_id, week_no, att_total, present_cnt, late_cnt, early_cnt, leave_cnt, absent_cnt,
   attend_rate, absent_rate, dt)
SELECT term_id, week_no,
       COUNT(*) AS att_total,
       SUM(att_status = 1) AS present_cnt,
       SUM(att_status = 2) AS late_cnt,
       SUM(att_status = 3) AS early_cnt,
       SUM(att_status = 4) AS leave_cnt,
       SUM(att_status = 5) AS absent_cnt,
       ROUND(SUM(att_status = 1) / COUNT(*), 4),
       ROUND(SUM(att_status = 5) / COUNT(*), 4),
       '2026-11-11'
FROM edu_dw.fact_attendance
WHERE is_valid = 1 AND week_no IS NOT NULL
GROUP BY term_id, week_no;

SELECT COUNT(*) AS rows_ FROM edu_dw.ads_attendance_weekly;


-- =====================================================================
-- 6) ads_score_distribution —— 成绩分段分布（直方图用，正考口径，含<60段）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_score_distribution;
CREATE TABLE edu_dw.ads_score_distribution (
  term_id     INT         NOT NULL,
  band_order  TINYINT     NOT NULL,
  band_name   VARCHAR(16) NOT NULL COMMENT '90-100/80-89/70-79/60-69/<60',
  score_cnt   INT         NOT NULL,
  ratio       DECIMAL(6,4) NOT NULL,
  dt          CHAR(10)    NOT NULL,
  PRIMARY KEY (term_id, band_order)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-成绩分段分布';

INSERT INTO edu_dw.ads_score_distribution
  (term_id, band_order, band_name, score_cnt, ratio, dt)
SELECT term_id, band_order, band_name, score_cnt,
       ROUND(score_cnt / SUM(score_cnt) OVER (PARTITION BY term_id), 4), '2026-11-11'
FROM (
  SELECT term_id,
         CASE WHEN first_score >= 90 THEN 1
              WHEN first_score >= 80 THEN 2
              WHEN first_score >= 70 THEN 3
              WHEN first_score >= 60 THEN 4
              ELSE 5 END AS band_order,
         CASE WHEN first_score >= 90 THEN '90-100'
              WHEN first_score >= 80 THEN '80-89'
              WHEN first_score >= 70 THEN '70-79'
              WHEN first_score >= 60 THEN '60-69'
              ELSE '<60' END AS band_name,
         COUNT(*) AS score_cnt
  FROM edu_dw.dwd_score_agg
  WHERE first_score IS NOT NULL
  GROUP BY term_id, band_order, band_name
) t;

SELECT * FROM edu_dw.ads_score_distribution WHERE term_id = 202601 ORDER BY band_order;


-- =====================================================================
-- 7) ads_college_kpi —— 学院横向对比（看板对比图用）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_college_kpi;
CREATE TABLE edu_dw.ads_college_kpi (
  term_id          INT          NOT NULL,
  college_name     VARCHAR(100) NOT NULL,
  class_cnt        INT          NOT NULL,
  student_cnt      INT          NOT NULL,
  avg_score        DECIMAL(5,2) NULL,
  fail_rate        DECIMAL(6,4) NULL,
  avg_attend_rate  DECIMAL(6,4) NULL,
  risk_cnt         INT          NOT NULL,
  risk_rate        DECIMAL(6,4) NULL,
  rank_no          INT          NULL COMMENT '按均分排名',
  dt               CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, college_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-学院KPI对比';

INSERT INTO edu_dw.ads_college_kpi
  (term_id, college_name, class_cnt, student_cnt, avg_score, fail_rate,
   avg_attend_rate, risk_cnt, risk_rate, rank_no, dt)
SELECT term_id, college_name, COUNT(DISTINCT class_id), SUM(student_cnt),
       ROUND(AVG(avg_score), 2),
       ROUND(SUM(fail_rate * student_cnt) / SUM(student_cnt), 4),
       ROUND(AVG(avg_attend_rate), 4),
       SUM(risk_cnt),
       ROUND(SUM(risk_cnt) / SUM(student_cnt), 4),
       RANK() OVER (PARTITION BY term_id ORDER BY AVG(avg_score) DESC),
       '2026-11-11'
FROM edu_dw.dws_class_term
WHERE college_name IS NOT NULL
GROUP BY term_id, college_name;

SELECT term_id, college_name, student_cnt, avg_score, CONCAT(ROUND(fail_rate*100,1),'%') fail_rate, rank_no
FROM edu_dw.ads_college_kpi WHERE term_id = 202601 ORDER BY rank_no LIMIT 5;


-- =====================================================================
-- 8) ads_term_trend —— 多学期趋势（3 个学期 KPI 变化，折线图用）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ads_term_trend;
CREATE TABLE edu_dw.ads_term_trend (
  term_id        INT          NOT NULL,
  term_name      VARCHAR(64)  NULL,
  seq_no         INT          NULL COMMENT '时间顺序',
  student_cnt    INT          NOT NULL,
  avg_score      DECIMAL(5,2) NULL,
  fail_rate      DECIMAL(6,4) NULL,
  attend_rate    DECIMAL(6,4) NULL,
  risk_rate      DECIMAL(6,4) NULL,
  dt             CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ADS-学期趋势';

INSERT INTO edu_dw.ads_term_trend
  (term_id, term_name, seq_no, student_cnt, avg_score, fail_rate, attend_rate, risk_rate, dt)
SELECT term_id, term_name,
       ROW_NUMBER() OVER (ORDER BY term_id),
       student_cnt, avg_score, fail_rate, avg_attend_rate,
       ROUND(risk_student_cnt / NULLIF(student_cnt, 0), 4),
       '2026-11-11'
FROM edu_dw.ads_term_kpi;

SELECT * FROM edu_dw.ads_term_trend ORDER BY seq_no;


-- =====================================================================
-- 验收：ADS 层 8 张表行数
-- =====================================================================
SELECT 'ads_term_kpi' t, COUNT(*) cnt FROM edu_dw.ads_term_kpi
UNION ALL SELECT 'ads_course_fail_rank', COUNT(*) FROM edu_dw.ads_course_fail_rank
UNION ALL SELECT 'ads_student_risk',     COUNT(*) FROM edu_dw.ads_student_risk
UNION ALL SELECT 'ads_teacher_workload', COUNT(*) FROM edu_dw.ads_teacher_workload
UNION ALL SELECT 'ads_attendance_weekly',COUNT(*) FROM edu_dw.ads_attendance_weekly
UNION ALL SELECT 'ads_score_distribution',COUNT(*) FROM edu_dw.ads_score_distribution
UNION ALL SELECT 'ads_college_kpi',       COUNT(*) FROM edu_dw.ads_college_kpi
UNION ALL SELECT 'ads_term_trend',        COUNT(*) FROM edu_dw.ads_term_trend;
