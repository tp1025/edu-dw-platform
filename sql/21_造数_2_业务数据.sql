-- =====================================================================
-- 造数脚本 2/2：班次 → 时段 → 课次 → 选课 → 成绩 → 考勤 → 流水
-- 环境：MySQL 26.10 @ 127.0.0.1:3307
-- 前提：已执行 20_造数_1_工具与维表.sql（有 nums 表 + 8 张维表数据）
--       已执行 15_补字段.sql（attendance/score 字段补齐）
-- 执行顺序：严格按 第 1 段 → 第 8 段，每段后跑验证
-- 预计总耗时：3 ~ 8 分钟（取决于机器）
-- =====================================================================

-- ⚠️ 必须：指定当前数据库，否则 HeidiSQL 会报 1046 No database selected
USE edu_online;


-- =====================================================================
-- 第 1 段：course_schedule（720 个教学班 = 3 学期 × 240）
--   唯一键 uk_course_term_class (term_id, course_id, class_no, deleted_at)
--   生成规则：每个学期 120 门课 × 2 个班次 = 240
--   容量 max_count = 1000：
--     50 万选课会落在「前 500 个班次」上，每个班次 1000 名学生（1000 学生 × 500 班次）
--     若 max_count < 1000，第 5 段回填 current_count 时会违反 ck_cs_count（current<=max）
--     剩余 220 个班次选课人数为 0（可解释为「选课人数不足未开课」，正好是真实业务场景）
-- =====================================================================
INSERT INTO edu_online.course_schedule
  (course_id, teacher_id, class_no, term_id, max_count, current_count, start_time, end_time)
SELECT 1 + (n - 1) % 120,                                  -- course_id 1..120
       1 + (n * 7) % 400,                                  -- teacher_id 1..400
       1 + FLOOR((n - 1) / 120) % 2,                       -- class_no 1,2
       CASE FLOOR((n - 1) / 240)
            WHEN 0 THEN 202501
            WHEN 1 THEN 202502
            ELSE 202601
       END,                                                -- term_id 三个学期
       1000,                                               -- max_count（500 班次 × 1000 人 = 50 万，见下方说明）
       0,                                                  -- current_count 稍后回填
       CASE FLOOR((n - 1) / 240)
            WHEN 0 THEN '2025-02-24 00:00:00'
            WHEN 1 THEN '2025-09-01 00:00:00'
            ELSE '2026-03-02 00:00:00'
       END,
       CASE FLOOR((n - 1) / 240)
            WHEN 0 THEN '2025-06-20 00:00:00'
            WHEN 1 THEN '2025-12-26 00:00:00'
            ELSE '2026-06-26 00:00:00'
       END
FROM edu_normal.nums WHERE n <= 720;

-- 验证：720 行，3 个学期各 240
SELECT term_id, COUNT(*) cnt FROM edu_online.course_schedule GROUP BY term_id;
SELECT COUNT(*) AS total FROM edu_online.course_schedule;


-- =====================================================================
-- 第 2 段：schedule_time（每个班次 2 个时段 = 1440）
--   唯一键 (schedule_id, week, begin_section, deleted_at)
-- =====================================================================
INSERT INTO edu_online.schedule_time (schedule_id, week, begin_section, end_section, classroom_id)
SELECT cs.schedule_id, t.wk, t.b, t.e, 1 + (cs.schedule_id * 3) % 60
FROM edu_online.course_schedule cs
CROSS JOIN (
  SELECT 1 AS wk, 3 AS b, 4 AS e
  UNION ALL
  SELECT 3, 5, 6
) t;

-- 验证：1440 行
SELECT COUNT(*) AS total FROM edu_online.schedule_time;


-- =====================================================================
-- 第 3 段：course_session（每个班次 16 次课 = 11520）
--   唯一键 (term_id, schedule_id, session_no) + (term_id, schedule_id, session_date, start_section)
--   日期：学期开学日 + (k-1)*7 天，每周一次
--   week_day：1=周一 … 7=周日（WEEKDAY() 返回 0=周一，所以要 +1）
-- =====================================================================
INSERT INTO edu_online.course_session
  (term_id, schedule_id, session_no, week_no, session_date, classroom_id, week_day, start_section, end_section)
SELECT cs.term_id, cs.schedule_id, k.n, k.n,
       DATE_ADD(
         CASE cs.term_id
              WHEN 202501 THEN DATE'2025-02-24'
              WHEN 202502 THEN DATE'2025-09-01'
              ELSE             DATE'2026-03-02'
         END,
         INTERVAL (k.n - 1) * 7 DAY
       ),
       1 + (cs.schedule_id * 3) % 60,
       WEEKDAY(
         DATE_ADD(
           CASE cs.term_id
                WHEN 202501 THEN DATE'2025-02-24'
                WHEN 202502 THEN DATE'2025-09-01'
                ELSE             DATE'2026-03-02'
           END,
           INTERVAL (k.n - 1) * 7 DAY
         )
       ) + 1,
       3, 4
FROM edu_online.course_schedule cs
CROSS JOIN (SELECT n FROM edu_normal.nums WHERE n <= 16) k;

-- 验证：11520 行；每个班次 16 次；日期都是周一
SELECT COUNT(*) AS total, COUNT(DISTINCT schedule_id) AS schedules FROM edu_online.course_session;
SELECT session_no, COUNT(*) cnt FROM edu_online.course_session GROUP BY session_no ORDER BY session_no LIMIT 5;
SELECT week_day, COUNT(*) cnt FROM edu_online.course_session GROUP BY week_day;


-- =====================================================================
-- 第 4 段：selection（48 万 = 20000 学生 × 每学期 8 门 × 3 学期）
--   唯一键 (student_id, schedule_id, term_id, active_flag, deleted_at)
--   ⚠️ active_flag 是生成列，不能显式赋值（数据库自动算）
--   生成规则（真实规模）：
--     · 每学期 240 个班次 → 把它分成 8 组，每组 30 个
--     · 第 k 门课从第 k 组里取一个 → 同一学生同学期的 8 门课必然不同班次
--     · rk = 1 + k*30 + MOD(学号*7 + 学期序号*17, 30)  → 落在 1..240
--   埋脏：10% 已退课（select_status=2 → active_flag 自动变 NULL）
-- =====================================================================
INSERT INTO edu_online.selection
  (student_id, schedule_id, term_id, select_status, deleted_at, created_at)
SELECT s.student_id, sc.schedule_id, sc.term_id,
       IF(MOD(s.student_id * 17 + sc.schedule_id * 7, 100) < 10, 2, 1),
       '1970-01-01 00:00:00',
       NOW()
FROM (
  SELECT 1 + FLOOR((n - 1) / 24)          AS student_id,   -- 20000 学生 × 24 条
         FLOOR(MOD(n - 1, 24) / 8)        AS term_seq,     -- 0/1/2 三个学期
         MOD(n - 1, 8)                    AS course_idx    -- 0..7 共 8 门课
  FROM edu_normal.nums WHERE n <= 480000
) s
JOIN (
  SELECT schedule_id, term_id,
         ROW_NUMBER() OVER (PARTITION BY term_id ORDER BY schedule_id) AS rk
  FROM edu_online.course_schedule
) sc
  ON sc.term_id = CASE s.term_seq WHEN 0 THEN 202501 WHEN 1 THEN 202502 ELSE 202601 END
 AND sc.rk = 1 + s.course_idx * 30 + MOD(s.student_id * 7 + s.term_seq * 17, 30);

-- 验证：48 万行；有效约 43.2 万、已退约 4.8 万
SELECT COUNT(*) AS total,
       SUM(select_status = 1) AS active,
       SUM(select_status = 2) AS dropped,
       SUM(active_flag = 1)   AS flag_1,
       SUM(active_flag IS NULL) AS flag_null
FROM edu_online.selection;

-- 验证：人均每学期选课数（应约 8 门）
SELECT ROUND(COUNT(*) / COUNT(DISTINCT student_id || '-' || term_id), 2) AS avg_courses_per_term
FROM edu_online.selection;


-- =====================================================================
-- 第 5 段：回填 course_schedule.current_count
--   只统计「有效选课」（select_status=1 且未软删除）
--   ⚠️ 用 JOIN 一次聚合，不要用相关子查询（720 行 × 每次扫 50 万行 = 极慢）
--   ⚠️ ck_cs_count 约束：current_count <= max_count
-- =====================================================================
UPDATE edu_online.course_schedule cs
JOIN (
  SELECT schedule_id, term_id, COUNT(*) AS cnt
  FROM edu_online.selection
  WHERE select_status = 1
    AND deleted_at = '1970-01-01 00:00:00'
  GROUP BY schedule_id, term_id
) t
  ON t.schedule_id = cs.schedule_id
 AND t.term_id     = cs.term_id
SET cs.current_count = t.cnt;

-- 验证：容量分布（应该都 <= 800）
SELECT MIN(current_count) AS min_cnt, MAX(current_count) AS max_cnt,
       AVG(current_count) AS avg_cnt
FROM edu_online.course_schedule;


-- =====================================================================
-- 第 6 段：score（基于有效选课生成，约 45 万 + 补考）
--   唯一键 (student_id, schedule_id, term_id, exam_type, deleted_at)
--   用确定性伪随机（MOD(学号, 班次)）保证同一条记录里各列互相一致
--   埋脏：5% 待录入（分数全 NULL）
-- =====================================================================
INSERT INTO edu_online.score
  (student_id, schedule_id, exam_type, term_id,
   total_score, score_status, usual_score, final_score,
   is_manual_adjust, rule_version, deleted_at, created_at)
SELECT student_id, schedule_id, 1, term_id,
       IF(k < 5, NULL, ROUND(35 + MOD(k * 7, 66), 1)),
       IF(k < 5, 1, IF(k < 30, 2, 3)),
       IF(k < 5, NULL, ROUND(35 + MOD(k * 11, 66), 1)),
       IF(k < 5, NULL, ROUND(35 + MOD(k * 13, 66), 1)),
       0,
       'v1-6:4',
       '1970-01-01 00:00:00',
       NOW()
FROM (
  SELECT sel.student_id, sel.schedule_id, sel.term_id,
         MOD(sel.student_id * 13 + sel.schedule_id * 29, 100) AS k
  FROM edu_online.selection sel
  WHERE sel.select_status = 1
    AND sel.deleted_at = '1970-01-01 00:00:00'
) t;

-- 验证：约 45 万行；待录入约 2 万；分数分布合理
SELECT COUNT(*) AS total,
       SUM(score_status = 1) AS pending,
       SUM(score_status = 2) AS entered,
       SUM(score_status = 3) AS reviewed,
       SUM(total_score IS NULL) AS null_score
FROM edu_online.score;


-- =====================================================================
-- 第 7 段：补考成绩（给挂科的人补一条 exam_type=2）
--   作用：为「平均分取最高分 / 挂科率取正考」的口径提供真实素材
-- =====================================================================
INSERT INTO edu_online.score
  (student_id, schedule_id, exam_type, term_id,
   total_score, score_status, usual_score, final_score,
   is_manual_adjust, rule_version, deleted_at, created_at)
SELECT student_id, schedule_id, 2, term_id,
       ROUND(60 + MOD(student_id * 7 + schedule_id, 30), 1),   -- 补考 60~89
       3,
       ROUND(60 + MOD(student_id * 3 + schedule_id, 30), 1),
       ROUND(60 + MOD(student_id * 5 + schedule_id, 30), 1),
       0, 'v1-6:4', '1970-01-01 00:00:00', NOW()
FROM edu_online.score
WHERE exam_type = 1 AND total_score IS NOT NULL AND total_score < 60;

-- 验证：补考行数（应等于挂科人数）
SELECT exam_type, COUNT(*) cnt FROM edu_online.score GROUP BY exam_type;


-- =====================================================================
-- 第 8 段：attendance（100 万 = 50 万选课 × 每个 2 次课）
--   唯一键 (term_id, session_id, student_id, deleted_at)
--   只取 session_no IN (1,2,3,4)，所以每个学生每个班次 4 条
--   ⚠️ 已退课的学生也会有考勤 → 这是刻意埋的跨表不一致（DWD 层用 select_status 过滤）
--   状态分布：出勤 85% / 迟到 5% / 早退 3% / 请假 3% / 旷课 4%
-- =====================================================================
INSERT INTO edu_online.attendance
  (student_id, session_id, session_date, schedule_id, term_id,
   att_status, att_time, late_minutes, early_minutes,
   check_by, check_time, sign_method, deleted_at, created_at)
SELECT student_id, session_id, session_date, schedule_id, term_id,
       att_status,
       TIMESTAMP(session_date, '08:00:00'),
       IF(att_status = 2, 5 + MOD(k, 55), NULL),      -- 迟到 5~59 分钟（约一半 >30）
       IF(att_status = 3, 5 + MOD(k, 55), NULL),
       IF(MOD(k, 100) < 85, 1 + MOD(k, 400), NULL),   -- 85% 已核对
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
   AND cs.session_no IN (1, 2, 3, 4)
) t;

-- 验证：100 万行；状态分布；未核对数量
SELECT COUNT(*) AS total,
       SUM(att_status = 1) AS attend_ok,
       SUM(att_status = 2) AS late,
       SUM(att_status = 3) AS early,
       SUM(att_status = 4) AS leave_,
       SUM(att_status = 5) AS absent,
       SUM(check_time IS NULL) AS unchecked
FROM edu_online.attendance;


-- =====================================================================
-- 第 9 段：student_status_change（2000 条学籍异动）
--   注意：转专业/转班时 old_status 与 new_status 相同（都是 1）
-- =====================================================================
INSERT INTO edu_normal.student_status_change
  (student_id, change_type, from_class_id, to_class_id,
   old_status, new_status, change_reason, operator_id, operate_time)
SELECT 1 + MOD(n * 7, 20000),
       1 + MOD(n, 7),
       IF(MOD(n, 7) IN (3, 4), 1 + MOD(n * 3, 400), NULL),          -- 转专业/转班
       IF(MOD(n, 7) IN (3, 4), 1 + MOD(n * 3 + 17, 400), NULL),
       CASE MOD(n, 7) WHEN 0 THEN 1 WHEN 1 THEN 2 ELSE 1 END,       -- 复学从 2 开始
       CASE MOD(n, 7)
            WHEN 0 THEN 2      -- 休学 1→2
            WHEN 1 THEN 1      -- 复学 2→1
            WHEN 2 THEN 3      -- 退学 1→3
            ELSE 1             -- 转专业/转班/保留/恢复：状态不变
       END,
       CONCAT('异动原因-', n),
       1 + MOD(n, 400),
       TIMESTAMP('2025-03-01 09:00:00') + INTERVAL (MOD(n, 300)) DAY
FROM edu_normal.nums WHERE n <= 8000;

-- 验证：2000 行，7 种类型都有
SELECT change_type, COUNT(*) cnt FROM edu_normal.student_status_change GROUP BY change_type ORDER BY change_type;


-- =====================================================================
-- 第 10 段：reward_punish（3000 条奖助奖惩）
--   奖学金/助学金/补助有金额，表彰/处分金额为 NULL
-- =====================================================================
INSERT INTO edu_normal.reward_punish
  (student_id, rp_type, rp_level, amount, rp_title, rp_content,
   rp_date, issue_dept, file_no, operator_id)
SELECT 1 + MOD(n * 11, 20000),
       1 + MOD(n, 5),
       1 + MOD(n, 4),
       IF(MOD(n, 5) < 3, ROUND(500 + MOD(n * 37, 9500), 2), NULL),  -- 前 3 类有金额
       CONCAT(ELT(1 + MOD(n, 5), '奖学金', '助学金', '困难补助', '校级表彰', '纪律处分'), n),
       CONCAT('记录内容说明-', n),
       DATE('2025-01-01') + INTERVAL MOD(n, 330) DAY,
       ELT(1 + MOD(n, 4), '学生工作部', '研究生工作部', '学院学工办', '教务处'),
       CONCAT('DOC-', LPAD(n, 6, '0')),
       1 + MOD(n, 400)
FROM edu_normal.nums WHERE n <= 6000;

-- 验证：3000 行；有金额的约 1800
SELECT COUNT(*) AS total, SUM(amount IS NOT NULL) AS with_amount, ROUND(SUM(amount),2) AS total_amount
FROM edu_normal.reward_punish;


-- =====================================================================
-- 第 11 段：全库规模汇总（这是你简历上要写的数字）
-- =====================================================================
SELECT 'course_schedule' AS tbl, COUNT(*) AS cnt FROM edu_online.course_schedule
UNION ALL SELECT 'schedule_time',   COUNT(*) FROM edu_online.schedule_time
UNION ALL SELECT 'course_session',  COUNT(*) FROM edu_online.course_session
UNION ALL SELECT 'selection',       COUNT(*) FROM edu_online.selection
UNION ALL SELECT 'score',           COUNT(*) FROM edu_online.score
UNION ALL SELECT 'attendance',      COUNT(*) FROM edu_online.attendance
UNION ALL SELECT 'student_status_change', COUNT(*) FROM edu_normal.student_status_change
UNION ALL SELECT 'reward_punish',   COUNT(*) FROM edu_normal.reward_punish;

-- 理想结果：720 / 1440 / 11520 / 480000 / 约 432000 / 1920000 / 8000 / 6000
-- 总行数约 190 万


-- =====================================================================
-- 第 12 段：性能实测（阶段3 的素材，现在先记一笔）
-- =====================================================================
-- ① 分区裁剪：应只扫 p202601
EXPLAIN SELECT COUNT(*) FROM edu_online.selection WHERE term_id = 202601;

-- ② 典型统计：某班次的折算缺勤次数（迟到>30 分钟计 1 次）
SELECT student_id,
       SUM(CASE WHEN att_status = 5 THEN 1
                WHEN att_status = 2 AND late_minutes  > 30 THEN 1
                WHEN att_status = 3 AND early_minutes > 30 THEN 1
                ELSE 0 END) AS absent_times
FROM edu_online.attendance
WHERE term_id = 202601 AND schedule_id = 1
  AND deleted_at = '1970-01-01 00:00:00'
GROUP BY student_id
ORDER BY absent_times DESC
LIMIT 10;

-- ③ 成绩口径：平均分取最高分（正考+补考）
SELECT student_id, MAX(total_score) AS best_score
FROM edu_online.score
WHERE term_id = 202601 AND deleted_at = '1970-01-01 00:00:00'
GROUP BY student_id
ORDER BY best_score DESC
LIMIT 10;
