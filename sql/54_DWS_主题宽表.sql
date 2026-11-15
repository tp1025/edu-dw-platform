-- =====================================================================
-- DWS 层（重构版）：主题宽表
--
-- 【上一版踩的两个坑，这版修正】
--   坑1 性能：用相关子查询取最高分 → 45 万次索引查找 → 9 分钟
--            改为：先建 dwd_score_agg 预聚合，再 JOIN → 预计 30 秒内
--   坑2 口径：用「最高分」算挂科率 → 补考通过的人不算挂科 → 挂科率恒为 0
--            改为：均分用最高分口径（best_score），挂科用正考口径（first_score）
--
-- 【口径定义】（写进指标文档，面试会问）
--   · avg_score        ：同一班次多次考试取【最高分】——学生权益口径
--   · fail_cnt/fail_rate：按【正考】< 60 判定 —— 教学质量评估口径
--   · 折算缺勤          ：旷课(5) + 迟到且>30min + 早退且>30min；请假/待签到不计
--   · 出勤率            ：出勤(1) / 有效考勤记录数
--   · 只统计 is_valid=1 的事实行
-- =====================================================================
USE edu_dw;

-- ---------------------------------------------------------------------
-- 0) 新增索引：让 DWS 聚合走索引（term_id + schedule_id）
-- ---------------------------------------------------------------------
SET @idx_exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                    WHERE TABLE_SCHEMA='edu_dw' AND TABLE_NAME='fact_attendance'
                      AND INDEX_NAME='idx_term_schedule');
SET @sql := IF(@idx_exists = 0,
  'ALTER TABLE edu_dw.fact_attendance ADD KEY idx_term_schedule (term_id, schedule_id)',
  'SELECT ''index exists'' AS msg');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;

SET @idx_exists2 := (SELECT COUNT(*) FROM information_schema.STATISTICS
                     WHERE TABLE_SCHEMA='edu_dw' AND TABLE_NAME='fact_score'
                       AND INDEX_NAME='idx_term_stu_sch');
SET @sql2 := IF(@idx_exists2 = 0,
  'ALTER TABLE edu_dw.fact_score ADD KEY idx_term_stu_sch (term_id, student_id, schedule_id)',
  'SELECT ''index exists'' AS msg');
PREPARE s2 FROM @sql2; EXECUTE s2; DEALLOCATE PREPARE s2;


-- ---------------------------------------------------------------------
-- 1) dwd_score_agg：一次考试多条成绩 → 学生×班次 一行
--    （这张表本身也是 DWD 层的合法产物：成绩宽表）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dwd_score_agg;
CREATE TABLE edu_dw.dwd_score_agg (
  term_id     INT          NOT NULL,
  student_id  BIGINT       NOT NULL,
  schedule_id BIGINT       NOT NULL,
  first_score DECIMAL(5,2) NULL COMMENT '正考成绩（教学评估口径）',
  best_score  DECIMAL(5,2) NULL COMMENT '最高分（含补考缓考，学生权益口径）',
  exam_cnt    TINYINT      NOT NULL DEFAULT 0 COMMENT '考试次数',
  makeup_pass TINYINT      NOT NULL DEFAULT 0 COMMENT '正考挂科但补考通过',
  dt          CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, student_id, schedule_id),
  KEY idx_schedule (schedule_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='DWD-成绩宽表（学生×班次）';

INSERT INTO edu_dw.dwd_score_agg
  (term_id, student_id, schedule_id, first_score, best_score, exam_cnt, makeup_pass, dt)
SELECT term_id, student_id, schedule_id,
       MAX(CASE WHEN exam_type = 1 THEN total_score END)  AS first_score,
       MAX(total_score)                                   AS best_score,
       COUNT(*)                                           AS exam_cnt,
       CASE WHEN MAX(CASE WHEN exam_type = 1 THEN total_score END) < 60
             AND MAX(total_score) >= 60 THEN 1 ELSE 0 END AS makeup_pass,
       '2026-11-10'
FROM edu_dw.fact_score
WHERE is_valid = 1 AND total_score IS NOT NULL
GROUP BY term_id, student_id, schedule_id;

SELECT COUNT(*) AS score_agg_rows,
       SUM(first_score IS NOT NULL) AS has_first,
       SUM(first_score < 60)        AS first_fail,
       SUM(makeup_pass)             AS makeup_pass_cnt
FROM edu_dw.dwd_score_agg;


-- ---------------------------------------------------------------------
-- 2) 出勤预聚合：按 学期 + 班次
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.tmp_att_schedule;
CREATE TABLE edu_dw.tmp_att_schedule (
  term_id     INT NOT NULL,
  schedule_id BIGINT NOT NULL,
  att_total   INT NOT NULL,
  att_present INT NOT NULL,
  att_converted INT NOT NULL,
  PRIMARY KEY (term_id, schedule_id)
) ENGINE=InnoDB;

INSERT INTO edu_dw.tmp_att_schedule (term_id, schedule_id, att_total, att_present, att_converted)
SELECT term_id, schedule_id, COUNT(*), SUM(att_status = 1),
       SUM(CASE WHEN att_status = 5 THEN 1
                WHEN att_status = 2 AND late_minutes  > 30 THEN 1
                WHEN att_status = 3 AND early_minutes > 30 THEN 1
                ELSE 0 END)
FROM edu_dw.fact_attendance
WHERE is_valid = 1
GROUP BY term_id, schedule_id;


-- ---------------------------------------------------------------------
-- 3) dws_student_term —— 学生 × 学期
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dws_student_term;
CREATE TABLE edu_dw.dws_student_term (
  term_id        INT          NOT NULL,
  student_id     BIGINT       NOT NULL,
  student_no     VARCHAR(32)  NULL,
  student_name   VARCHAR(64)  NULL,
  class_id       INT          NULL,
  class_name     VARCHAR(64)  NULL,
  major_name     VARCHAR(100) NULL,
  college_name   VARCHAR(100) NULL,
  select_cnt     INT          NOT NULL DEFAULT 0,
  credit_sum     DECIMAL(6,1) NOT NULL DEFAULT 0,
  scored_cnt     INT          NOT NULL DEFAULT 0 COMMENT '已出分门数',
  avg_score      DECIMAL(5,2) NULL COMMENT '均分（最高分口径）',
  avg_first      DECIMAL(5,2) NULL COMMENT '均分（正考口径）',
  max_score      DECIMAL(5,2) NULL,
  min_score      DECIMAL(5,2) NULL,
  fail_cnt       INT          NOT NULL DEFAULT 0 COMMENT '正考挂科门数',
  makeup_pass    INT          NOT NULL DEFAULT 0 COMMENT '补考通过门数',
  pass_rate      DECIMAL(6,4) NULL COMMENT '正考通过率',
  att_total      INT          NOT NULL DEFAULT 0,
  att_present    INT          NOT NULL DEFAULT 0,
  att_late       INT          NOT NULL DEFAULT 0,
  att_early      INT          NOT NULL DEFAULT 0,
  att_leave      INT          NOT NULL DEFAULT 0,
  att_absent     INT          NOT NULL DEFAULT 0,
  att_converted  INT          NOT NULL DEFAULT 0 COMMENT '折算缺勤次数',
  attend_rate    DECIMAL(6,4) NULL,
  att_pass       TINYINT      NULL COMMENT '折算缺勤<=3 合格',
  dt             CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, student_id),
  KEY idx_class (term_id, class_id),
  KEY idx_college (term_id, college_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='DWS-学生学期汇总';

INSERT INTO edu_dw.dws_student_term
  (term_id, student_id, student_no, student_name, class_id, class_name, major_name, college_name,
   select_cnt, credit_sum, scored_cnt, avg_score, avg_first, max_score, min_score,
   fail_cnt, makeup_pass, pass_rate,
   att_total, att_present, att_late, att_early, att_leave, att_absent, att_converted,
   attend_rate, att_pass, dt)
WITH sel AS (
  SELECT f.term_id, f.student_id, f.schedule_id, sch.credit
  FROM edu_dw.fact_selection f
  JOIN edu_dw.dim_schedule sch ON sch.schedule_id = f.schedule_id
  WHERE f.is_valid = 1
),
sel_sc AS (
  SELECT s.term_id, s.student_id, s.credit, sc.first_score, sc.best_score, sc.makeup_pass
  FROM sel s
  LEFT JOIN edu_dw.dwd_score_agg sc
         ON sc.term_id = s.term_id AND sc.student_id = s.student_id AND sc.schedule_id = s.schedule_id
),
stu_agg AS (
  SELECT term_id, student_id,
         COUNT(*) AS select_cnt,
         ROUND(SUM(credit), 1) AS credit_sum,
         COUNT(best_score)  AS scored_cnt,
         ROUND(AVG(best_score), 2)  AS avg_score,
         ROUND(AVG(first_score), 2) AS avg_first,
         MAX(best_score) AS max_score,
         MIN(best_score) AS min_score,
         SUM(CASE WHEN first_score < 60 THEN 1 ELSE 0 END) AS fail_cnt,
         SUM(makeup_pass) AS makeup_pass
  FROM sel_sc GROUP BY term_id, student_id
),
att_agg AS (
  SELECT term_id, student_id,
         COUNT(*) att_total, SUM(att_status=1) att_present,
         SUM(att_status=2) att_late, SUM(att_status=3) att_early,
         SUM(att_status=4) att_leave, SUM(att_status=5) att_absent,
         SUM(CASE WHEN att_status = 5 THEN 1
                  WHEN att_status = 2 AND late_minutes  > 30 THEN 1
                  WHEN att_status = 3 AND early_minutes > 30 THEN 1
                  ELSE 0 END) att_converted
  FROM edu_dw.fact_attendance
  WHERE is_valid = 1
  GROUP BY term_id, student_id
)
SELECT a.term_id, a.student_id, ds.student_no, ds.student_name,
       ds.class_id, ds.class_name, ds.major_name, ds.college_name,
       a.select_cnt, a.credit_sum, a.scored_cnt, a.avg_score, a.avg_first,
       a.max_score, a.min_score, a.fail_cnt, a.makeup_pass,
       ROUND(1 - a.fail_cnt / NULLIF(a.scored_cnt, 0), 4) AS pass_rate,
       IFNULL(t.att_total,0), IFNULL(t.att_present,0), IFNULL(t.att_late,0),
       IFNULL(t.att_early,0), IFNULL(t.att_leave,0), IFNULL(t.att_absent,0),
       IFNULL(t.att_converted,0),
       ROUND(IFNULL(t.att_present,0) / NULLIF(t.att_total,0), 4) AS attend_rate,
       CASE WHEN IFNULL(t.att_converted,0) <= 3 THEN 1 ELSE 0 END AS att_pass,
       '2026-11-10'
FROM stu_agg a
LEFT JOIN att_agg t ON t.term_id=a.term_id AND t.student_id=a.student_id
LEFT JOIN edu_dw.dim_student ds ON ds.student_id=a.student_id;

SELECT COUNT(*) rows_, ROUND(AVG(avg_score),2) avg_of_avg,
       ROUND(AVG(fail_cnt),2) avg_fail, ROUND(AVG(attend_rate),4) avg_attend,
       SUM(fail_cnt) total_fail
FROM edu_dw.dws_student_term;


-- ---------------------------------------------------------------------
-- 4) dws_course_term —— 课程 × 学期
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dws_course_term;
CREATE TABLE edu_dw.dws_course_term (
  term_id        INT          NOT NULL,
  course_id      INT          NOT NULL,
  course_code    VARCHAR(32)  NULL,
  course_name    VARCHAR(100) NULL,
  course_type_name VARCHAR(16) NULL,
  credit         DECIMAL(3,1) NULL,
  select_cnt     INT          NOT NULL DEFAULT 0,
  scored_cnt     INT          NOT NULL DEFAULT 0,
  avg_score      DECIMAL(5,2) NULL,
  fail_cnt       INT          NOT NULL DEFAULT 0,
  fail_rate      DECIMAL(6,4) NULL,
  excellent_cnt  INT          NOT NULL DEFAULT 0 COMMENT '>=90',
  excellent_rate DECIMAL(6,4) NULL,
  att_total      INT          NOT NULL DEFAULT 0,
  att_present    INT          NOT NULL DEFAULT 0,
  attend_rate    DECIMAL(6,4) NULL COMMENT '课程出勤率（按班次考勤汇总）',
  dt             CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, course_id),
  KEY idx_course (course_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='DWS-课程学期汇总';

INSERT INTO edu_dw.dws_course_term
  (term_id, course_id, course_code, course_name, course_type_name, credit,
   select_cnt, scored_cnt, avg_score, fail_cnt, fail_rate, excellent_cnt, excellent_rate,
   att_total, att_present, attend_rate, dt)
WITH base AS (
  SELECT f.term_id, f.course_id, f.schedule_id, sc.best_score, sc.first_score
  FROM edu_dw.fact_selection f
  LEFT JOIN edu_dw.dwd_score_agg sc
         ON sc.term_id=f.term_id AND sc.student_id=f.student_id AND sc.schedule_id=f.schedule_id
  WHERE f.is_valid = 1
),
crs AS (
  SELECT term_id, course_id,
         COUNT(*) AS select_cnt,
         COUNT(best_score) AS scored_cnt,
         ROUND(AVG(best_score), 2) AS avg_score,
         SUM(CASE WHEN first_score < 60 THEN 1 ELSE 0 END) AS fail_cnt,
         SUM(CASE WHEN best_score >= 90 THEN 1 ELSE 0 END) AS excellent_cnt
  FROM base GROUP BY term_id, course_id
),
crs_att AS (   -- 按课程汇总考勤：班次 → 课程
  SELECT sch.course_id, t.term_id, SUM(t.att_total) att_total, SUM(t.att_present) att_present
  FROM edu_dw.tmp_att_schedule t
  JOIN edu_dw.dim_schedule sch ON sch.schedule_id = t.schedule_id
  GROUP BY sch.course_id, t.term_id
)
SELECT c.term_id, c.course_id, dc.course_code, dc.course_name, dc.course_type_name, dc.credit,
       c.select_cnt, c.scored_cnt, c.avg_score, c.fail_cnt,
       ROUND(c.fail_cnt / NULLIF(c.scored_cnt,0), 4) AS fail_rate,
       c.excellent_cnt,
       ROUND(c.excellent_cnt / NULLIF(c.scored_cnt,0), 4) AS excellent_rate,
       IFNULL(ca.att_total,0), IFNULL(ca.att_present,0),
       ROUND(IFNULL(ca.att_present,0) / NULLIF(ca.att_total,0), 4) AS attend_rate,
       '2026-11-10'
FROM crs c
JOIN edu_dw.dim_course dc ON dc.course_id = c.course_id
LEFT JOIN crs_att ca ON ca.term_id = c.term_id AND ca.course_id = c.course_id;

SELECT COUNT(*) rows_, ROUND(AVG(avg_score),2) avg_s,
       ROUND(AVG(fail_rate),4) avg_fail_rate, ROUND(AVG(attend_rate),4) avg_attend
FROM edu_dw.dws_course_term;


-- ---------------------------------------------------------------------
-- 5) dws_class_term —— 班级 × 学期
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dws_class_term;
CREATE TABLE edu_dw.dws_class_term (
  term_id       INT          NOT NULL,
  class_id      INT          NOT NULL,
  class_name    VARCHAR(64)  NULL,
  major_name    VARCHAR(100) NULL,
  college_name  VARCHAR(100) NULL,
  enroll_year   SMALLINT     NULL,
  student_cnt   INT          NOT NULL DEFAULT 0,
  avg_select    DECIMAL(6,2) NULL,
  avg_score     DECIMAL(5,2) NULL,
  fail_rate     DECIMAL(6,4) NULL,
  avg_attend_rate DECIMAL(6,4) NULL,
  risk_cnt      INT          NOT NULL DEFAULT 0 COMMENT '挂科>=2 或 折算缺勤>3',
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, class_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='DWS-班级学期汇总';

INSERT INTO edu_dw.dws_class_term
  (term_id, class_id, class_name, major_name, college_name, enroll_year,
   student_cnt, avg_select, avg_score, fail_rate, avg_attend_rate, risk_cnt, dt)
SELECT s.term_id, s.class_id, MAX(s.class_name), MAX(s.major_name), MAX(s.college_name),
       MAX(cl.enroll_year),
       COUNT(*), ROUND(AVG(s.select_cnt),2), ROUND(AVG(s.avg_score),2),
       ROUND(SUM(s.fail_cnt)/NULLIF(SUM(s.scored_cnt),0),4),
       ROUND(AVG(s.attend_rate),4),
       SUM(CASE WHEN s.fail_cnt >= 2 OR s.att_converted > 3 THEN 1 ELSE 0 END),
       '2026-11-10'
FROM edu_dw.dws_student_term s
LEFT JOIN edu_dw.dim_class cl ON cl.class_id = s.class_id
GROUP BY s.term_id, s.class_id;

SELECT COUNT(*) rows_ FROM edu_dw.dws_class_term;


-- ---------------------------------------------------------------------
-- 6) dws_teacher_term —— 教师 × 学期
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dws_teacher_term;
CREATE TABLE edu_dw.dws_teacher_term (
  term_id       INT          NOT NULL,
  teacher_id    BIGINT       NOT NULL,
  teacher_name  VARCHAR(64)  NULL,
  title         VARCHAR(30)  NULL,
  college_name  VARCHAR(100) NULL,
  schedule_cnt  INT          NOT NULL DEFAULT 0,
  student_cnt   INT          NOT NULL DEFAULT 0,
  avg_score     DECIMAL(5,2) NULL,
  fail_rate     DECIMAL(6,4) NULL,
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (term_id, teacher_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='DWS-教师学期汇总';

INSERT INTO edu_dw.dws_teacher_term
  (term_id, teacher_id, teacher_name, title, college_name,
   schedule_cnt, student_cnt, avg_score, fail_rate, dt)
SELECT f.term_id, f.teacher_id, MAX(dt2.teacher_name), MAX(dt2.title), MAX(dt2.college_name),
       COUNT(DISTINCT f.schedule_id), COUNT(*),
       ROUND(AVG(sc.best_score),2),
       ROUND(SUM(CASE WHEN sc.first_score < 60 THEN 1 ELSE 0 END)/NULLIF(COUNT(sc.best_score),0),4),
       '2026-11-10'
FROM edu_dw.fact_selection f
LEFT JOIN edu_dw.dwd_score_agg sc
       ON sc.term_id=f.term_id AND sc.student_id=f.student_id AND sc.schedule_id=f.schedule_id
LEFT JOIN edu_dw.dim_teacher dt2 ON dt2.teacher_id = f.teacher_id
WHERE f.is_valid = 1
GROUP BY f.term_id, f.teacher_id;

SELECT COUNT(*) rows_ FROM edu_dw.dws_teacher_term;

-- 清理临时表
DROP TABLE IF EXISTS edu_dw.tmp_att_schedule;
