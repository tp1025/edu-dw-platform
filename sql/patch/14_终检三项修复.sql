-- =====================================================================
-- 终检三项修复：A 审计字段命名统一 / B 删冗余索引 / C 补 class_no
-- 环境：MySQL 26.10 @ 127.0.0.1:3307
-- 前提：相关表 0 行（sys_dict 41 行字典不受影响）
-- 用法：按 A → B → C 顺序执行，每段后面有验证
-- =====================================================================


-- =====================================================================
-- 先看现状：还有哪些表在用 create_time / update_time
--   （如果某张表已经改过，下面 A 段会报 1054，跳过它即可）
-- =====================================================================
SELECT TABLE_SCHEMA, TABLE_NAME,
       SUM(COLUMN_NAME='create_time') AS has_c_time,
       SUM(COLUMN_NAME='update_time') AS has_u_time
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online')
  AND COLUMN_NAME IN ('create_time','update_time')
GROUP BY 1,2 ORDER BY 1,2;
-- 应该有 11 行，且 has_c_time=1 / has_u_time=1


-- =====================================================================
-- A. 审计字段命名统一：create_time → created_at，update_time → updated_at
--    共 11 张表 × 2 列 = 22 条（edu_normal 6 张 + edu_online 5 张）
--    RENAME COLUMN 是 INSTANT 操作，不重建表
-- =====================================================================

-- ---- edu_normal（6 张）----
ALTER TABLE edu_normal.class   RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_normal.class   RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_normal.college RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_normal.college RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_normal.course  RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_normal.course  RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_normal.major   RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_normal.major   RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_normal.student RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_normal.student RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_normal.teacher RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_normal.teacher RENAME COLUMN update_time TO updated_at;

-- ---- edu_online（5 张）----
ALTER TABLE edu_online.attendance      RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_online.attendance      RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_online.course_schedule RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_online.course_schedule RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_online.schedule_time   RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_online.schedule_time   RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_online.score           RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_online.score           RENAME COLUMN update_time TO updated_at;

ALTER TABLE edu_online.selection       RENAME COLUMN create_time TO created_at;
ALTER TABLE edu_online.selection       RENAME COLUMN update_time TO updated_at;

-- 验证 A：应该有 0 行残留
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online')
  AND COLUMN_NAME IN ('create_time','update_time');
-- 期望：空结果

-- 验证 A：17 张表全部具备 created_at + updated_at
SELECT COUNT(*) AS tables_with_both FROM (
  SELECT TABLE_SCHEMA, TABLE_NAME
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA IN ('edu_normal','edu_online')
    AND COLUMN_NAME IN ('created_at','updated_at')
  GROUP BY 1,2 HAVING COUNT(*) = 2
) t;
-- 期望：17


-- =====================================================================
-- B. 删掉 2 个冗余索引
--   reward_punish.idx_student_rp 被 uk_rp 最左前缀(student_id)覆盖
--   sys_dict.idx_dict_type       被 uk_type_value 最左前缀(dict_type)覆盖
-- =====================================================================
ALTER TABLE edu_normal.reward_punish DROP INDEX idx_student_rp;
ALTER TABLE edu_normal.sys_dict      DROP INDEX idx_dict_type;

-- 验证 B：应返回空（没有冗余索引了）
SELECT table_schema, table_name, redundant_index_name, dominant_index_name
FROM sys.schema_redundant_indexes
WHERE table_schema IN ('edu_normal','edu_online');


-- =====================================================================
-- C. course_schedule 补 class_no，支持「同一老师同一课程同学期开多个班」
--   原唯一键 (course_id, teacher_id, term_id, deleted_at) 的副作用：
--     一师一课一学期只能开 1 个班 → 造数时必须保证不重复
--   新唯一键 (term_id, course_id, class_no, deleted_at)：
--     班级序号区分班次，teacher 只作普通字段
-- =====================================================================
ALTER TABLE edu_online.course_schedule
  ADD COLUMN class_no TINYINT NOT NULL DEFAULT 1
      COMMENT '同课程同学期内的班次号（1、2、3…）' AFTER teacher_id,
  DROP INDEX uk_course_teacher_term,
  ADD UNIQUE KEY uk_course_term_class (term_id, course_id, class_no, deleted_at),
  ADD CONSTRAINT ck_cs_class_no CHECK (class_no >= 1);

-- 验证 C：字段存在 + 唯一键含 term_id
SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME='course_schedule' AND COLUMN_NAME='class_no';

SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME='course_schedule' AND NON_UNIQUE=0
GROUP BY INDEX_NAME;
-- 期望：PRIMARY(schedule_id,term_id) + uk_course_term_class(term_id,course_id,class_no,deleted_at)

-- 验证 C：分区仍然正常（改唯一键不影响分区）
SELECT PARTITION_METHOD, COUNT(*) parts FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME='course_schedule' AND PARTITION_NAME IS NOT NULL
GROUP BY PARTITION_METHOD;


-- =====================================================================
-- 最终终检：一把梭（全部期望通过）
-- =====================================================================

-- ① 表数量：edu_normal 11 / edu_online 6
SELECT TABLE_SCHEMA, COUNT(*) tbls FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') GROUP BY 1;

-- ② 分区：5 张表 × 5 分区，全 RANGE
SELECT TABLE_NAME, PARTITION_METHOD, COUNT(*) parts FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') AND PARTITION_NAME IS NOT NULL
GROUP BY 1,2 ORDER BY 1;

-- ③ 外键：0
SELECT COUNT(*) AS fk FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA IN ('edu_normal','edu_online') AND CONSTRAINT_TYPE='FOREIGN KEY';

-- ④ 业务唯一键全部含 deleted_at（结果应只有各表 PRIMARY）
SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') AND NON_UNIQUE=0
GROUP BY 1,2,3
HAVING SUM(COLUMN_NAME='deleted_at') = 0 AND INDEX_NAME <> 'PRIMARY';
-- 期望：空结果

-- ⑤ CHECK 总数：应 ≥ 16（原 15 + ck_cs_class_no）
SELECT COUNT(*) AS check_total FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA IN ('edu_normal','edu_online') AND CONSTRAINT_TYPE='CHECK';

-- ⑥ 实测：CHECK 是否真的拦（期望 ERROR 3819）
INSERT INTO edu_normal.classroom (building_name, room_no, capacity, room_type)
VALUES ('测试楼','X001', -5, 1);

-- ⑦ 实测：分区裁剪（partitions 列应只显示 p202601）
EXPLAIN SELECT * FROM edu_online.selection WHERE term_id = 202601;

-- ⑧ 实测：软删除后能重建同编码（期望成功）
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('SMOKE','冒烟学院');
UPDATE edu_normal.college SET deleted_at = NOW() WHERE college_code='SMOKE';
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('SMOKE','重建学院');
DELETE FROM edu_normal.college WHERE college_code='SMOKE';
