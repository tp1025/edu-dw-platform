-- =====================================================================
-- 批量修复 deleted_at：17 张表一次跑完
-- 三种方式任选其一（推荐方式 2）
-- =====================================================================


-- =====================================================================
-- 方式 1（最快）：拼成一条长 SQL，复制一个单元格粘贴后执行
-- =====================================================================
SET SESSION group_concat_max_len = 102400;   -- 默认 1024 会截断，必须放大

SELECT GROUP_CONCAT(
         CONCAT('ALTER TABLE `', TABLE_SCHEMA, '`.`', TABLE_NAME,
                '` MODIFY COLUMN `deleted_at` DATETIME NOT NULL DEFAULT ''1970-01-01 00:00:00''')
         SEPARATOR ';\n'
       ) AS batch_sql
FROM information_schema.COLUMNS
WHERE COLUMN_NAME = 'deleted_at'
  AND TABLE_SCHEMA IN ('edu_normal','edu_online')
  AND (IS_NULLABLE = 'YES' OR COLUMN_DEFAULT IS NULL);

-- 用法：点住 batch_sql 那一格 → 右键「复制」（不是复制整行）→ 粘到新查询页 →
--       末尾补一个分号 → F9。一次执行 17 条 ALTER。
-- 说明：SEPARATOR ';\n' 让每条之间用「分号+换行」隔开，粘出来就是可执行的多语句。


-- =====================================================================
-- 方式 2（推荐）：存储过程 + 动态 SQL，一条 CALL 跑完
--   ① 用游标遍历 information_schema 查出的表名
--   ② 用 PREPARE / EXECUTE 执行拼出来的 ALTER
--   ③ 每执行一张打印一行 OK，最后自动清理自己
--   注意：HeidiSQL 支持 DELIMITER，直接整段粘贴执行即可
-- =====================================================================
DROP PROCEDURE IF EXISTS edu_normal.sp_fix_deleted_at;

DELIMITER $$

CREATE PROCEDURE edu_normal.sp_fix_deleted_at()
BEGIN
  DECLARE v_done INT DEFAULT 0;
  DECLARE v_sql  VARCHAR(500);

  DECLARE cur CURSOR FOR
    SELECT CONCAT('ALTER TABLE `', TABLE_SCHEMA, '`.`', TABLE_NAME,
                  '` MODIFY COLUMN `deleted_at` DATETIME NOT NULL DEFAULT ''1970-01-01 00:00:00''')
    FROM information_schema.COLUMNS
    WHERE COLUMN_NAME = 'deleted_at'
      AND TABLE_SCHEMA IN ('edu_normal','edu_online')
      AND (IS_NULLABLE = 'YES' OR COLUMN_DEFAULT IS NULL)
    ORDER BY TABLE_SCHEMA, TABLE_NAME;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

  OPEN cur;

  read_loop: LOOP
    FETCH cur INTO v_sql;
    IF v_done = 1 THEN
      LEAVE read_loop;
    END IF;

    SET @s = v_sql;
    PREPARE stmt FROM @s;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;

    SELECT CONCAT('OK → ', v_sql) AS progress;
  END LOOP;

  CLOSE cur;
END$$

DELIMITER ;

CALL edu_normal.sp_fix_deleted_at();

DROP PROCEDURE edu_normal.sp_fix_deleted_at;


-- =====================================================================
-- 方式 3：HeidiSQL 结果网格整列复制
--   选中 fix_sql 列的所有行（点第一格，Shift+点最后一格）→ Ctrl+C →
--   粘到新查询页。注意：网格复制会带 tab 分隔符和可能带表头，
--   粘进去后要删掉表头那一行。**不如方式 1/2 干净**。
-- =====================================================================


-- =====================================================================
-- 执行后：验证（三条都要过）
-- =====================================================================

-- ① 还有没有漏网的（期望 0）
SELECT COUNT(*) AS still_bad
FROM information_schema.COLUMNS
WHERE COLUMN_NAME = 'deleted_at'
  AND TABLE_SCHEMA IN ('edu_normal','edu_online')
  AND (IS_NULLABLE = 'YES' OR COLUMN_DEFAULT IS NULL);

-- ② 全部 17 张表都应该是 NOT NULL + 哨兵默认值
SELECT TABLE_SCHEMA, TABLE_NAME, IS_NULLABLE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE COLUMN_NAME = 'deleted_at' AND TABLE_SCHEMA IN ('edu_normal','edu_online')
ORDER BY 1,2;

-- ③ 唯一键真的生效了：插两条相同 college_code，第二条必须报 1062
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('ZZTEST', '测试学院A');
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('ZZTEST', '测试学院B');
-- 期望：ERROR 1062 Duplicate entry 'ZZTEST-1970-01-01 00:00:00' for key 'college.uk_college_code'

-- ④ 软删除后能重建同编码（期望成功）
UPDATE edu_normal.college SET deleted_at = NOW() WHERE college_code = 'ZZTEST';
INSERT INTO edu_normal.college (college_code, college_name) VALUES ('ZZTEST', '重建的测试学院');
SELECT college_code, college_name, deleted_at FROM edu_normal.college WHERE college_code = 'ZZTEST';

-- ⑤ 清理测试数据
DELETE FROM edu_normal.college WHERE college_code = 'ZZTEST';


-- =====================================================================
-- 附：最后两件收尾（都建议在灌数前做）
-- =====================================================================

-- ① student 唯一键补上 deleted_at（软删后同身份证可重新建档）
ALTER TABLE edu_normal.student
  DROP INDEX uk_id_card_hash,
  ADD UNIQUE KEY uk_id_card_hash (id_card_hash, deleted_at);

-- ② 可选：course_schedule 加 class_no，支持「同一老师同一课程同学期开多个班」
--   若不加，造数时必须保证「一师一课一学期只有一班」
-- ALTER TABLE edu_online.course_schedule
--   ADD COLUMN class_no TINYINT NOT NULL DEFAULT 1 COMMENT '同课程同学期内的班次号' AFTER teacher_id,
--   DROP INDEX uk_course_teacher_term,
--   ADD UNIQUE KEY uk_course_term_class (term_id, course_id, class_no, deleted_at);
