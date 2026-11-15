-- =====================================================================
-- DWD 层（二）：事实表 3 张
--   清洗顺序（重要）：① 类型转换 → ② 修外键 → ③ 去重 → ④ 打有效性标记
--   口径（已和用户确认）：
--     · 业务重复选课：保留最新（updated_at DESC, selection_id DESC）
--     · 脏外键：改指向 -1「未知班次」，标记 is_valid=0
--     · DWD 全部保留明细，用 is_valid / invalid_reason 标记，不在本层删除
-- =====================================================================
USE edu_dw;


-- =====================================================================
-- 1) fact_selection（选课事实）
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.fact_selection;
CREATE TABLE edu_dw.fact_selection (
  selection_sk   BIGINT      NOT NULL AUTO_INCREMENT COMMENT '事实代理键',
  term_id        INT         NOT NULL COMMENT '学期（退化维度）',
  student_id     BIGINT      NOT NULL COMMENT '学生（-1=未知）',
  schedule_id    BIGINT      NOT NULL COMMENT '班次（-1=未知）',
  course_id      INT         NULL COMMENT '冗余：课程（来自班次）',
  teacher_id     BIGINT      NULL COMMENT '冗余：教师（来自班次）',
  select_status  TINYINT     NOT NULL COMMENT '1已选/2已退',
  select_time    DATETIME    NULL COMMENT '选课时间',
  is_valid       TINYINT     NOT NULL COMMENT '1有效/0无效',
  invalid_reason VARCHAR(64) NULL COMMENT '无效原因',
  source_selection_id VARCHAR(64) NULL COMMENT '原始流水号（字符串原样，可能有4D这类脏值）',
  dt             CHAR(10)    NOT NULL,
  PRIMARY KEY (selection_sk),
  KEY idx_term (term_id),
  KEY idx_student (student_id),
  KEY idx_schedule (schedule_id),
  KEY idx_valid (is_valid),
  KEY idx_stu_sch_term (student_id, schedule_id, term_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='事实-选课明细';

INSERT INTO edu_dw.fact_selection
  (term_id, student_id, schedule_id, course_id, teacher_id,
   select_status, select_time, is_valid, invalid_reason, source_selection_id, dt)
WITH s1 AS (                              -- ① 类型转换（正则保护，避免 '4D' 这类脏ID炸掉CAST）
  SELECT selection_id,                                   -- ID 保留字符串
         CASE WHEN student_id  REGEXP '^[0-9]+$' THEN CAST(student_id  AS UNSIGNED) END AS student_id,
         CASE WHEN schedule_id REGEXP '^[0-9]+$' THEN CAST(schedule_id AS UNSIGNED) END AS schedule_id,
         CASE WHEN term_id     REGEXP '^[0-9]+$' THEN CAST(term_id     AS UNSIGNED) END AS term_id,
         CASE WHEN select_status REGEXP '^[0-9]+$' THEN CAST(select_status AS UNSIGNED) END AS select_status,
         CAST(row_id AS UNSIGNED) AS row_id,
         created_at, updated_at, dt
  FROM edu_dw.ods_selection
  WHERE selection_id IS NOT NULL AND selection_id <> ''
),
s2 AS (                                   -- ② 去重一：同一 selection_id 重复抽取
  SELECT *, ROW_NUMBER() OVER (PARTITION BY selection_id ORDER BY row_id) AS rn1
  FROM s1
),
s3 AS (                                   -- ③ 去重二：同一学生+班次+学期保留最新
  SELECT *, ROW_NUMBER() OVER (
             PARTITION BY student_id, schedule_id, term_id
             ORDER BY updated_at DESC, selection_id DESC) AS rn2
  FROM s2 WHERE rn1 = 1
)
SELECT IFNULL(sch.term_id, IFNULL(s3.term_id, 0)) AS term_id_clean,
       IF(ds.student_id   IS NULL, -1, s3.student_id)   AS student_id_clean,
       IF(sch.schedule_id IS NULL, -1, s3.schedule_id)  AS schedule_id_clean,
       sch.course_id, sch.teacher_id,
       IFNULL(s3.select_status, 0) AS select_status_clean, s3.created_at,
       CASE WHEN ds.student_id   IS NULL THEN 0
            WHEN sch.schedule_id IS NULL THEN 0
            WHEN s3.select_status = 2    THEN 0
            ELSE 1 END AS is_valid,
       CASE WHEN ds.student_id   IS NULL THEN '脏学生ID'
            WHEN sch.schedule_id IS NULL THEN '脏外键-未知班次'
            WHEN s3.select_status = 2    THEN '已退课'
            ELSE NULL END AS invalid_reason,
       s3.selection_id, s3.dt
FROM s3
LEFT JOIN edu_dw.dim_student  ds  ON ds.student_id  = s3.student_id
LEFT JOIN edu_dw.dim_schedule sch ON sch.schedule_id = s3.schedule_id
WHERE s3.rn2 = 1;

SELECT COUNT(*) AS fact_selection_rows,
       SUM(is_valid=1) AS valid_rows,
       SUM(is_valid=0) AS invalid_rows
FROM edu_dw.fact_selection;

SELECT invalid_reason, COUNT(*) cnt FROM edu_dw.fact_selection
WHERE is_valid = 0 GROUP BY invalid_reason;


-- =====================================================================
-- 2) fact_score（成绩事实）
--   清洗：正则判数字 → CAST → 越界置 NULL → 学期以班次为准 → 无效标记
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.fact_score;
CREATE TABLE edu_dw.fact_score (
  score_sk       BIGINT       NOT NULL AUTO_INCREMENT,
  term_id        INT          NOT NULL,
  student_id     BIGINT       NOT NULL,
  schedule_id    BIGINT       NOT NULL,
  course_id      INT          NULL,
  teacher_id     BIGINT       NULL,
  exam_type      TINYINT      NOT NULL COMMENT '1正考/2补考/3缓考',
  total_score    DECIMAL(5,2) NULL COMMENT '总评（清洗后）',
  usual_score    DECIMAL(5,2) NULL,
  final_score    DECIMAL(5,2) NULL,
  score_status   TINYINT      NULL,
  is_manual_adjust TINYINT    NULL,
  is_valid       TINYINT      NOT NULL,
  invalid_reason VARCHAR(64)  NULL,
  source_score_id BIGINT      NULL,
  dt             CHAR(10)     NOT NULL,
  PRIMARY KEY (score_sk),
  KEY idx_term (term_id),
  KEY idx_student (student_id),
  KEY idx_schedule (schedule_id),
  KEY idx_exam (exam_type),
  KEY idx_valid (is_valid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='事实-成绩明细';

INSERT INTO edu_dw.fact_score
  (term_id, student_id, schedule_id, course_id, teacher_id, exam_type,
   total_score, usual_score, final_score, score_status, is_manual_adjust,
   is_valid, invalid_reason, source_score_id, dt)
WITH s1 AS (   -- ① 类型转换 + 数字校验
  SELECT CAST(score_id   AS UNSIGNED) AS score_id,
         CAST(student_id AS UNSIGNED) AS student_id,
         CAST(schedule_id AS UNSIGNED) AS schedule_id,
         CAST(term_id     AS UNSIGNED) AS term_id,
         CAST(exam_type   AS UNSIGNED) AS exam_type,
         total_score, usual_score, final_score,
         CAST(score_status AS UNSIGNED) AS score_status,
         CAST(is_manual_adjust AS UNSIGNED) AS is_manual_adjust,
         dt,
         (total_score REGEXP '^-?[0-9]+([.][0-9]+)?$') AS total_is_num,
         (usual_score REGEXP '^-?[0-9]+([.][0-9]+)?$') AS usual_is_num,
         (final_score REGEXP '^-?[0-9]+([.][0-9]+)?$') AS final_is_num
  FROM edu_dw.ods_score
  WHERE score_id IS NOT NULL
),
s2 AS (   -- ② 转数值 + 范围校验
  SELECT s1.*,
         CASE WHEN total_is_num = 1 THEN CAST(total_score AS DECIMAL(6,2)) END AS total_num,
         CASE WHEN usual_is_num = 1 THEN CAST(usual_score AS DECIMAL(6,2)) END AS usual_num,
         CASE WHEN final_is_num = 1 THEN CAST(final_score AS DECIMAL(6,2)) END AS final_num
  FROM s1
)
SELECT IFNULL(sch.term_id, IFNULL(s2.term_id, 0)) AS term_id_clean,
       IF(ds.student_id   IS NULL, -1, s2.student_id)  AS student_id_clean,
       IF(sch.schedule_id IS NULL, -1, s2.schedule_id) AS schedule_id_clean,
       sch.course_id, sch.teacher_id,
       IF(s2.exam_type BETWEEN 1 AND 3, s2.exam_type, 1) AS exam_type_clean,
       -- ④ 越界/非数字 → NULL
       CASE WHEN s2.total_num BETWEEN 0 AND 100 THEN s2.total_num END,
       CASE WHEN s2.usual_num BETWEEN 0 AND 100 THEN s2.usual_num END,
       CASE WHEN s2.final_num BETWEEN 0 AND 100 THEN s2.final_num END,
       s2.score_status, s2.is_manual_adjust,
       -- ⑤ 有效性
       CASE WHEN ds.student_id IS NULL THEN 0
            WHEN sch.schedule_id IS NULL THEN 0
            WHEN s2.total_is_num = 0 AND s2.score_status <> 1 THEN 0
            WHEN s2.total_is_num = 1 AND s2.total_num NOT BETWEEN 0 AND 100 THEN 0
            ELSE 1 END AS is_valid,
       CASE WHEN ds.student_id IS NULL THEN '脏学生ID'
            WHEN sch.schedule_id IS NULL THEN '脏外键-未知班次'
            WHEN s2.total_is_num = 0 AND s2.score_status <> 1 THEN '非数字成绩'
            WHEN s2.total_is_num = 1 AND s2.total_num NOT BETWEEN 0 AND 100 THEN '成绩超出0-100'
            ELSE NULL END AS invalid_reason,
       s2.score_id, s2.dt
FROM s2
LEFT JOIN edu_dw.dim_student  ds  ON ds.student_id  = s2.student_id
LEFT JOIN edu_dw.dim_schedule sch ON sch.schedule_id = s2.schedule_id;

SELECT COUNT(*) AS fact_score_rows, SUM(is_valid=1) AS valid_rows, SUM(is_valid=0) AS invalid_rows
FROM edu_dw.fact_score;
SELECT invalid_reason, COUNT(*) cnt FROM edu_dw.fact_score WHERE is_valid=0 GROUP BY invalid_reason;


-- =====================================================================
-- 3) fact_attendance（考勤事实，约 100 万行）
--   清洗：非法状态码→0、负数分钟→NULL、日期越界→NULL、退课学生→is_valid=0
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.fact_attendance;
CREATE TABLE edu_dw.fact_attendance (
  attendance_sk   BIGINT   NOT NULL AUTO_INCREMENT,
  term_id         INT      NOT NULL,
  student_id      BIGINT   NOT NULL,
  schedule_id     BIGINT   NOT NULL,
  session_id      BIGINT   NOT NULL,
  course_id       INT      NULL,
  teacher_id      BIGINT   NULL,
  session_date    DATE     NULL COMMENT '越界日期清洗为NULL',
  week_no         TINYINT  NULL,
  att_status      TINYINT  NOT NULL COMMENT '0待签到/1出勤/2迟到/3早退/4请假/5旷课',
  late_minutes    INT      NULL,
  early_minutes   INT      NULL,
  is_makeup       TINYINT  NULL,
  is_valid        TINYINT  NOT NULL,
  invalid_reason  VARCHAR(64) NULL,
  source_att_id   BIGINT   NULL,
  dt              CHAR(10) NOT NULL,
  PRIMARY KEY (attendance_sk),
  KEY idx_term (term_id),
  KEY idx_student (student_id),
  KEY idx_schedule (schedule_id),
  KEY idx_session (session_id),
  KEY idx_status (att_status),
  KEY idx_valid (is_valid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='事实-考勤明细';

INSERT INTO edu_dw.fact_attendance
  (term_id, student_id, schedule_id, session_id, course_id, teacher_id,
   session_date, week_no, att_status, late_minutes, early_minutes, is_makeup,
   is_valid, invalid_reason, source_att_id, dt)
WITH a1 AS (
  SELECT CAST(att_id      AS UNSIGNED) AS att_id,
         CAST(student_id  AS UNSIGNED) AS student_id,
         CAST(session_id  AS UNSIGNED) AS session_id,
         CAST(schedule_id AS UNSIGNED) AS schedule_id,
         CAST(term_id     AS UNSIGNED) AS term_id,
         CAST(att_status  AS UNSIGNED) AS att_status_raw,
         att_status AS att_status_str,
         CAST(late_minutes  AS SIGNED) AS late_min,
         CAST(early_minutes AS SIGNED) AS early_min,
         CAST(is_makeup AS UNSIGNED) AS is_makeup,
         session_date, dt, row_id
  FROM edu_dw.ods_attendance
  WHERE att_id IS NOT NULL
),
a2 AS (   -- 按 att_id 去重
  SELECT *, ROW_NUMBER() OVER (PARTITION BY att_id ORDER BY row_id) AS rn
  FROM a1
)
SELECT IFNULL(a2.term_id, 0) AS term_id_clean,
       IF(ds.student_id   IS NULL, -1, a2.student_id)  AS student_id_clean,
       IF(sch.schedule_id IS NULL, -1, a2.schedule_id) AS schedule_id_clean,
       a2.session_id,
       sch.course_id, sch.teacher_id,
       CASE WHEN a2.session_date BETWEEN '2024-01-01' AND '2027-12-31'
            THEN a2.session_date END AS session_date_clean,
       cs.week_no,
       IF(a2.att_status_raw BETWEEN 0 AND 5, a2.att_status_raw, 0) AS att_status_clean,
       CASE WHEN a2.late_min  >= 0 THEN a2.late_min  END,
       CASE WHEN a2.early_min >= 0 THEN a2.early_min END,
       a2.is_makeup,
       CASE WHEN ds.student_id IS NULL THEN 0
            WHEN sch.schedule_id IS NULL THEN 0
            WHEN a2.att_status_raw NOT BETWEEN 0 AND 5 THEN 0
            WHEN a2.session_date NOT BETWEEN '2024-01-01' AND '2027-12-31' THEN 0
            WHEN fs.is_valid = 0 AND fs.invalid_reason = '已退课' THEN 0
            ELSE 1 END AS is_valid,
       CASE WHEN ds.student_id IS NULL THEN '脏学生ID'
            WHEN sch.schedule_id IS NULL THEN '脏外键-未知班次'
            WHEN a2.att_status_raw NOT BETWEEN 0 AND 5 THEN '非法考勤状态'
            WHEN a2.session_date NOT BETWEEN '2024-01-01' AND '2027-12-31' THEN '日期越界'
            WHEN fs.is_valid = 0 AND fs.invalid_reason = '已退课' THEN '退课学生仍有点名'
            ELSE NULL END AS invalid_reason,
       a2.att_id, a2.dt
FROM a2
LEFT JOIN edu_dw.dim_student  ds  ON ds.student_id  = a2.student_id
LEFT JOIN edu_dw.dim_schedule sch ON sch.schedule_id = a2.schedule_id
LEFT JOIN (SELECT CAST(session_id AS UNSIGNED) AS sid, week_no
             FROM edu_dw.ods_course_session) cs ON cs.sid = a2.session_id
LEFT JOIN edu_dw.fact_selection fs
       ON fs.student_id = a2.student_id AND fs.schedule_id = a2.schedule_id AND fs.term_id = a2.term_id
WHERE a2.rn = 1;

SELECT COUNT(*) AS fact_attendance_rows, SUM(is_valid=1) AS valid_rows, SUM(is_valid=0) AS invalid_rows
FROM edu_dw.fact_attendance;
SELECT invalid_reason, COUNT(*) cnt FROM edu_dw.fact_attendance WHERE is_valid=0 GROUP BY invalid_reason;
