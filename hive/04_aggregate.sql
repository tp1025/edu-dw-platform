-- =====================================================================
-- Hive 侧聚合对账（与 MySQL DWS 结果比对）
-- 口径与 MySQL 侧保持一致：
--   · 只算正考（exam_type='1'）
--   · 成绩限定 0—100（排除 -5 / 150 / 缺考 等脏数据）
--   · 结果 ROUND 到 2/4 位，避免 DOUBLE 精度差异
-- 注意：Hive 列别名不支持中文，必须用 ASCII 或加反引号
-- =====================================================================
USE edu_dw;

-- ---------------------------------------------------------------------
-- Q1：按学期统计 出分人次 / 挂科人次 / 挂科率 / 均分
--     期望：与 MySQL 完全一致（挂科率约 10.46%）
-- ---------------------------------------------------------------------
SELECT term_id,
       COUNT(*)                                                          AS scored_cnt,
       SUM(CASE WHEN CAST(total_score AS DOUBLE) < 60 THEN 1 ELSE 0 END) AS fail_cnt,
       ROUND(SUM(CASE WHEN CAST(total_score AS DOUBLE) < 60 THEN 1 ELSE 0 END)
             / COUNT(*), 4)                                              AS fail_rate,
       ROUND(AVG(CAST(total_score AS DOUBLE)), 2)                        AS avg_score
FROM ods_score
WHERE dt = '2026-11-15'
  AND exam_type = '1'
  AND CAST(total_score AS DOUBLE) BETWEEN 0 AND 100
GROUP BY term_id
ORDER BY term_id;

-- ---------------------------------------------------------------------
-- Q2：按班级统计均分 Top10（验证 JOIN 能力）
-- ---------------------------------------------------------------------
SELECT c.class_name,
       COUNT(*)                                     AS cnt,
       ROUND(AVG(CAST(s.total_score AS DOUBLE)), 2)  AS avg_score
FROM ods_score   s
JOIN ods_student st ON st.student_id = s.student_id AND st.dt = '2026-11-15'
JOIN ods_class   c  ON c.class_id    = st.class_id  AND c.dt  = '2026-11-15'
WHERE s.dt = '2026-11-15'
  AND s.exam_type = '1'
  AND CAST(s.total_score AS DOUBLE) BETWEEN 0 AND 100
GROUP BY c.class_name
HAVING COUNT(*) > 100
ORDER BY avg_score DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- Q3：分区裁剪对比 —— 带分区条件 vs 不带
-- ---------------------------------------------------------------------
EXPLAIN
SELECT COUNT(*) FROM ods_score WHERE dt = '2026-11-15';

EXPLAIN
SELECT COUNT(*) FROM ods_score;
