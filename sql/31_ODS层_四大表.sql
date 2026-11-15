-- =====================================================================
-- ODS 层：4 张大表（需要「脱类型」的表）
--   student(1000) / selection(50万) / score(49万) / attendance(100万)
-- 关键规范：
--   ① 数值型 → VARCHAR（脏数据高发）
--   ② 日期/时间 → 保留 DATETIME/DATE
--   ③ varbinary(密文) → 原样保留，绝不能转 VARCHAR
--   ④ 生成列 active_flag → 不带进 ODS（它是派生列，DWD 层重算）
--   ⑤ 只留 PRIMARY(row_id)，不要业务唯一键 / CHECK
-- =====================================================================
USE edu_dw;

-- 提速（灌完记得改回 1）
SET GLOBAL innodb_flush_log_at_trx_commit = 2;


-- =====================================================================
-- 1) ods_student —— 源 12 列
--    要点：id_card_cipher / phone_cipher 是 VARBINARY，必须原样保留
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ods_student;
CREATE TABLE edu_dw.ods_student (
  row_id         BIGINT       NOT NULL AUTO_INCREMENT COMMENT 'ODS行号',
  student_id     VARCHAR(64)  NULL COMMENT '源: bigint',
  class_id       VARCHAR(64)  NULL COMMENT '源: bigint',
  student_no     VARCHAR(64)  NULL COMMENT '源: varchar(32)',
  student_name   VARCHAR(255) NULL COMMENT '源: varchar(32)，故意放宽（尾空格/超长也能贴进来）',
  gender         VARCHAR(64)  NULL COMMENT '源: tinyint',
  deleted_at     DATETIME     NULL,
  created_at     DATETIME     NULL,
  updated_at     DATETIME     NULL,
  id_card_hash   CHAR(64)     NULL COMMENT '哈希字符串，保留',
  id_card_cipher VARBINARY(64) NULL COMMENT '密文，二进制必须保留原类型',
  phone_hash     CHAR(64)     NULL,
  phone_cipher   VARBINARY(64) NULL,
  src_table      VARCHAR(100) NOT NULL,
  etl_time       DATETIME     NOT NULL,
  dt             CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-学生（贴源）';

INSERT INTO edu_dw.ods_student
  (student_id, class_id, student_no, student_name, gender,
   deleted_at, created_at, updated_at,
   id_card_hash, id_card_cipher, phone_hash, phone_cipher,
   src_table, etl_time, dt)
SELECT CAST(student_id AS CHAR), CAST(class_id AS CHAR), student_no, student_name, CAST(gender AS CHAR),
       deleted_at, created_at, updated_at,
       id_card_hash, id_card_cipher, phone_hash, phone_cipher,
       'edu_normal.student', NOW(), '2026-11-10'
FROM edu_normal.student;

SELECT 'student' AS tbl,
       (SELECT COUNT(*) FROM edu_normal.student) AS src_cnt,
       (SELECT COUNT(*) FROM edu_dw.ods_student) AS ods_cnt,
       (SELECT SUM(CRC32(CONCAT_WS('#', student_id, student_no, gender))) FROM edu_normal.student) AS src_crc,
       (SELECT SUM(CRC32(CONCAT_WS('#', student_id, student_no, gender))) FROM edu_dw.ods_student) AS ods_crc;


-- =====================================================================
-- 2) ods_selection —— 50 万行，源 11 列但去掉生成列 active_flag → 10 列
--    ⚠️ 绝对不能带 uk_stu_schedule_term，否则源里的重复选课抽不进来
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ods_selection;
CREATE TABLE edu_dw.ods_selection (
  row_id        BIGINT       NOT NULL AUTO_INCREMENT COMMENT 'ODS行号',
  selection_id  VARCHAR(64)  NULL COMMENT '源: bigint',
  student_id    VARCHAR(64)  NULL,
  schedule_id   VARCHAR(64)  NULL,
  term_id       VARCHAR(64)  NULL COMMENT '源: int',
  select_status VARCHAR(64)  NULL COMMENT '源: tinyint（1已选/2已退）',
  creator       VARCHAR(64)  NULL,
  remark        VARCHAR(255) NULL,
  deleted_at    DATETIME     NULL,
  created_at    DATETIME     NULL,
  updated_at    DATETIME     NULL,
  src_table     VARCHAR(100) NOT NULL,
  etl_time      DATETIME     NOT NULL,
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-选课流水（贴源，无唯一键）';

INSERT INTO edu_dw.ods_selection
  (selection_id, student_id, schedule_id, term_id, select_status, creator, remark,
   deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CAST(selection_id AS CHAR), CAST(student_id AS CHAR), CAST(schedule_id AS CHAR),
       CAST(term_id AS CHAR), CAST(select_status AS CHAR), CAST(creator AS CHAR), remark,
       deleted_at, created_at, updated_at,
       'edu_online.selection', NOW(), '2026-11-10'
FROM edu_online.selection;

SELECT 'selection' AS tbl,
       (SELECT COUNT(*) FROM edu_online.selection) AS src_cnt,
       (SELECT COUNT(*) FROM edu_dw.ods_selection) AS ods_cnt,
       (SELECT SUM(CRC32(CONCAT_WS('#', selection_id, student_id, schedule_id, select_status)))
          FROM edu_online.selection) AS src_crc,
       (SELECT SUM(CRC32(CONCAT_WS('#', selection_id, student_id, schedule_id, select_status)))
          FROM edu_dw.ods_selection) AS ods_crc;


-- =====================================================================
-- 3) ods_score —— 约 49 万行，源 16 列
--    要点：total_score / usual_score / final_score 三个 decimal 必须脱成 VARCHAR
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ods_score;
CREATE TABLE edu_dw.ods_score (
  row_id           BIGINT       NOT NULL AUTO_INCREMENT COMMENT 'ODS行号',
  score_id         VARCHAR(64)  NULL,
  student_id       VARCHAR(64)  NULL,
  schedule_id      VARCHAR(64)  NULL,
  exam_type        VARCHAR(64)  NULL COMMENT '源: tinyint（1正考/2补考/3缓考）',
  term_id          VARCHAR(64)  NULL,
  total_score      VARCHAR(64)  NULL COMMENT '源: decimal(5,2)',
  score_status     VARCHAR(64)  NULL,
  is_manual_adjust VARCHAR(64)  NULL,
  rule_version     VARCHAR(64)  NULL,
  creator          VARCHAR(64)  NULL,
  remark           VARCHAR(255) NULL,
  deleted_at       DATETIME     NULL,
  created_at       DATETIME     NULL,
  updated_at       DATETIME     NULL,
  usual_score      VARCHAR(64)  NULL,
  final_score      VARCHAR(64)  NULL,
  src_table        VARCHAR(100) NOT NULL,
  etl_time         DATETIME     NOT NULL,
  dt               CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-成绩（贴源）';

INSERT INTO edu_dw.ods_score
  (score_id, student_id, schedule_id, exam_type, term_id,
   total_score, score_status, is_manual_adjust, rule_version, creator, remark,
   deleted_at, created_at, updated_at, usual_score, final_score,
   src_table, etl_time, dt)
SELECT CAST(score_id AS CHAR), CAST(student_id AS CHAR), CAST(schedule_id AS CHAR),
       CAST(exam_type AS CHAR), CAST(term_id AS CHAR),
       CAST(total_score AS CHAR), CAST(score_status AS CHAR),
       CAST(is_manual_adjust AS CHAR), rule_version, CAST(creator AS CHAR), remark,
       deleted_at, created_at, updated_at,
       CAST(usual_score AS CHAR), CAST(final_score AS CHAR),
       'edu_online.score', NOW(), '2026-11-10'
FROM edu_online.score;

SELECT 'score' AS tbl,
       (SELECT COUNT(*) FROM edu_online.score) AS src_cnt,
       (SELECT COUNT(*) FROM edu_dw.ods_score) AS ods_cnt,
       (SELECT SUM(CRC32(CONCAT_WS('#', score_id, student_id, schedule_id, total_score)))
          FROM edu_online.score) AS src_crc,
       (SELECT SUM(CRC32(CONCAT_WS('#', score_id, student_id, schedule_id, total_score)))
          FROM edu_dw.ods_score) AS ods_crc;


-- =====================================================================
-- 4) ods_attendance —— 100 万行，源 18 列（最慢的一张，约 40~90 秒）
--    要点：late_minutes / early_minutes 脱成 VARCHAR（可能是脏值）
--          session_date / att_time / check_time 保留日期类型
-- =====================================================================
DROP TABLE IF EXISTS edu_dw.ods_attendance;
CREATE TABLE edu_dw.ods_attendance (
  row_id        BIGINT       NOT NULL AUTO_INCREMENT COMMENT 'ODS行号',
  att_id        VARCHAR(64)  NULL,
  student_id    VARCHAR(64)  NULL,
  session_id    VARCHAR(64)  NULL,
  session_date  DATE         NULL COMMENT '日期保留原类型',
  schedule_id   VARCHAR(64)  NULL,
  term_id       VARCHAR(64)  NULL,
  att_status    VARCHAR(64)  NULL COMMENT '源: tinyint（0待签到..5旷课）',
  is_makeup     VARCHAR(64)  NULL,
  late_minutes  VARCHAR(64)  NULL COMMENT '源: int',
  early_minutes VARCHAR(64)  NULL COMMENT '源: int',
  att_time      DATETIME     NULL,
  sign_method   VARCHAR(64)  NULL,
  check_by      VARCHAR(64)  NULL,
  check_time    DATETIME     NULL,
  remark        VARCHAR(255) NULL,
  deleted_at    DATETIME     NULL,
  created_at    DATETIME     NULL,
  updated_at    DATETIME     NULL,
  src_table     VARCHAR(100) NOT NULL,
  etl_time      DATETIME     NOT NULL,
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-考勤明细（贴源）';

INSERT INTO edu_dw.ods_attendance
  (att_id, student_id, session_id, session_date, schedule_id, term_id,
   att_status, is_makeup, late_minutes, early_minutes, att_time,
   sign_method, check_by, check_time, remark,
   deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CAST(att_id AS CHAR), CAST(student_id AS CHAR), CAST(session_id AS CHAR), session_date,
       CAST(schedule_id AS CHAR), CAST(term_id AS CHAR),
       CAST(att_status AS CHAR), CAST(is_makeup AS CHAR),
       CAST(late_minutes AS CHAR), CAST(early_minutes AS CHAR), att_time,
       CAST(sign_method AS CHAR), CAST(check_by AS CHAR), check_time, remark,
       deleted_at, created_at, updated_at,
       'edu_online.attendance', NOW(), '2026-11-10'
FROM edu_online.attendance;

SELECT 'attendance' AS tbl,
       (SELECT COUNT(*) FROM edu_online.attendance) AS src_cnt,
       (SELECT COUNT(*) FROM edu_dw.ods_attendance) AS ods_cnt,
       (SELECT SUM(CRC32(CONCAT_WS('#', att_id, student_id, session_id, att_status)))
          FROM edu_online.attendance) AS src_crc,
       (SELECT SUM(CRC32(CONCAT_WS('#', att_id, student_id, session_id, att_status)))
          FROM edu_dw.ods_attendance) AS ods_crc;


-- =====================================================================
-- 5) 收尾：恢复刷盘策略 + 规模汇总
-- =====================================================================
SET GLOBAL innodb_flush_log_at_trx_commit = 1;

SELECT 'ods_student'    AS t, COUNT(*) AS rows_ FROM edu_dw.ods_student
UNION ALL SELECT 'ods_selection',  COUNT(*) FROM edu_dw.ods_selection
UNION ALL SELECT 'ods_score',      COUNT(*) FROM edu_dw.ods_score
UNION ALL SELECT 'ods_attendance', COUNT(*) FROM edu_dw.ods_attendance;

-- 约束检查：每张 ODS 表都应该"只有 PRIMARY row_id"
SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='edu_dw' AND TABLE_NAME IN
      ('ods_student','ods_selection','ods_score','ods_attendance')
GROUP BY TABLE_NAME, INDEX_NAME ORDER BY TABLE_NAME;
