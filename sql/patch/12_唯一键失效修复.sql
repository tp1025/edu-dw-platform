-- =====================================================================
-- 紧急修复：deleted_at 默认值是 NULL，导致全部唯一键对「活数据」失效
-- 影响：17 张表里的所有 (..., deleted_at) 唯一键
-- =====================================================================
-- 原理（一句话）：
--   MySQL 唯一索引对 NULL 不做唯一性校验（NULL ≠ NULL）。
--   你的 deleted_at 是 `DATETIME NULL DEFAULT NULL`，所以未删除的行都是 (..., NULL)，
--   任意两条都能插进去 —— 唯一键形同废纸。
--
-- 正确做法（决策 D 定的）：
--   deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00'
--   用「哨兵值」表示未删除，而不是 NULL。
-- =====================================================================


-- ---------------------------------------------------------------------
-- 步骤 1：先看有多少张表中招（期望 17 行）
-- ---------------------------------------------------------------------
SELECT TABLE_SCHEMA, TABLE_NAME, IS_NULLABLE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE COLUMN_NAME = 'deleted_at'
  AND TABLE_SCHEMA IN ('edu_normal','edu_online')
  AND (IS_NULLABLE = 'YES' OR COLUMN_DEFAULT IS NULL)
ORDER BY 1,2;


-- ---------------------------------------------------------------------
-- 步骤 2：用 SQL 生成修复语句（把结果复制出来执行）
-- ---------------------------------------------------------------------
SELECT CONCAT(
         'ALTER TABLE ', TABLE_SCHEMA, '.', TABLE_NAME,
         ' MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT ''1970-01-01 00:00:00'';'
       ) AS fix_sql
FROM information_schema.COLUMNS
WHERE COLUMN_NAME = 'deleted_at'
  AND TABLE_SCHEMA IN ('edu_normal','edu_online')
  AND (IS_NULLABLE = 'YES' OR COLUMN_DEFAULT IS NULL)
ORDER BY TABLE_SCHEMA, TABLE_NAME;


-- ---------------------------------------------------------------------
-- 步骤 3：执行步骤 2 复制出来的 17 条 ALTER（形如下面这样）
--   注意：现在除了 sys_dict(41 行字典) 之外都是 0 行，改起来是秒级。
--   sys_dict 的 41 行字典在插入时已显式写了 '1970-01-01 00:00:00'，不会冲突。
-- ---------------------------------------------------------------------
-- ALTER TABLE edu_normal.class       MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.classroom   MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.college     MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.course      MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.course_prerequisite MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.major       MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.reward_punish MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.student     MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.student_status_change MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.sys_dict    MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_normal.teacher     MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_online.attendance  MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_online.course_schedule MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_online.course_session  MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_online.schedule_time   MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_online.score       MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';
-- ALTER TABLE edu_online.selection   MODIFY COLUMN deleted_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00';


-- ---------------------------------------------------------------------
-- 步骤 4：修 student 的唯一键（它没带 deleted_at，不符合全局规则）
--   现状 uk_id_card_hash(id_card_hash) → 软删一个学生后，同身份证无法重新建档
--   注意：id_card_hash 允许 NULL（无身份证学生），NULL 不参与唯一 → 不受影响
-- ---------------------------------------------------------------------
ALTER TABLE edu_normal.student
  DROP INDEX uk_id_card_hash,
  ADD UNIQUE KEY uk_id_card_hash (id_card_hash, deleted_at);


-- ---------------------------------------------------------------------
-- 步骤 5：验证「唯一键真的生效了」——这是最重要的一步
--   ① 先确认全部 17 张表都是 NOT NULL + 哨兵默认值
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS still_bad
FROM information_schema.COLUMNS
WHERE COLUMN_NAME='deleted_at' AND TABLE_SCHEMA IN ('edu_normal','edu_online')
  AND (IS_NULLABLE='YES' OR COLUMN_DEFAULT IS NULL);
-- 期望：0

-- ② 故意插两条相同 college_code，第二条必须报 1062
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('ZZTEST', '测试学院A');
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('ZZTEST', '测试学院B');
-- 期望：ERROR 1062 (23000): Duplicate entry 'ZZTEST-1970-01-01 00:00:00' for key 'college.uk_college_code'
-- 看到 1062 就说明唯一键活了 ✅

-- ③ 清理测试数据
DELETE FROM edu_normal.college WHERE college_code='ZZTEST';

-- ④ 顺带验证「软删除后可以重建同编码」
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('ZZTEST', '测试学院A');
UPDATE edu_normal.college SET deleted_at = NOW() WHERE college_code='ZZTEST';
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('ZZTEST', '重建的测试学院');
-- 期望：成功（因为已删除那条的 deleted_at 不是哨兵值了）
SELECT college_code, college_name, deleted_at FROM edu_normal.college WHERE college_code='ZZTEST';
DELETE FROM edu_normal.college WHERE college_code='ZZTEST';
