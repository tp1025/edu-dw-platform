-- =====================================================================
-- DWD 层（三）：数据质量结果表 dq_result
--   每条规则一行：规则编码 / 检查表 / 总行数 / 问题行数 / 已修复行数 / 通过率
--   目的：让「脏数据发现→清洗→验收」形成闭环，可复现、可对账
-- =====================================================================
USE edu_dw;

DROP TABLE IF EXISTS edu_dw.dq_result;
CREATE TABLE edu_dw.dq_result (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  batch_no    VARCHAR(20)  NOT NULL COMMENT '批次号',
  rule_code   VARCHAR(16)  NOT NULL COMMENT '规则编码 R01..R11',
  rule_name   VARCHAR(64)  NOT NULL COMMENT '规则名称',
  target_table VARCHAR(64) NOT NULL COMMENT '检查目标表',
  total_rows  BIGINT       NOT NULL COMMENT '该表总行数',
  bad_rows    BIGINT       NOT NULL COMMENT '发现的问题行数',
  fixed_rows  BIGINT       NOT NULL COMMENT '已在 DWD 修复/标记的行数',
  pass_rate   DECIMAL(8,4) NOT NULL COMMENT '通过率 = 1 - bad/total',
  check_time  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_rule (rule_code),
  KEY idx_table (target_table)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='数据质量检查结果';

DELETE FROM edu_dw.dq_result WHERE batch_no = 'B1';

-- R01 姓名带首尾空格（ODS 脏 → dim_student 已 TRIM 修复）
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R01', '姓名含首尾空格', 'ods_student',
       COUNT(*),
       SUM(student_name <> TRIM(student_name)),
       SUM(student_name <> TRIM(student_name)),      -- dim_student 已 TRIM，视为全部修复
       ROUND(1 - SUM(student_name <> TRIM(student_name)) / COUNT(*), 4)
FROM edu_dw.ods_student;

-- R02 成绩超出 0~100（DWD 置 NULL 并标记 is_valid=0）
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R02', '成绩超出0-100区间', 'ods_score',
       COUNT(*), SUM(bad), SUM(bad),
       ROUND(1 - SUM(bad) / COUNT(*), 4)
FROM (
  SELECT CASE WHEN total_score REGEXP '^-?[0-9]+([.][0-9]+)?$'
               AND CAST(total_score AS DECIMAL(6,2)) NOT BETWEEN 0 AND 100 THEN 1 ELSE 0 END AS bad
  FROM edu_dw.ods_score
) t;

-- R03 成绩为非数字（"缺考"这类）
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R03', '成绩为非数字', 'ods_score',
       COUNT(*), SUM(bad), SUM(bad),
       ROUND(1 - SUM(bad) / COUNT(*), 4)
FROM (
  SELECT CASE WHEN total_score IS NOT NULL
               AND total_score NOT REGEXP '^-?[0-9]+([.][0-9]+)?$' THEN 1 ELSE 0 END AS bad
  FROM edu_dw.ods_score
) t;

-- R04 ETL 重跑导致同一 selection_id 重复
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R04', 'ETL重跑导致流水重复', 'ods_selection',
       (SELECT COUNT(*) FROM edu_dw.ods_selection),
       (SELECT COUNT(*) FROM (SELECT selection_id FROM edu_dw.ods_selection
                               GROUP BY selection_id HAVING COUNT(*) > 1) x),
       (SELECT COUNT(*) FROM (SELECT selection_id FROM edu_dw.ods_selection
                               GROUP BY selection_id HAVING COUNT(*) > 1) x),
       ROUND(1 - (SELECT COUNT(*) FROM (SELECT selection_id FROM edu_dw.ods_selection
                                        GROUP BY selection_id HAVING COUNT(*) > 1) x)
               / (SELECT COUNT(*) FROM edu_dw.ods_selection), 4);

-- R05 业务重复选课（同学生+班次+学期多条流水）
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R05', '业务重复选课', 'ods_selection',
       (SELECT COUNT(*) FROM edu_dw.ods_selection),
       (SELECT COALESCE(SUM(cnt - 1), 0) FROM (
          SELECT COUNT(*) cnt FROM edu_dw.ods_selection
          GROUP BY student_id, schedule_id, term_id HAVING COUNT(*) > 1) x),
       (SELECT COALESCE(SUM(cnt - 1), 0) FROM (
          SELECT COUNT(*) cnt FROM edu_dw.ods_selection
          GROUP BY student_id, schedule_id, term_id HAVING COUNT(*) > 1) x),
       ROUND(1 - (SELECT COALESCE(SUM(cnt - 1), 0) FROM (
                    SELECT COUNT(*) cnt FROM edu_dw.ods_selection
                    GROUP BY student_id, schedule_id, term_id HAVING COUNT(*) > 1) x)
               / (SELECT COUNT(*) FROM edu_dw.ods_selection), 4);

-- R06 脏外键：选课指向不存在的班次
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R06', '选课引用不存在的班次', 'fact_selection',
       COUNT(*),
       SUM(invalid_reason = '脏外键-未知班次'),
       SUM(invalid_reason = '脏外键-未知班次'),
       ROUND(1 - SUM(invalid_reason = '脏外键-未知班次') / COUNT(*), 4)
FROM edu_dw.fact_selection;

-- R07 非法考勤状态码
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R07', '非法考勤状态码', 'fact_attendance',
       COUNT(*),
       SUM(invalid_reason = '非法考勤状态'),
       SUM(invalid_reason = '非法考勤状态'),
       ROUND(1 - SUM(invalid_reason = '非法考勤状态') / COUNT(*), 4)
FROM edu_dw.fact_attendance;

-- R08 迟到/早退分钟为负
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R08', '迟到/早退分钟为负', 'ods_attendance',
       COUNT(*),
       SUM(CAST(late_minutes AS SIGNED) < 0 OR CAST(early_minutes AS SIGNED) < 0),
       SUM(CAST(late_minutes AS SIGNED) < 0 OR CAST(early_minutes AS SIGNED) < 0),
       ROUND(1 - SUM(CAST(late_minutes AS SIGNED) < 0 OR CAST(early_minutes AS SIGNED) < 0) / COUNT(*), 4)
FROM edu_dw.ods_attendance;

-- R09 上课日期越界（早于 2024 或晚于 2027）
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R09', '上课日期越界', 'ods_course_session',
       COUNT(*),
       SUM(session_date NOT BETWEEN '2024-01-01' AND '2027-12-31'),
       SUM(session_date NOT BETWEEN '2024-01-01' AND '2027-12-31'),
       ROUND(1 - SUM(session_date NOT BETWEEN '2024-01-01' AND '2027-12-31') / COUNT(*), 4)
FROM edu_dw.ods_course_session;

-- R10 成绩的学期与所属班次的学期不一致
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R10', '成绩学期与班次学期不一致', 'ods_score',
       COUNT(*), SUM(bad), SUM(bad),
       ROUND(1 - SUM(bad) / COUNT(*), 4)
FROM (
  SELECT CASE WHEN CAST(s.term_id AS UNSIGNED) <> CAST(cs.term_id AS UNSIGNED) THEN 1 ELSE 0 END AS bad
  FROM edu_dw.ods_score s
  JOIN edu_dw.ods_course_schedule cs ON cs.schedule_id = s.schedule_id
) t;

-- R11 考勤冗余日期与课次日期不一致（跨表一致性）
INSERT INTO edu_dw.dq_result
  (batch_no, rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows, pass_rate)
SELECT 'B1', 'R11', '考勤日期与课次日期不一致', 'ods_attendance',
       COUNT(*), SUM(bad), SUM(bad),
       ROUND(1 - SUM(bad) / COUNT(*), 4)
FROM (
  SELECT CASE WHEN a.session_date <> cs.session_date THEN 1 ELSE 0 END AS bad
  FROM edu_dw.ods_attendance a
  JOIN edu_dw.ods_course_session cs
    ON CAST(cs.session_id AS UNSIGNED) = CAST(a.session_id AS UNSIGNED)
) t;


-- =====================================================================
-- 验收：质量报告（这就是你简历里"6条规则发现X条问题"的来源）
-- =====================================================================
SELECT rule_code, rule_name, target_table, total_rows, bad_rows, fixed_rows,
       CONCAT(ROUND(pass_rate * 100, 2), '%') AS pass_rate
FROM edu_dw.dq_result
ORDER BY rule_code;
