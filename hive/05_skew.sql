-- =====================================================================
-- 数据倾斜实验 v2：造真实热点（10 万行同一个 key）
-- 对比：普通 GROUP BY / skewindata 自动两阶段 / 手工加盐两阶段
-- =====================================================================
USE edu_dw;

-- 清空实验分区，避免重复插入
ALTER TABLE ods_score DROP PARTITION (dt='2026-11-16');

-- ---------------------------------------------------------------------
-- 第 1 步：造 20 万行，其中前 10 万行的 schedule_id 全改成 '1'
--   → key='1' 占 10 万行，其余 10 万行分散在约 700 个 key 上
-- ---------------------------------------------------------------------
INSERT INTO TABLE ods_score PARTITION (dt='2026-11-16')
SELECT row_id, score_id, student_id,
       IF(CAST(row_id AS BIGINT) <= 100000, '1', schedule_id) AS schedule_id,
       exam_type, term_id, total_score, score_status, is_manual_adjust,
       rule_version, creator, remark, deleted_at, created_at, updated_at,
       usual_score, final_score, src_table, etl_time
FROM ods_score
WHERE dt = '2026-11-15'
LIMIT 200000;

-- ---------------------------------------------------------------------
-- 第 2 步：验证倾斜（热点 key 一家独大）
-- ---------------------------------------------------------------------
SELECT schedule_id, COUNT(*) AS cnt
FROM ods_score WHERE dt = '2026-11-16'
GROUP BY schedule_id
ORDER BY cnt DESC
LIMIT 5;

SELECT COUNT(*) AS total_rows, COUNT(DISTINCT schedule_id) AS distinct_keys
FROM ods_score WHERE dt = '2026-11-16';

-- ---------------------------------------------------------------------
-- 第 3 步：对照组 —— 普通 GROUP BY
--   热点 key 的 10 万行全压到同一个 reducer
-- ---------------------------------------------------------------------
SELECT schedule_id, COUNT(*) AS cnt
FROM ods_score WHERE dt = '2026-11-16'
GROUP BY schedule_id;

-- ---------------------------------------------------------------------
-- 第 4 步：skewindata 自动两阶段
-- ---------------------------------------------------------------------
SET hive.groupby.skewindata = true;

EXPLAIN
SELECT schedule_id, COUNT(*) AS cnt
FROM ods_score WHERE dt = '2026-11-16'
GROUP BY schedule_id;

SELECT schedule_id, COUNT(*) AS cnt
FROM ods_score WHERE dt = '2026-11-16'
GROUP BY schedule_id;

SET hive.groupby.skewindata = false;

-- ---------------------------------------------------------------------
-- 第 5 步：手工加盐两阶段（结果必须与第 3 步完全一致）
-- ---------------------------------------------------------------------
SELECT schedule_id, SUM(cnt) AS cnt
FROM (
  SELECT schedule_id,
         PMOD(HASH(student_id), 10) AS salt,
         COUNT(*)                   AS cnt
  FROM ods_score
  WHERE dt = '2026-11-16'
  GROUP BY schedule_id, PMOD(HASH(student_id), 10)
) t
GROUP BY schedule_id
ORDER BY cnt DESC
LIMIT 5;
