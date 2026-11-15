-- =====================================================================
-- DWD 层（四）：学生维度拉链表 dim_student_zip（SCD2）
--   用途：支持「任意历史时点」回溯学生的学籍状态 / 班级
--   输入：ods_student（当前快照）+ ods_student_status_change（异动流水）
--   规则：
--     · 区间为「左闭右开」：[start_date, end_date)
--     · 当前有效段 end_date = 9999-12-31，is_current = 1
--     · 全量重建模式 → 迟到数据自动归位（无需手工"拉链回插"）
-- =====================================================================
USE edu_dw;

DROP TABLE IF EXISTS edu_dw.dim_student_zip;
CREATE TABLE edu_dw.dim_student_zip (
  student_sk    BIGINT       NOT NULL AUTO_INCREMENT COMMENT '拉链代理键（一段一行）',
  student_id    BIGINT       NOT NULL COMMENT '学生业务键（一个学生多行）',
  student_no    VARCHAR(32)  NULL,
  student_name  VARCHAR(64)  NULL COMMENT '已 TRIM',
  class_id      INT          NULL,
  class_name    VARCHAR(64)  NULL,
  gender        TINYINT      NULL,
  gender_name   VARCHAR(8)   NULL,
  student_status TINYINT     NOT NULL COMMENT '本段的学籍状态：1正常/2休学/3退学',
  status_name   VARCHAR(16)  NULL,
  start_date    DATE         NOT NULL COMMENT '本段生效日（含）',
  end_date      DATE         NOT NULL COMMENT '本段失效日（不含）；9999-12-31=当前',
  is_current    TINYINT      NOT NULL DEFAULT 0 COMMENT '1=当前有效段',
  change_type   TINYINT      NULL COMMENT '触发本段的异动类型（首次建档为 NULL）',
  change_reason VARCHAR(512) NULL,
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (student_sk),
  KEY idx_stu     (student_id, start_date),
  KEY idx_current (is_current),
  KEY idx_range   (start_date, end_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='拉链表-学生学籍历史（SCD2）';

INSERT INTO edu_dw.dim_student_zip
  (student_id, student_no, student_name, class_id, class_name, gender, gender_name,
   student_status, status_name, start_date, end_date, is_current,
   change_type, change_reason, dt)
WITH base AS (          -- ① 初始段：入学建档，状态=正常，班级=当前班级
  SELECT CAST(s.student_id AS UNSIGNED) AS student_id,
         TRIM(s.student_no)   AS student_no,
         TRIM(s.student_name) AS student_name,
         CAST(s.class_id AS UNSIGNED) AS class_id,
         CAST(s.gender   AS UNSIGNED) AS gender,
         DATE(CONCAT(cl.enroll_year, '-09-01')) AS eff_date,
         1 AS status_val,
         NULL AS change_type,
         '入学建档' AS reason,
         0 AS evt_order
  FROM edu_dw.ods_student s
  LEFT JOIN edu_dw.dim_class cl ON cl.class_id = CAST(s.class_id AS UNSIGNED)
  WHERE CAST(s.student_id AS UNSIGNED) > 0
    AND s.deleted_at = '1970-01-01 00:00:00'
),
chg AS (                -- ② 异动事件流（只取有效、按时间排序）
  SELECT CAST(student_id AS UNSIGNED) AS student_id,
         DATE(operate_time) AS eff_date,
         CAST(new_status  AS UNSIGNED) AS status_val,
         CAST(change_type AS UNSIGNED) AS change_type,
         COALESCE(CAST(to_class_id AS UNSIGNED), CAST(from_class_id AS UNSIGNED)) AS new_class_id,
         change_reason AS reason,
         ROW_NUMBER() OVER (PARTITION BY student_id
                            ORDER BY operate_time, id) AS evt_order   -- id 按字符串排（可能是 'X1' 这类脏ID）
  FROM edu_dw.ods_student_status_change
  WHERE deleted_at = '1970-01-01 00:00:00'
    AND student_id IS NOT NULL
),
events AS (             -- ③ 合并事件：初始段 + 异动
  SELECT b.student_id, b.student_no, b.student_name, b.class_id, b.gender,
         b.eff_date, b.status_val, b.change_type, b.reason, b.evt_order
  FROM base b
  UNION ALL
  SELECT c.student_id, NULL, NULL, c.new_class_id, NULL,
         c.eff_date, c.status_val, c.change_type, c.reason, c.evt_order
  FROM chg c
),
chain AS (              -- ④ 闭链：下一段的开始日 = 本段的失效日
  SELECT e.*,
         LEAD(eff_date) OVER (PARTITION BY student_id ORDER BY eff_date, evt_order) AS next_date,
         FIRST_VALUE(student_no)   OVER (PARTITION BY student_id ORDER BY evt_order) AS first_no,
         FIRST_VALUE(student_name) OVER (PARTITION BY student_id ORDER BY evt_order) AS first_name,
         FIRST_VALUE(gender)       OVER (PARTITION BY student_id ORDER BY evt_order) AS first_gender,
         FIRST_VALUE(class_id)     OVER (PARTITION BY student_id ORDER BY evt_order) AS first_class_id
  FROM events e
)
SELECT c.student_id,
       COALESCE(c.student_no, c.first_no)     AS student_no,
       COALESCE(c.student_name, c.first_name) AS student_name,
       COALESCE(c.class_id, c.first_class_id) AS class_id,
       cl.class_name,
       COALESCE(c.gender, c.first_gender)     AS gender,
       gd.dict_label                          AS gender_name,
       c.status_val,
       sd.dict_label                          AS status_name,
       c.eff_date                             AS start_date,
       IFNULL(c.next_date, DATE'9999-12-31')  AS end_date,
       IF(c.next_date IS NULL, 1, 0)          AS is_current,
       c.change_type,
       c.reason,
       '2026-11-10'
FROM chain c
LEFT JOIN edu_dw.dim_class cl
       ON cl.class_id = COALESCE(c.class_id, c.first_class_id)   -- 用兜底后的班级关联
LEFT JOIN edu_dw.ods_sys_dict gd
       ON gd.dict_type = 'sex' AND gd.dict_value = CAST(COALESCE(c.gender, c.first_gender) AS CHAR)
LEFT JOIN edu_dw.ods_sys_dict sd
       ON sd.dict_type = 'student_status' AND sd.dict_value = CAST(c.status_val AS CHAR)
ORDER BY c.student_id, c.eff_date;

-- =====================================================================
-- 验收 1：规模 —— 学生数 / 总段数 / 当前段数
-- =====================================================================
SELECT COUNT(*) AS total_segments,
       COUNT(DISTINCT student_id) AS students,
       SUM(is_current) AS current_segments,
       ROUND(COUNT(*) / COUNT(DISTINCT student_id), 2) AS avg_segments_per_student
FROM edu_dw.dim_student_zip;

-- =====================================================================
-- 验收 2：段数分布（有多少学生经历了 1 段 / 2 段 / 3 段以上）
-- =====================================================================
SELECT seg_cnt AS 段数, COUNT(*) AS 学生数 FROM (
  SELECT student_id, COUNT(*) AS seg_cnt FROM edu_dw.dim_student_zip GROUP BY student_id
) t GROUP BY seg_cnt ORDER BY seg_cnt;

-- =====================================================================
-- 验收 3：链的完整性 —— 同一学生相邻段必须「无重叠、无空洞」
--   判定：按 start_date 排序，上一段的 end_date 必须等于下一段的 start_date
-- =====================================================================
SELECT COUNT(*) AS broken_links FROM (
  SELECT student_id, end_date,
         LEAD(start_date) OVER (PARTITION BY student_id ORDER BY start_date) AS next_start
  FROM edu_dw.dim_student_zip
) t
WHERE next_start IS NOT NULL AND end_date <> next_start;
-- 期望：0

-- =====================================================================
-- 验收 4：随便挑一个有异动的学生，看他的完整时间线
-- =====================================================================
SELECT student_id, student_no, student_name, class_name, status_name,
       start_date, end_date, is_current, change_type, change_reason
FROM edu_dw.dim_student_zip
WHERE student_id = (
  SELECT student_id FROM edu_dw.dim_student_zip
  GROUP BY student_id HAVING COUNT(*) >= 3 LIMIT 1
)
ORDER BY start_date;

-- =====================================================================
-- 验收 5【核心能力】：查「历史某一天」的状态 —— 这是拉链表存在的意义
--   示例：2025-06-01 那天，每个学籍状态有多少人
-- =====================================================================
SELECT status_name, COUNT(*) AS students
FROM edu_dw.dim_student_zip
WHERE start_date <= '2025-06-01' AND end_date > '2025-06-01'
GROUP BY status_name;

-- 对比：当前状态分布（应该和上面不同，说明历史确实被保留了）
SELECT status_name, COUNT(*) AS students
FROM edu_dw.dim_student_zip WHERE is_current = 1 GROUP BY status_name;
