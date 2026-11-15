-- =====================================================================
-- 事实表重灌（修正两处数据分布问题）
--   问题1：50 万选课全落在「前 500 个班次」→ p202501/p202502 各 24 万、
--          p202601 仅 2 万、p202602 为 0 → 分区对比实验没有说服力
--   修正：用 37 与 720 互质的步长，让 1000 个学生各选 500 个**分散**的班次，
--          覆盖全部 720 个班次 → 三个学期各约 16.7 万行
--   问题2：挂科率 35%（72 万分里 15.75 万挂科）→ 真实高校约 5~10%
--   修正：10% 学生落在 40~59 分，其余 60~100
-- 执行：USE edu_online 后整段跑，约 2 分钟
-- =====================================================================
USE edu_online;

TRUNCATE TABLE edu_online.attendance;
TRUNCATE TABLE edu_online.score;
TRUNCATE TABLE edu_online.selection;
UPDATE edu_online.course_schedule SET current_count = 0;

-- ---------------------------------------------------------------------
-- 1) selection：50 万，班次分散到全部 720 个
--    rk = 1 + MOD((n-1)*37, 720)：步长 37 与 720 互质 → 同一学生 500 次无重复
-- ---------------------------------------------------------------------
INSERT INTO edu_online.selection
  (student_id, schedule_id, term_id, select_status, deleted_at, created_at)
SELECT s.student_id, sc.schedule_id, sc.term_id,
       IF(MOD(s.student_id * 17 + sc.schedule_id * 7, 100) < 10, 2, 1),
       '1970-01-01 00:00:00',
       NOW()
FROM (
  SELECT 1 + FLOOR((n - 1) / 500)          AS student_id,
         1 + MOD((n - 1) * 37, 720)        AS rk
  FROM edu_normal.nums WHERE n <= 500000
) s
JOIN (
  SELECT schedule_id, term_id,
         ROW_NUMBER() OVER (ORDER BY schedule_id) AS rk
  FROM edu_online.course_schedule
) sc ON sc.rk = s.rk;

SELECT COUNT(*) AS total, SUM(select_status=1) AS active, SUM(active_flag=1) AS flag1
FROM edu_online.selection;

-- ---------------------------------------------------------------------
-- 2) 回填 current_count
-- ---------------------------------------------------------------------
UPDATE edu_online.course_schedule cs
JOIN (
  SELECT schedule_id, term_id, COUNT(*) AS cnt
  FROM edu_online.selection
  WHERE select_status = 1 AND deleted_at = '1970-01-01 00:00:00'
  GROUP BY schedule_id, term_id
) t ON t.schedule_id = cs.schedule_id AND t.term_id = cs.term_id
SET cs.current_count = t.cnt;

SELECT MIN(current_count) min_cnt, MAX(current_count) max_cnt, ROUND(AVG(current_count),1) avg_cnt
FROM edu_online.course_schedule;

-- ---------------------------------------------------------------------
-- 3) score（正考）：挂科率降到约 10%
-- ---------------------------------------------------------------------
INSERT INTO edu_online.score
  (student_id, schedule_id, exam_type, term_id,
   total_score, score_status, usual_score, final_score,
   is_manual_adjust, rule_version, deleted_at, created_at)
SELECT student_id, schedule_id, 1, term_id,
       CASE WHEN k < 5  THEN NULL                        -- 5% 待录入
            WHEN MOD(k,10) = 5 THEN 40 + MOD(k, 20)      -- 10% 挂科 40~59
            ELSE 60 + MOD(k * 7, 41) END,                -- 其余 60~100
       IF(k < 5, 1, IF(k < 30, 2, 3)),
       CASE WHEN k < 5 THEN NULL ELSE 60 + MOD(k * 11, 41) END,
       CASE WHEN k < 5 THEN NULL ELSE 60 + MOD(k * 13, 41) END,
       0, 'v1-6:4', '1970-01-01 00:00:00', NOW()
FROM (
  SELECT sel.student_id, sel.schedule_id, sel.term_id,
         MOD(sel.student_id * 13 + sel.schedule_id * 29, 100) AS k
  FROM edu_online.selection sel
  WHERE sel.select_status = 1 AND sel.deleted_at = '1970-01-01 00:00:00'
) t;

SELECT COUNT(*) total, SUM(total_score < 60) AS fail_cnt,
       ROUND(SUM(total_score < 60) / COUNT(*), 4) AS fail_rate,
       ROUND(AVG(total_score),2) AS avg_score
FROM edu_online.score WHERE total_score IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4) 补考（给挂科者）
-- ---------------------------------------------------------------------
INSERT INTO edu_online.score
  (student_id, schedule_id, exam_type, term_id,
   total_score, score_status, usual_score, final_score,
   is_manual_adjust, rule_version, deleted_at, created_at)
SELECT student_id, schedule_id, 2, term_id,
       ROUND(60 + MOD(student_id * 7 + schedule_id, 30), 1), 3,
       ROUND(60 + MOD(student_id * 3 + schedule_id, 30), 1),
       ROUND(60 + MOD(student_id * 5 + schedule_id, 30), 1),
       0, 'v1-6:4', '1970-01-01 00:00:00', NOW()
FROM edu_online.score
WHERE exam_type = 1 AND total_score IS NOT NULL AND total_score < 60;

SELECT exam_type, COUNT(*) cnt FROM edu_online.score GROUP BY exam_type;

-- ---------------------------------------------------------------------
-- 5) attendance（100 万，与 selection 一一对应两次课）
-- ---------------------------------------------------------------------
INSERT INTO edu_online.attendance
  (student_id, session_id, session_date, schedule_id, term_id,
   att_status, att_time, late_minutes, early_minutes,
   check_by, check_time, sign_method, deleted_at, created_at)
SELECT student_id, session_id, session_date, schedule_id, term_id,
       att_status,
       TIMESTAMP(session_date, '08:00:00'),
       IF(att_status = 2, 5 + MOD(k, 55), NULL),
       IF(att_status = 3, 5 + MOD(k, 55), NULL),
       IF(MOD(k, 100) < 85, 1 + MOD(k, 400), NULL),
       IF(MOD(k, 100) < 85, TIMESTAMP(session_date, '08:00:00') + INTERVAL 2 HOUR, NULL),
       1 + MOD(k, 3),
       '1970-01-01 00:00:00',
       NOW()
FROM (
  SELECT sel.student_id, cs.session_id, cs.session_date, sel.schedule_id, sel.term_id,
         MOD(sel.student_id * 37 + cs.session_id * 13, 100) AS k,
         CASE
           WHEN MOD(sel.student_id * 37 + cs.session_id * 13, 100) < 85 THEN 1
           WHEN MOD(sel.student_id * 37 + cs.session_id * 13, 100) < 90 THEN 2
           WHEN MOD(sel.student_id * 37 + cs.session_id * 13, 100) < 93 THEN 3
           WHEN MOD(sel.student_id * 37 + cs.session_id * 13, 100) < 96 THEN 4
           ELSE 5
         END AS att_status
  FROM edu_online.selection sel
  JOIN edu_online.course_session cs
    ON cs.schedule_id = sel.schedule_id
   AND cs.term_id     = sel.term_id
   AND cs.session_no IN (1, 2)
) t;

SELECT COUNT(*) total, SUM(att_status=1) ok, SUM(att_status=5) absent,
       SUM(check_time IS NULL) unchecked
FROM edu_online.attendance;

-- ---------------------------------------------------------------------
-- 6) 验收：分区分布是否均衡 + 分区裁剪
-- ---------------------------------------------------------------------
SELECT PARTITION_NAME, TABLE_ROWS
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME='selection' AND PARTITION_NAME IS NOT NULL
ORDER BY PARTITION_ORDINAL_POSITION;

EXPLAIN SELECT COUNT(*) FROM edu_online.selection WHERE term_id = 202601;
