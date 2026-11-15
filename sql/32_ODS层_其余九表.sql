-- =====================================================================
-- ODS 层：其余 9 张表（均为干净维表/流水表）
-- 规则：
--   ① 数值型（bigint/int/tinyint/decimal）→ VARCHAR(64)
--   ② 字符串保持原长度（维表数据干净，无需放宽）
--   ③ date/datetime 保留原类型；varbinary(密文) 原样保留
--   ④ 只有 PRIMARY(row_id)，无业务唯一键 / CHECK
-- =====================================================================
USE edu_dw;

SET GLOBAL innodb_flush_log_at_trx_commit = 2;


-- ---------------------------------------------------------------------
-- 1) ods_major（45 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_major;
CREATE TABLE edu_dw.ods_major (
  row_id      BIGINT       NOT NULL AUTO_INCREMENT,
  major_id    VARCHAR(64)  NULL COMMENT '源: bigint',
  college_id  VARCHAR(64)  NULL COMMENT '源: bigint',
  major_name  VARCHAR(64)  NULL,
  major_code  VARCHAR(32)  NULL,
  deleted_at  DATETIME     NULL,
  created_at  DATETIME     NULL,
  updated_at  DATETIME     NULL,
  src_table   VARCHAR(100) NOT NULL,
  etl_time    DATETIME     NOT NULL,
  dt          CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-专业（贴源）';

INSERT INTO edu_dw.ods_major
  (major_id, college_id, major_name, major_code, deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CAST(major_id AS CHAR), CAST(college_id AS CHAR), major_name, major_code,
       deleted_at, created_at, updated_at, 'edu_normal.major', NOW(), '2026-11-10'
FROM edu_normal.major;


-- ---------------------------------------------------------------------
-- 2) ods_class（160 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_class;
CREATE TABLE edu_dw.ods_class (
  row_id      BIGINT       NOT NULL AUTO_INCREMENT,
  class_id    VARCHAR(64)  NULL COMMENT '源: bigint',
  major_id    VARCHAR(64)  NULL,
  teacher_id  VARCHAR(64)  NULL COMMENT '班主任',
  class_no    VARCHAR(32)  NULL,
  class_name  VARCHAR(64)  NULL,
  enroll_year VARCHAR(64)  NULL COMMENT '源: int',
  deleted_at  DATETIME     NULL,
  created_at  DATETIME     NULL,
  updated_at  DATETIME     NULL,
  src_table   VARCHAR(100) NOT NULL,
  etl_time    DATETIME     NOT NULL,
  dt          CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-行政班级（贴源）';

INSERT INTO edu_dw.ods_class
  (class_id, major_id, teacher_id, class_no, class_name, enroll_year,
   deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CAST(class_id AS CHAR), CAST(major_id AS CHAR), CAST(teacher_id AS CHAR),
       class_no, class_name, CAST(enroll_year AS CHAR),
       deleted_at, created_at, updated_at, 'edu_normal.class', NOW(), '2026-11-10'
FROM edu_normal.class;


-- ---------------------------------------------------------------------
-- 3) ods_teacher（400 行）—— phone_cipher 是 VARBINARY，必须保留
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_teacher;
CREATE TABLE edu_dw.ods_teacher (
  row_id       BIGINT        NOT NULL AUTO_INCREMENT,
  teacher_id   VARCHAR(64)   NULL COMMENT '源: bigint',
  college_id   VARCHAR(64)   NULL,
  teacher_no   VARCHAR(32)   NULL,
  teacher_name VARCHAR(32)   NULL,
  title        VARCHAR(30)   NULL COMMENT '职称',
  email        VARCHAR(64)   NULL,
  deleted_at   DATETIME      NULL,
  created_at   DATETIME      NULL,
  updated_at   DATETIME      NULL,
  phone_hash   CHAR(64)      NULL,
  phone_cipher VARBINARY(64) NULL COMMENT '密文，二进制原样保留',
  src_table    VARCHAR(100)  NOT NULL,
  etl_time     DATETIME      NOT NULL,
  dt           CHAR(10)      NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-教师（贴源）';

INSERT INTO edu_dw.ods_teacher
  (teacher_id, college_id, teacher_no, teacher_name, title, email,
   deleted_at, created_at, updated_at, phone_hash, phone_cipher, src_table, etl_time, dt)
SELECT CAST(teacher_id AS CHAR), CAST(college_id AS CHAR), teacher_no, teacher_name, title, email,
       deleted_at, created_at, updated_at, phone_hash, phone_cipher,
       'edu_normal.teacher', NOW(), '2026-11-10'
FROM edu_normal.teacher;


-- ---------------------------------------------------------------------
-- 4) ods_course（120 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_course;
CREATE TABLE edu_dw.ods_course (
  row_id      BIGINT       NOT NULL AUTO_INCREMENT,
  course_id   VARCHAR(64)  NULL COMMENT '源: bigint',
  course_code VARCHAR(32)  NULL,
  course_name VARCHAR(64)  NULL,
  credit      VARCHAR(64)  NULL COMMENT '源: decimal(3,1)',
  course_type VARCHAR(64)  NULL COMMENT '源: tinyint',
  remark      VARCHAR(255) NULL,
  deleted_at  DATETIME     NULL,
  created_at  DATETIME     NULL,
  updated_at  DATETIME     NULL,
  src_table   VARCHAR(100) NOT NULL,
  etl_time    DATETIME     NOT NULL,
  dt          CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-课程（贴源）';

INSERT INTO edu_dw.ods_course
  (course_id, course_code, course_name, credit, course_type, remark,
   deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CAST(course_id AS CHAR), course_code, course_name,
       CAST(credit AS CHAR), CAST(course_type AS CHAR), remark,
       deleted_at, created_at, updated_at, 'edu_normal.course', NOW(), '2026-11-10'
FROM edu_normal.course;


-- ---------------------------------------------------------------------
-- 5) ods_course_prerequisite（200 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_course_prerequisite;
CREATE TABLE edu_dw.ods_course_prerequisite (
  row_id                 BIGINT       NOT NULL AUTO_INCREMENT,
  id                     VARCHAR(64)  NULL,
  course_id              VARCHAR(64)  NULL,
  prerequisite_course_id VARCHAR(64)  NULL,
  remark                 VARCHAR(255) NULL,
  created_at             DATETIME     NULL,
  updated_at             DATETIME     NULL,
  deleted_at             DATETIME     NULL,
  src_table              VARCHAR(100) NOT NULL,
  etl_time               DATETIME     NOT NULL,
  dt                     CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-先修关系（贴源）';

INSERT INTO edu_dw.ods_course_prerequisite
  (id, course_id, prerequisite_course_id, remark, created_at, updated_at, deleted_at,
   src_table, etl_time, dt)
SELECT CAST(id AS CHAR), CAST(course_id AS CHAR), CAST(prerequisite_course_id AS CHAR),
       remark, created_at, updated_at, deleted_at,
       'edu_normal.course_prerequisite', NOW(), '2026-11-10'
FROM edu_normal.course_prerequisite;


-- ---------------------------------------------------------------------
-- 6) ods_classroom（60 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_classroom;
CREATE TABLE edu_dw.ods_classroom (
  row_id        BIGINT       NOT NULL AUTO_INCREMENT,
  id            VARCHAR(64)  NULL,
  building_name VARCHAR(64)  NULL,
  room_no       VARCHAR(32)  NULL,
  capacity      VARCHAR(64)  NULL COMMENT '源: int',
  room_type     VARCHAR(64)  NULL COMMENT '源: tinyint',
  is_enabled    VARCHAR(64)  NULL COMMENT '源: tinyint',
  remark        VARCHAR(255) NULL,
  created_at    DATETIME     NULL,
  updated_at    DATETIME     NULL,
  deleted_at    DATETIME     NULL,
  src_table     VARCHAR(100) NOT NULL,
  etl_time      DATETIME     NOT NULL,
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-教室（贴源）';

INSERT INTO edu_dw.ods_classroom
  (id, building_name, room_no, capacity, room_type, is_enabled, remark,
   created_at, updated_at, deleted_at, src_table, etl_time, dt)
SELECT CAST(id AS CHAR), building_name, room_no,
       CAST(capacity AS CHAR), CAST(room_type AS CHAR), CAST(is_enabled AS CHAR), remark,
       created_at, updated_at, deleted_at, 'edu_normal.classroom', NOW(), '2026-11-10'
FROM edu_normal.classroom;


-- ---------------------------------------------------------------------
-- 7) ods_sys_dict（41 行）—— 字典表
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_sys_dict;
CREATE TABLE edu_dw.ods_sys_dict (
  row_id      BIGINT       NOT NULL AUTO_INCREMENT,
  id          VARCHAR(64)  NULL,
  dict_type   VARCHAR(64)  NULL,
  dict_label  VARCHAR(64)  NULL,
  dict_value  VARCHAR(64)  NULL,
  sort        VARCHAR(64)  NULL COMMENT '源: int',
  active_flag VARCHAR(64)  NULL COMMENT '源: tinyint',
  created_at  DATETIME     NULL,
  updated_at  DATETIME     NULL,
  deleted_at  DATETIME     NULL,
  src_table   VARCHAR(100) NOT NULL,
  etl_time    DATETIME     NOT NULL,
  dt          CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-字典（贴源）';

INSERT INTO edu_dw.ods_sys_dict
  (id, dict_type, dict_label, dict_value, sort, active_flag,
   created_at, updated_at, deleted_at, src_table, etl_time, dt)
SELECT CAST(id AS CHAR), dict_type, dict_label, dict_value,
       CAST(sort AS CHAR), CAST(active_flag AS CHAR),
       created_at, updated_at, deleted_at, 'edu_normal.sys_dict', NOW(), '2026-11-10'
FROM edu_normal.sys_dict;


-- ---------------------------------------------------------------------
-- 8) ods_student_status_change（2000 行）—— 学籍异动，拉链表的数据来源
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_student_status_change;
CREATE TABLE edu_dw.ods_student_status_change (
  row_id         BIGINT       NOT NULL AUTO_INCREMENT,
  id             VARCHAR(64)  NULL,
  student_id     VARCHAR(64)  NULL,
  change_type    VARCHAR(64)  NULL COMMENT '源: tinyint（1休学..7恢复）',
  from_class_id  VARCHAR(64)  NULL,
  to_class_id    VARCHAR(64)  NULL,
  old_status     VARCHAR(64)  NULL,
  new_status     VARCHAR(64)  NULL,
  change_reason  VARCHAR(512) NULL,
  operator_id    VARCHAR(64)  NULL,
  operate_time   DATETIME     NULL,
  created_at     DATETIME     NULL,
  updated_at     DATETIME     NULL,
  deleted_at     DATETIME     NULL,
  src_table      VARCHAR(100) NOT NULL,
  etl_time       DATETIME     NOT NULL,
  dt             CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-学籍异动（贴源，拉链来源）';

INSERT INTO edu_dw.ods_student_status_change
  (id, student_id, change_type, from_class_id, to_class_id, old_status, new_status,
   change_reason, operator_id, operate_time, created_at, updated_at, deleted_at,
   src_table, etl_time, dt)
SELECT CAST(id AS CHAR), CAST(student_id AS CHAR), CAST(change_type AS CHAR),
       CAST(from_class_id AS CHAR), CAST(to_class_id AS CHAR),
       CAST(old_status AS CHAR), CAST(new_status AS CHAR),
       change_reason, CAST(operator_id AS CHAR), operate_time,
       created_at, updated_at, deleted_at,
       'edu_normal.student_status_change', NOW(), '2026-11-10'
FROM edu_normal.student_status_change;


-- ---------------------------------------------------------------------
-- 9) ods_reward_punish（3000 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_reward_punish;
CREATE TABLE edu_dw.ods_reward_punish (
  row_id      BIGINT        NOT NULL AUTO_INCREMENT,
  id          VARCHAR(64)   NULL,
  student_id  VARCHAR(64)   NULL,
  term_id     VARCHAR(64)   NULL COMMENT '源: int（可空）',
  rp_type     VARCHAR(64)   NULL COMMENT '源: tinyint',
  rp_level    VARCHAR(64)   NULL COMMENT '源: tinyint',
  amount      VARCHAR(64)   NULL COMMENT '源: decimal(10,2)',
  rp_title    VARCHAR(128)  NULL,
  rp_content  TEXT          NULL,
  rp_date     DATE          NULL,
  issue_dept  VARCHAR(64)   NULL,
  file_no     VARCHAR(64)   NULL,
  operator_id VARCHAR(64)   NULL,
  created_at  DATETIME      NULL,
  updated_at  DATETIME      NULL,
  deleted_at  DATETIME      NULL,
  src_table   VARCHAR(100)  NOT NULL,
  etl_time    DATETIME      NOT NULL,
  dt          CHAR(10)      NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-奖助奖惩（贴源）';

INSERT INTO edu_dw.ods_reward_punish
  (id, student_id, term_id, rp_type, rp_level, amount, rp_title, rp_content,
   rp_date, issue_dept, file_no, operator_id, created_at, updated_at, deleted_at,
   src_table, etl_time, dt)
SELECT CAST(id AS CHAR), CAST(student_id AS CHAR), CAST(term_id AS CHAR),
       CAST(rp_type AS CHAR), CAST(rp_level AS CHAR), CAST(amount AS CHAR),
       rp_title, rp_content, rp_date, issue_dept, file_no, CAST(operator_id AS CHAR),
       created_at, updated_at, deleted_at,
       'edu_normal.reward_punish', NOW(), '2026-11-10'
FROM edu_normal.reward_punish;


-- =====================================================================
-- 收尾：恢复刷盘策略
-- =====================================================================
SET GLOBAL innodb_flush_log_at_trx_commit = 1;
