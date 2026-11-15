-- =====================================================================
-- 索引优化：3 条真实慢查询（从 mysql.slow_log 捞出来的）
-- 环境：MySQL 26.10 ｜ 数据：fact_attendance 192 万行
-- 用法：整段执行，看每步的 EXPLAIN / EXPLAIN ANALYZE 输出
-- =====================================================================
USE edu_dw;


-- #####################################################################
-- Q1：函数套在索引列上 → 索引失效
--     慢查询日志记录：1.667 秒 / 扫描 1,920,000 行 / 返回 1 行
-- #####################################################################

-- ---------- 优化前：CAST 让 idx_student 完全失效 ----------
EXPLAIN
SELECT COUNT(*) FROM edu_dw.fact_attendance WHERE CAST(student_id AS CHAR) = '12345';

EXPLAIN ANALYZE
SELECT COUNT(*) FROM edu_dw.fact_attendance WHERE CAST(student_id AS CHAR) = '12345';

-- ---------- 优化后：类型一致，直接走等值索引 ----------
EXPLAIN
SELECT COUNT(*) FROM edu_dw.fact_attendance WHERE student_id = 12345;

EXPLAIN ANALYZE
SELECT COUNT(*) FROM edu_dw.fact_attendance WHERE student_id = 12345;


-- #####################################################################
-- Q2：深分页 LIMIT offset, size
--     慢查询日志记录：0.717 秒 / 扫描 1,500,020 行 / 返回 20 行
--     三种写法对比：原始 / 延迟关联 / 游标分页
-- #####################################################################

-- ---------- 原始写法 ----------
EXPLAIN ANALYZE
SELECT attendance_sk, att_status
FROM edu_dw.fact_attendance
ORDER BY attendance_sk
LIMIT 1500000, 20;

-- ---------- 方案 A：延迟关联（先用覆盖索引拿主键，再回表取 20 行）----------
-- 预期：回表次数降到 20，但**仍要扫 150 万索引项** → rows_examined 不会明显下降
EXPLAIN ANALYZE
SELECT a.attendance_sk, a.att_status
FROM edu_dw.fact_attendance a
JOIN (
  SELECT attendance_sk
  FROM edu_dw.fact_attendance
  ORDER BY attendance_sk
  LIMIT 1500000, 20
) t ON t.attendance_sk = a.attendance_sk;

-- ---------- 方案 B：游标分页（记上一页最后一条，直接定位）----------
-- 上一页最后一条是 attendance_sk = 1500000 → 下一页从 > 1500000 开始
-- 预期：扫描 20 行，耗时毫秒级
EXPLAIN ANALYZE
SELECT attendance_sk, att_status
FROM edu_dw.fact_attendance
WHERE attendance_sk > 1500000
ORDER BY attendance_sk
LIMIT 20;


-- #####################################################################
-- Q3：分组聚合缺覆盖索引
--     慢查询日志记录：2.706 秒 / 扫描 640,000 行 / 返回 20 行
--     索引规则：等值条件列在前，分组列在后（顺序与 GROUP BY 一致）
-- #####################################################################

-- ---------- 优化前：只能用到 term_id（分区裁剪），week_no/att_status 要回表 ----------
EXPLAIN
SELECT week_no, att_status, COUNT(*) AS cnt
FROM edu_dw.fact_attendance
WHERE term_id = 202601
GROUP BY week_no, att_status;

-- ---------- 建覆盖索引 ----------
ALTER TABLE edu_dw.fact_attendance
  ADD KEY idx_term_week_status (term_id, week_no, att_status);

-- 加完必须更新统计信息
ANALYZE TABLE edu_dw.fact_attendance;

-- ---------- 优化后：Using index（索引覆盖扫描，不回表，无临时表）----------
EXPLAIN
SELECT week_no, att_status, COUNT(*) AS cnt
FROM edu_dw.fact_attendance
WHERE term_id = 202601
GROUP BY week_no, att_status;

EXPLAIN ANALYZE
SELECT week_no, att_status, COUNT(*) AS cnt
FROM edu_dw.fact_attendance
WHERE term_id = 202601
GROUP BY week_no, att_status;


-- #####################################################################
-- 汇总验证：从慢日志看优化效果（快于 0.2 秒的查询不会进慢日志）
-- #####################################################################
SELECT
  DATE_FORMAT(start_time,'%H:%i:%s') AS 执行时间,
  query_time AS 耗时,
  rows_examined AS 扫描行数,
  rows_sent AS 返回行数,
  LEFT(sql_text, 70) AS SQL片段
FROM mysql.slow_log
WHERE db = 'edu_dw'
ORDER BY start_time DESC
LIMIT 15;
