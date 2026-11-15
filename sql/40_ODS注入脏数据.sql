-- =====================================================================
-- 往 ODS 注入脏数据（7 类，共约 20 行受影响）
-- 目的：让 DWD 清洗有真实对象，且「发现几条、清洗几条」可核对
-- 特点：每次注入都记录原值到 edu_dw.dq_injected_dirty，DWD 可据此验收
-- ⚠️ 本脚本只跑一次（重复跑会重复注入，但不会破坏结构）
-- =====================================================================
USE edu_dw;

-- ---------------------------------------------------------------------
-- 0) 建「注入记录表」：记下每条脏数据的原值和脏值，便于 DWD 前后对比
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.dq_injected_dirty;
CREATE TABLE edu_dw.dq_injected_dirty (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  batch_no    VARCHAR(20)  NOT NULL COMMENT '批次号',
  table_name  VARCHAR(64)  NOT NULL,
  row_id      BIGINT       NULL COMMENT 'ODS 行号（定位用）',
  key_col     VARCHAR(64)  NULL COMMENT '业务键字段名',
  key_val     VARCHAR(64)  NULL COMMENT '业务键值',
  column_name VARCHAR(64)  NOT NULL COMMENT '被污染的字段',
  old_value   VARCHAR(255) NULL COMMENT '注入前的正确值',
  new_value   VARCHAR(255) NULL COMMENT '注入的脏值',
  dirty_type  VARCHAR(32)  NOT NULL COMMENT '脏数据类别',
  injected_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_type (dirty_type),
  KEY idx_table (table_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='脏数据注入记录（DWD 验收用）';


-- ---------------------------------------------------------------------
-- 1) 成绩超范围：-5 和 150（各 1 条）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_score', row_id, 'score_id', score_id, 'total_score', total_score,
       CASE row_id WHEN 1 THEN '-5.00' ELSE '150.00' END, '成绩超范围'
FROM edu_dw.ods_score WHERE row_id IN (1, 2);

UPDATE edu_dw.ods_score SET total_score = '-5.00'   WHERE row_id = 1 AND total_score <> '-5.00';
UPDATE edu_dw.ods_score SET total_score = '150.00'  WHERE row_id = 2 AND total_score <> '150.00';

-- ---------------------------------------------------------------------
-- 2) 成绩非数字：'缺考'（1 条）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_score', row_id, 'score_id', score_id, 'total_score', total_score, '缺考', '成绩非数字'
FROM edu_dw.ods_score WHERE row_id = 3;

UPDATE edu_dw.ods_score SET total_score = '缺考' WHERE row_id = 3 AND total_score <> '缺考';

-- ---------------------------------------------------------------------
-- 3) 完全重复行（模拟 ETL 重跑，3 条）：selection_id 也相同
--    DWD 处理方式：按 selection_id 去重（DISTINCT / ROW_NUMBER）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_selection', row_id, 'selection_id', selection_id, '(整行)', '单条', '重复抽取一份',
       'ETL重跑重复'
FROM edu_dw.ods_selection WHERE row_id IN (1, 2, 3);

INSERT INTO edu_dw.ods_selection
  (selection_id, student_id, schedule_id, term_id, select_status, creator, remark,
   deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT selection_id, student_id, schedule_id, term_id, select_status, creator,
       CONCAT(IFNULL(remark,''), '[重复抽取]'),
       deleted_at, created_at, updated_at, src_table, NOW(), dt
FROM edu_dw.ods_selection WHERE row_id IN (1, 2, 3);

-- ---------------------------------------------------------------------
-- 4) 业务重复（模拟源系统真的产生了两条流水，2 条）：selection_id 不同
--    DWD 处理方式：按 (student_id, schedule_id, term_id) 取一条 + 口径决策
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_selection', row_id, 'selection_id', selection_id, '(业务键)', '单条', '次条流水',
       '业务重复选课'
FROM edu_dw.ods_selection WHERE row_id IN (4, 5);

INSERT INTO edu_dw.ods_selection
  (selection_id, student_id, schedule_id, term_id, select_status, creator, remark,
   deleted_at, created_at, updated_at, src_table, etl_time, dt)
SELECT CONCAT(selection_id, 'D'), student_id, schedule_id, term_id, select_status, creator,
       '[同业务键的第二条流水]',
       deleted_at, created_at, updated_at, src_table, NOW(), dt
FROM edu_dw.ods_selection WHERE row_id IN (4, 5);

-- ---------------------------------------------------------------------
-- 5) 脏外键：schedule_id 指向不存在的班次（3 条）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_selection', row_id, 'selection_id', selection_id, 'schedule_id', schedule_id, '999999', '脏外键'
FROM edu_dw.ods_selection WHERE row_id IN (100, 101, 102);

UPDATE edu_dw.ods_selection SET schedule_id = '999999'
WHERE row_id IN (100, 101, 102) AND schedule_id <> '999999';

-- ---------------------------------------------------------------------
-- 6) 考勤：非法状态码 9（2 条）+ 迟到分钟数为负（2 条）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_attendance', row_id, 'att_id', att_id, 'att_status', att_status, '9', '非法状态码'
FROM edu_dw.ods_attendance WHERE row_id IN (5, 6);

UPDATE edu_dw.ods_attendance SET att_status = '9' WHERE row_id IN (5, 6) AND att_status <> '9';

INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_attendance', row_id, 'att_id', att_id, 'late_minutes', IFNULL(late_minutes,'NULL'), '-5', '数值为负'
FROM edu_dw.ods_attendance WHERE row_id IN (7, 8);

UPDATE edu_dw.ods_attendance SET late_minutes = '-5' WHERE row_id IN (7, 8) AND (late_minutes IS NULL OR late_minutes <> '-5');

-- ---------------------------------------------------------------------
-- 7) 日期越界：上课日期 1900-01-01（1 条）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_course_session', row_id, 'session_id', session_id, 'session_date',
       CAST(session_date AS CHAR), '1900-01-01', '日期越界'
FROM edu_dw.ods_course_session WHERE row_id = 1;

UPDATE edu_dw.ods_course_session SET session_date = '1900-01-01'
WHERE row_id = 1 AND session_date <> '1900-01-01';

-- ---------------------------------------------------------------------
-- 8) 跨表不一致：score.term_id 与所属班次的 term 不一致（2 条）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.dq_injected_dirty
  (batch_no, table_name, row_id, key_col, key_val, column_name, old_value, new_value, dirty_type)
SELECT 'B1', 'ods_score', row_id, 'score_id', score_id, 'term_id', term_id, '209901', '学期与班次不一致'
FROM edu_dw.ods_score WHERE row_id IN (10, 11);

UPDATE edu_dw.ods_score SET term_id = '209901' WHERE row_id IN (10, 11) AND term_id <> '209901';


-- =====================================================================
-- 验收：注入结果汇总（这是 DWD 清洗时要逐类对上的清单）
-- =====================================================================
SELECT dirty_type AS 脏数据类别, table_name AS 表, COUNT(*) AS 注入条数
FROM edu_dw.dq_injected_dirty
GROUP BY dirty_type, table_name
ORDER BY table_name, dirty_type;

-- 看一眼被污染的实际数据
SELECT '超范围成绩' AS chk, score_id, total_score FROM edu_dw.ods_score WHERE row_id IN (1,2,3)
UNION ALL SELECT '非法考勤', att_id, CONCAT(att_status,'/',IFNULL(late_minutes,'NULL')) FROM edu_dw.ods_attendance WHERE row_id IN (5,6,7,8)
UNION ALL SELECT '日期越界', session_id, CAST(session_date AS CHAR) FROM edu_dw.ods_course_session WHERE row_id = 1;

-- 重复情况统计
SELECT 'ETL重跑重复(相同selection_id)' AS chk, COUNT(*) AS cnt FROM (
  SELECT selection_id FROM edu_dw.ods_selection GROUP BY selection_id HAVING COUNT(*) > 1
) t
UNION ALL
SELECT '业务重复(相同学生+班次+学期)', COUNT(*) FROM (
  SELECT student_id, schedule_id, term_id FROM edu_dw.ods_selection
  GROUP BY student_id, schedule_id, term_id HAVING COUNT(*) > 1
) t2;
