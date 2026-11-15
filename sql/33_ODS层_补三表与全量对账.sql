-- =====================================================================
-- ODS 层：补齐最后 3 张表（都属于 edu_online 的班次/时段/课次）
-- =====================================================================
USE edu_dw;

-- ---------------------------------------------------------------------
-- 1) ods_course_schedule（720 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_course_schedule;
CREATE TABLE edu_dw.ods_course_schedule (
  row_id        BIGINT       NOT NULL AUTO_INCREMENT,
  schedule_id   VARCHAR(64)  NULL,
  course_id     VARCHAR(64)  NULL,
  teacher_id    VARCHAR(64)  NULL,
  class_no      VARCHAR(64)  NULL COMMENT '源: tinyint（班次号）',
  term_id       VARCHAR(64)  NULL COMMENT '源: int（学期）',
  max_count     VARCHAR(64)  NULL COMMENT '源: int（容量）',
  current_count VARCHAR(64)  NULL COMMENT '源: int（已选人数）',
  start_time    DATETIME     NULL,
  end_time      DATETIME     NULL,
  deleted_at    DATETIME     NULL,
  created_at    DATETIME     NULL,
  updated_at    DATETIME     NULL,
  src_table     VARCHAR(100) NOT NULL,
  etl_time      DATETIME     NOT NULL,
  dt            CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-开课班次（贴源）';

INSERT INTO edu_dw.ods_course_schedule
  (schedule_id, course_id, teacher_id, class_no, term_id, max_count, current_count,
   start_time, end_time, deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CAST(schedule_id AS CHAR), CAST(course_id AS CHAR), CAST(teacher_id AS CHAR),
       CAST(class_no AS CHAR), CAST(term_id AS CHAR),
       CAST(max_count AS CHAR), CAST(current_count AS CHAR),
       start_time, end_time, deleted_at, created_at, updated_at,
       'edu_online.course_schedule', NOW(), '2026-11-10'
FROM edu_online.course_schedule;

-- ---------------------------------------------------------------------
-- 2) ods_schedule_time（1440 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_schedule_time;
CREATE TABLE edu_dw.ods_schedule_time (
  row_id       BIGINT       NOT NULL AUTO_INCREMENT,
  st_id        VARCHAR(64)  NULL,
  schedule_id  VARCHAR(64)  NULL,
  week         VARCHAR(64)  NULL COMMENT '源: tinyint（星期1-7）',
  begin_section VARCHAR(64) NULL COMMENT '源: tinyint（起始节次）',
  end_section   VARCHAR(64) NULL COMMENT '源: tinyint（结束节次）',
  classroom_id VARCHAR(64)  NULL,
  deleted_at   DATETIME     NULL,
  created_at   DATETIME     NULL,
  updated_at   DATETIME     NULL,
  src_table    VARCHAR(100) NOT NULL,
  etl_time     DATETIME     NOT NULL,
  dt           CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-排课时段模板（贴源）';

INSERT INTO edu_dw.ods_schedule_time
  (st_id, schedule_id, week, begin_section, end_section, classroom_id,
   deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CAST(st_id AS CHAR), CAST(schedule_id AS CHAR), CAST(week AS CHAR),
       CAST(begin_section AS CHAR), CAST(end_section AS CHAR), CAST(classroom_id AS CHAR),
       deleted_at, created_at, updated_at,
       'edu_online.schedule_time', NOW(), '2026-11-10'
FROM edu_online.schedule_time;

-- ---------------------------------------------------------------------
-- 3) ods_course_session（11520 行）—— 考勤粒度就是「一次具体的课」
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_course_session;
CREATE TABLE edu_dw.ods_course_session (
  row_id       BIGINT       NOT NULL AUTO_INCREMENT,
  session_id   VARCHAR(64)  NULL,
  term_id      VARCHAR(64)  NULL,
  schedule_id  VARCHAR(64)  NULL,
  session_no   VARCHAR(64)  NULL COMMENT '源: smallint（第几次课）',
  week_no      VARCHAR(64)  NULL COMMENT '源: tinyint（第几教学周）',
  session_date DATE         NULL COMMENT '日期保留原类型',
  classroom_id VARCHAR(64)  NULL,
  week_day     VARCHAR(64)  NULL COMMENT '源: tinyint（1周一..7周日）',
  start_section VARCHAR(64) NULL,
  end_section   VARCHAR(64) NULL,
  created_at   DATETIME     NULL,
  updated_at   DATETIME     NULL,
  deleted_at   DATETIME     NULL,
  src_table    VARCHAR(100) NOT NULL,
  etl_time     DATETIME     NOT NULL,
  dt           CHAR(10)     NOT NULL,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-授课场次（贴源）';

INSERT INTO edu_dw.ods_course_session
  (session_id, term_id, schedule_id, session_no, week_no, session_date, classroom_id,
   week_day, start_section, end_section, created_at, updated_at, deleted_at,
   src_table, etl_time, dt)
SELECT CAST(session_id AS CHAR), CAST(term_id AS CHAR), CAST(schedule_id AS CHAR),
       CAST(session_no AS CHAR), CAST(week_no AS CHAR), session_date,
       CAST(classroom_id AS CHAR), CAST(week_day AS CHAR),
       CAST(start_section AS CHAR), CAST(end_section AS CHAR),
       created_at, updated_at, deleted_at,
       'edu_online.course_session', NOW(), '2026-11-10'
FROM edu_online.course_session;


-- =====================================================================
-- 全量对账：17 张 ODS 表 vs 源表
-- =====================================================================
SELECT 'college' t, (SELECT COUNT(*) FROM edu_normal.college) src, (SELECT COUNT(*) FROM edu_dw.ods_college) ods
UNION ALL SELECT 'major',   (SELECT COUNT(*) FROM edu_normal.major),   (SELECT COUNT(*) FROM edu_dw.ods_major)
UNION ALL SELECT 'class',   (SELECT COUNT(*) FROM edu_normal.class),   (SELECT COUNT(*) FROM edu_dw.ods_class)
UNION ALL SELECT 'student', (SELECT COUNT(*) FROM edu_normal.student), (SELECT COUNT(*) FROM edu_dw.ods_student)
UNION ALL SELECT 'teacher', (SELECT COUNT(*) FROM edu_normal.teacher), (SELECT COUNT(*) FROM edu_dw.ods_teacher)
UNION ALL SELECT 'course',  (SELECT COUNT(*) FROM edu_normal.course),  (SELECT COUNT(*) FROM edu_dw.ods_course)
UNION ALL SELECT 'course_prerequisite', (SELECT COUNT(*) FROM edu_normal.course_prerequisite), (SELECT COUNT(*) FROM edu_dw.ods_course_prerequisite)
UNION ALL SELECT 'classroom', (SELECT COUNT(*) FROM edu_normal.classroom), (SELECT COUNT(*) FROM edu_dw.ods_classroom)
UNION ALL SELECT 'sys_dict',  (SELECT COUNT(*) FROM edu_normal.sys_dict),  (SELECT COUNT(*) FROM edu_dw.ods_sys_dict)
UNION ALL SELECT 'student_status_change', (SELECT COUNT(*) FROM edu_normal.student_status_change), (SELECT COUNT(*) FROM edu_dw.ods_student_status_change)
UNION ALL SELECT 'reward_punish', (SELECT COUNT(*) FROM edu_normal.reward_punish), (SELECT COUNT(*) FROM edu_dw.ods_reward_punish)
UNION ALL SELECT 'course_schedule', (SELECT COUNT(*) FROM edu_online.course_schedule), (SELECT COUNT(*) FROM edu_dw.ods_course_schedule)
UNION ALL SELECT 'schedule_time',   (SELECT COUNT(*) FROM edu_online.schedule_time),   (SELECT COUNT(*) FROM edu_dw.ods_schedule_time)
UNION ALL SELECT 'course_session',  (SELECT COUNT(*) FROM edu_online.course_session),  (SELECT COUNT(*) FROM edu_dw.ods_course_session)
UNION ALL SELECT 'selection',  (SELECT COUNT(*) FROM edu_online.selection),  (SELECT COUNT(*) FROM edu_dw.ods_selection)
UNION ALL SELECT 'score',      (SELECT COUNT(*) FROM edu_online.score),      (SELECT COUNT(*) FROM edu_dw.ods_score)
UNION ALL SELECT 'attendance', (SELECT COUNT(*) FROM edu_online.attendance), (SELECT COUNT(*) FROM edu_dw.ods_attendance);

-- 约束检查：所有 ODS 表都只能有 PRIMARY(row_id)
SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='edu_dw'
GROUP BY TABLE_NAME, INDEX_NAME
HAVING INDEX_NAME <> 'PRIMARY';
-- 期望：空结果
