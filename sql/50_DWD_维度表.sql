-- =====================================================================
-- DWD 层（一）：维度表 8 张
--   清洗规则：TRIM、类型转换、字典翻译、未知成员占位
-- 依赖：edu_dw.ods_*（已就绪）
-- =====================================================================
USE edu_dw;

-- ---------------------------------------------------------------------
-- 0) 日期维 dim_date：2024-01-01 ~ 2027-12-31（1461 天）
-- ---------------------------------------------------------------------
SET SESSION cte_max_recursion_depth = 3000;

DROP TABLE IF EXISTS edu_dw.dim_date;
CREATE TABLE edu_dw.dim_date (
  date_key      INT      NOT NULL COMMENT '代理键 yyyymmdd',
  full_date     DATE     NOT NULL COMMENT '日期',
  year_num      SMALLINT NOT NULL,
  month_num     TINYINT  NOT NULL,
  day_num       TINYINT  NOT NULL,
  week_day      TINYINT  NOT NULL COMMENT '1周一..7周日',
  week_day_name VARCHAR(8) NOT NULL,
  week_of_year  TINYINT  NOT NULL COMMENT 'ISO 周序号',
  is_weekend    TINYINT  NOT NULL COMMENT '1周末/0工作日',
  PRIMARY KEY (date_key),
  UNIQUE KEY uk_full_date (full_date),
  KEY idx_year_month (year_num, month_num)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-日期';

INSERT INTO edu_dw.dim_date
  (date_key, full_date, year_num, month_num, day_num, week_day, week_day_name, week_of_year, is_weekend)
WITH RECURSIVE d(dt) AS (
  SELECT DATE'2024-01-01'
  UNION ALL
  SELECT DATE_ADD(dt, INTERVAL 1 DAY) FROM d WHERE dt < DATE'2027-12-31'
)
SELECT CAST(DATE_FORMAT(dt, '%Y%m%d') AS UNSIGNED),
       dt, YEAR(dt), MONTH(dt), DAY(dt),
       WEEKDAY(dt) + 1,
       ELT(WEEKDAY(dt) + 1, '周一','周二','周三','周四','周五','周六','周日'),
       WEEK(dt, 3),
       IF(WEEKDAY(dt) >= 5, 1, 0)
FROM d;

SELECT COUNT(*) AS dim_date_rows, MIN(full_date) AS d1, MAX(full_date) AS d2 FROM edu_dw.dim_date;


-- ---------------------------------------------------------------------
-- 1) 学期维 dim_term（3 个学期，与 fact 的 term_id 对齐）
--    term_id 约定：202501 = 2025 春季，202502 = 2025 秋季，202601 = 2026 春季
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_term;
CREATE TABLE edu_dw.dim_term (
  term_id     INT         NOT NULL,
  term_name   VARCHAR(64) NOT NULL COMMENT '如 2024-2025学年第二学期',
  school_year VARCHAR(16) NOT NULL COMMENT '如 2024-2025',
  term_seq    TINYINT     NOT NULL COMMENT '1秋季/2春季',
  begin_date  DATE        NOT NULL,
  end_date    DATE        NOT NULL,
  season      VARCHAR(8)  NOT NULL COMMENT '春/秋',
  PRIMARY KEY (term_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-学期';

INSERT INTO edu_dw.dim_term
  (term_id, term_name, school_year, term_seq, begin_date, end_date, season) VALUES
(202501, '2024-2025学年第二学期', '2024-2025', 2, '2025-02-24', '2025-06-20', '春'),
(202502, '2025-2026学年第一学期', '2025-2026', 1, '2025-09-01', '2025-12-26', '秋'),
(202601, '2025-2026学年第二学期', '2025-2026', 2, '2026-03-02', '2026-06-26', '春');


-- ---------------------------------------------------------------------
-- 2) 学院维 dim_college
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_college;
CREATE TABLE edu_dw.dim_college (
  college_id   INT          NOT NULL,
  college_code VARCHAR(32)  NOT NULL,
  college_name VARCHAR(100) NOT NULL,
  PRIMARY KEY (college_id),
  UNIQUE KEY uk_code (college_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-学院（已清洗）';

INSERT INTO edu_dw.dim_college (college_id, college_code, college_name)
SELECT CAST(college_id AS UNSIGNED), TRIM(college_code), TRIM(college_name)
FROM edu_dw.ods_college
WHERE CAST(college_id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 3) 专业维 dim_major（挂上学院名，便于报表直接用）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_major;
CREATE TABLE edu_dw.dim_major (
  major_id     INT          NOT NULL,
  major_code   VARCHAR(32)  NOT NULL,
  major_name   VARCHAR(100) NOT NULL,
  college_id   INT          NOT NULL,
  college_name VARCHAR(100) NULL COMMENT '冗余学院名，省一次 JOIN',
  PRIMARY KEY (major_id),
  KEY idx_college (college_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-专业';

INSERT INTO edu_dw.dim_major (major_id, major_code, major_name, college_id, college_name)
SELECT CAST(m.major_id AS UNSIGNED), TRIM(m.major_code), TRIM(m.major_name),
       CAST(m.college_id AS UNSIGNED), c.college_name
FROM edu_dw.ods_major m
LEFT JOIN edu_dw.dim_college c ON c.college_id = CAST(m.college_id AS UNSIGNED)
WHERE CAST(m.major_id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 4) 班级维 dim_class
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_class;
CREATE TABLE edu_dw.dim_class (
  class_id      INT          NOT NULL,
  class_no      VARCHAR(32)  NOT NULL,
  class_name    VARCHAR(64)  NOT NULL,
  major_id      INT          NULL,
  major_name    VARCHAR(100) NULL,
  college_name  VARCHAR(100) NULL,
  enroll_year   SMALLINT     NULL,
  head_teacher_id BIGINT     NULL COMMENT '班主任',
  PRIMARY KEY (class_id),
  KEY idx_major (major_id),
  KEY idx_enroll_year (enroll_year)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-行政班级';

INSERT INTO edu_dw.dim_class
  (class_id, class_no, class_name, major_id, major_name, college_name, enroll_year, head_teacher_id)
SELECT CAST(cl.class_id AS UNSIGNED), TRIM(cl.class_no), TRIM(cl.class_name),
       CAST(cl.major_id AS UNSIGNED), m.major_name, m.college_name,
       CAST(cl.enroll_year AS UNSIGNED), CAST(cl.teacher_id AS UNSIGNED)
FROM edu_dw.ods_class cl
LEFT JOIN edu_dw.dim_major m ON m.major_id = CAST(cl.major_id AS UNSIGNED)
WHERE CAST(cl.class_id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 5) 教室维 dim_classroom
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_classroom;
CREATE TABLE edu_dw.dim_classroom (
  classroom_id  INT          NOT NULL,
  building_name VARCHAR(64)  NOT NULL,
  room_no       VARCHAR(32)  NOT NULL,
  full_name     VARCHAR(128) NOT NULL COMMENT '楼栋+房间号',
  capacity      INT          NULL,
  room_type     TINYINT      NULL,
  room_type_name VARCHAR(16) NULL,
  is_enabled    TINYINT      NULL,
  PRIMARY KEY (classroom_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-教室';

INSERT INTO edu_dw.dim_classroom
  (classroom_id, building_name, room_no, full_name, capacity, room_type, room_type_name, is_enabled)
SELECT CAST(c.id AS UNSIGNED), TRIM(c.building_name), TRIM(c.room_no),
       CONCAT(TRIM(c.building_name), TRIM(c.room_no)),
       CAST(c.capacity AS UNSIGNED), CAST(c.room_type AS UNSIGNED),
       d.dict_label, CAST(c.is_enabled AS UNSIGNED)
FROM edu_dw.ods_classroom c
LEFT JOIN edu_dw.ods_sys_dict d
       ON d.dict_type = 'room_type' AND d.dict_value = c.room_type
WHERE CAST(c.id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 6) 课程维 dim_course（字典翻译 course_type）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_course;
CREATE TABLE edu_dw.dim_course (
  course_id     INT          NOT NULL,
  course_code   VARCHAR(32)  NOT NULL,
  course_name   VARCHAR(100) NOT NULL,
  credit        DECIMAL(3,1) NULL,
  course_type   TINYINT      NULL,
  course_type_name VARCHAR(16) NULL,
  prereq_cnt    INT          NOT NULL DEFAULT 0 COMMENT '先修课数量（来自先修关系表）',
  PRIMARY KEY (course_id),
  KEY idx_type (course_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-课程';

INSERT INTO edu_dw.dim_course
  (course_id, course_code, course_name, credit, course_type, course_type_name, prereq_cnt)
SELECT CAST(c.course_id AS UNSIGNED), TRIM(c.course_code), TRIM(c.course_name),
       CAST(c.credit AS DECIMAL(3,1)), CAST(c.course_type AS UNSIGNED),
       d.dict_label,
       (SELECT COUNT(*) FROM edu_dw.ods_course_prerequisite p
         WHERE p.course_id = c.course_id)
FROM edu_dw.ods_course c
LEFT JOIN edu_dw.ods_sys_dict d
       ON d.dict_type = 'course_type' AND d.dict_value = c.course_type
WHERE CAST(c.course_id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 7) 教师维 dim_teacher（含 -1 未知成员）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_teacher;
CREATE TABLE edu_dw.dim_teacher (
  teacher_id   BIGINT       NOT NULL,
  teacher_no   VARCHAR(32)  NULL,
  teacher_name VARCHAR(64)  NULL,
  title        VARCHAR(30)  NULL COMMENT '职称',
  college_id   INT          NULL,
  college_name VARCHAR(100) NULL,
  email        VARCHAR(64)  NULL,
  is_unknown   TINYINT      NOT NULL DEFAULT 0 COMMENT '1=未知成员占位',
  PRIMARY KEY (teacher_id),
  KEY idx_college (college_id),
  KEY idx_title (title)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-教师';

-- 未知成员
INSERT INTO edu_dw.dim_teacher (teacher_id, teacher_no, teacher_name, title, college_id, college_name, is_unknown)
VALUES (-1, 'UNKNOWN', '未知教师', NULL, NULL, NULL, 1);

INSERT INTO edu_dw.dim_teacher
  (teacher_id, teacher_no, teacher_name, title, college_id, college_name, email, is_unknown)
SELECT CAST(t.teacher_id AS UNSIGNED), TRIM(t.teacher_no), TRIM(t.teacher_name), TRIM(t.title),
       CAST(t.college_id AS UNSIGNED), c.college_name, TRIM(t.email), 0
FROM edu_dw.ods_teacher t
LEFT JOIN edu_dw.dim_college c ON c.college_id = CAST(t.college_id AS UNSIGNED)
WHERE CAST(t.teacher_id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 8) 班次维 dim_schedule（含 -1 未知班次）
--    一个教学班 = 学期 × 课程 × 班次号
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_schedule;
CREATE TABLE edu_dw.dim_schedule (
  schedule_id    BIGINT       NOT NULL,
  term_id        INT          NULL,
  course_id      INT          NULL,
  course_name    VARCHAR(100) NULL,
  credit         DECIMAL(3,1) NULL,
  teacher_id     BIGINT       NULL,
  teacher_name   VARCHAR(64)  NULL,
  class_no       TINYINT      NULL COMMENT '班次号',
  max_count      INT          NULL,
  current_count  INT          NULL,
  fill_rate      DECIMAL(6,4) NULL COMMENT '已选/容量',
  is_unknown     TINYINT      NOT NULL DEFAULT 0,
  PRIMARY KEY (schedule_id),
  KEY idx_term (term_id),
  KEY idx_course (course_id),
  KEY idx_teacher (teacher_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-教学班（班次）';

INSERT INTO edu_dw.dim_schedule
  (schedule_id, term_id, course_id, course_name, credit, teacher_id, teacher_name,
   class_no, max_count, current_count, fill_rate, is_unknown)
VALUES (-1, NULL, NULL, '未知班次', NULL, -1, '未知教师', NULL, NULL, NULL, NULL, 1);

INSERT INTO edu_dw.dim_schedule
  (schedule_id, term_id, course_id, course_name, credit, teacher_id, teacher_name,
   class_no, max_count, current_count, fill_rate, is_unknown)
SELECT CAST(s.schedule_id AS UNSIGNED), CAST(s.term_id AS UNSIGNED),
       CAST(s.course_id AS UNSIGNED), c.course_name, c.credit,
       CAST(s.teacher_id AS UNSIGNED), t.teacher_name,
       CAST(s.class_no AS UNSIGNED),
       CAST(s.max_count AS UNSIGNED), CAST(s.current_count AS UNSIGNED),
       ROUND(CAST(s.current_count AS UNSIGNED) / NULLIF(CAST(s.max_count AS UNSIGNED), 0), 4),
       0
FROM edu_dw.ods_course_schedule s
LEFT JOIN edu_dw.dim_course c  ON c.course_id  = CAST(s.course_id AS UNSIGNED)
LEFT JOIN edu_dw.dim_teacher t ON t.teacher_id = CAST(s.teacher_id AS UNSIGNED)
WHERE CAST(s.schedule_id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 9) 学生维 dim_student（含 -1 未知学生）
--    清洗：TRIM 姓名、性别字典翻译、学籍状态取异动表最新一条
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dim_student;
CREATE TABLE edu_dw.dim_student (
  student_id     BIGINT       NOT NULL,
  student_no     VARCHAR(32)  NULL,
  student_name   VARCHAR(64)  NULL COMMENT '已 TRIM（原始脏值在 ODS）',
  gender         TINYINT      NULL,
  gender_name    VARCHAR(8)   NULL,
  class_id       INT          NULL,
  class_name     VARCHAR(64)  NULL,
  major_name     VARCHAR(100) NULL,
  college_name   VARCHAR(100) NULL,
  enroll_year    SMALLINT     NULL,
  student_status TINYINT      NOT NULL DEFAULT 1 COMMENT '1正常/2休学/3退学（取异动最新）',
  status_name    VARCHAR(16)  NULL,
  has_id_card    TINYINT      NOT NULL DEFAULT 1 COMMENT '0=无身份证（哈希为NULL）',
  is_unknown     TINYINT      NOT NULL DEFAULT 0,
  PRIMARY KEY (student_id),
  KEY idx_class (class_id),
  KEY idx_status (student_status),
  KEY idx_enroll_year (enroll_year)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='维度-学生（已清洗）';

-- 未知成员
INSERT INTO edu_dw.dim_student
  (student_id, student_no, student_name, gender, gender_name, class_id, class_name,
   major_name, college_name, enroll_year, student_status, status_name, has_id_card, is_unknown)
VALUES (-1, 'UNKNOWN', '未知学生', NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        1, '正常', 0, 1);

INSERT INTO edu_dw.dim_student
  (student_id, student_no, student_name, gender, gender_name,
   class_id, class_name, major_name, college_name, enroll_year,
   student_status, status_name, has_id_card, is_unknown)
SELECT CAST(s.student_id AS UNSIGNED),
       TRIM(s.student_no),
       TRIM(s.student_name),                              -- ← 清洗尾空格
       CAST(s.gender AS UNSIGNED),
       gd.dict_label,
       CAST(s.class_id AS UNSIGNED), cl.class_name, cl.major_name, cl.college_name,
       cl.enroll_year,
       IFNULL(sc.new_status, 1),                          -- 默认 1=正常
       IFNULL(sd.dict_label, '正常'),
       IF(s.id_card_hash IS NULL, 0, 1),
       0
FROM edu_dw.ods_student s
LEFT JOIN edu_dw.dim_class cl ON cl.class_id = CAST(s.class_id AS UNSIGNED)
LEFT JOIN edu_dw.ods_sys_dict gd ON gd.dict_type = 'sex' AND gd.dict_value = s.gender
-- 学籍状态：取该学生「异动最新一条」的 new_status
LEFT JOIN (
  SELECT student_id, new_status,
         ROW_NUMBER() OVER (PARTITION BY student_id
                            ORDER BY operate_time DESC, CAST(id AS UNSIGNED) DESC) rn
  FROM edu_dw.ods_student_status_change
  WHERE deleted_at = '1970-01-01 00:00:00'
) sc ON sc.student_id = s.student_id AND sc.rn = 1
LEFT JOIN edu_dw.ods_sys_dict sd
       ON sd.dict_type = 'student_status'
      AND sd.dict_value = CAST(IFNULL(sc.new_status, 1) AS CHAR)
WHERE CAST(s.student_id AS UNSIGNED) > 0;


-- ---------------------------------------------------------------------
-- 验收：8 张维度表行数
-- ---------------------------------------------------------------------
SELECT 'dim_date' t, COUNT(*) cnt FROM edu_dw.dim_date
UNION ALL SELECT 'dim_term',      COUNT(*) FROM edu_dw.dim_term
UNION ALL SELECT 'dim_college',   COUNT(*) FROM edu_dw.dim_college
UNION ALL SELECT 'dim_major',     COUNT(*) FROM edu_dw.dim_major
UNION ALL SELECT 'dim_class',     COUNT(*) FROM edu_dw.dim_class
UNION ALL SELECT 'dim_classroom', COUNT(*) FROM edu_dw.dim_classroom
UNION ALL SELECT 'dim_course',    COUNT(*) FROM edu_dw.dim_course
UNION ALL SELECT 'dim_teacher',   COUNT(*) FROM edu_dw.dim_teacher
UNION ALL SELECT 'dim_schedule',  COUNT(*) FROM edu_dw.dim_schedule
UNION ALL SELECT 'dim_student',   COUNT(*) FROM edu_dw.dim_student;
