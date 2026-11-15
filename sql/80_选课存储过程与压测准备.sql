-- =====================================================================
-- 选课存储过程 + 并发压测准备
-- 目标：证明「500 并发下零超选 + 零重复选课」
-- 核心设计（面试必答）：
--   ① 原子扣减：UPDATE ... SET current_count = current_count + 1
--                WHERE current_count < max_count
--      → 「判断 + 扣减」在一条语句里完成，靠 InnoDB 行锁保证原子性
--      → 影响行数 = 0 说明没抢到（要么满、要么班次不存在）
--   ② INSERT 的唯一键 uk_active 兜底：同一学生同一班次只能有一条有效选课
--   ③ 全部在一个事务里：INSERT 失败 → ROLLBACK，扣减自动回退
-- =====================================================================
USE edu_online;

DROP PROCEDURE IF EXISTS edu_online.sp_select_course;

DELIMITER $$

CREATE PROCEDURE edu_online.sp_select_course(
  IN  p_student_id  BIGINT,
  IN  p_schedule_id BIGINT,
  IN  p_term_id     INT,
  OUT p_code        INT,          -- 0成功 / 1名额满 / 2重复选课 / 3班次不存在
  OUT p_msg         VARCHAR(64)
)
BEGIN
  DECLARE v_affected INT DEFAULT 0;
  DECLARE v_exists   INT DEFAULT 0;

  -- 任何异常（含唯一键冲突 1062）都回滚，保证「扣减」不会白扣
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    GET DIAGNOSTICS CONDITION 1 @errno = MYSQL_ERRNO;
    IF @errno = 1062 THEN
      SET p_code = 2, p_msg = '已选过该班次（唯一键拦截）';
    ELSE
      SET p_code = -1, p_msg = CONCAT('SQL异常已回滚，errno=', @errno);
    END IF;
  END;

  START TRANSACTION;

  -- ① 原子扣减：一步完成「判断容量 + 占位」
  UPDATE edu_online.course_schedule
     SET current_count = current_count + 1
   WHERE schedule_id = p_schedule_id
     AND term_id     = p_term_id
     AND current_count < max_count;

  SET v_affected = ROW_COUNT();

  IF v_affected = 0 THEN
    -- 区分「名额满」和「班次不存在」
    SELECT COUNT(*) INTO v_exists
    FROM edu_online.course_schedule
    WHERE schedule_id = p_schedule_id AND term_id = p_term_id;

    IF v_exists = 0 THEN
      SET p_code = 3, p_msg = '班次不存在';
    ELSE
      SET p_code = 1, p_msg = '名额已满';
    END IF;
    ROLLBACK;
  ELSE
    -- ② 插入选课流水（唯一键 active_flag 兜底防重复）
    INSERT INTO edu_online.selection
      (student_id, schedule_id, term_id, select_status, creator, deleted_at, created_at)
    VALUES
      (p_student_id, p_schedule_id, p_term_id, 1, p_student_id, '1970-01-01 00:00:00', NOW());

    SET p_code = 0, p_msg = '选课成功';
    COMMIT;
  END IF;
END$$

DELIMITER ;

SELECT '存储过程已创建' AS st;


-- =====================================================================
-- 测试用 CODES 字典（压测时统计各类返回，方便展示）
-- =====================================================================
DROP TABLE IF EXISTS edu_online.sp_result;
CREATE TABLE edu_online.sp_result (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  student_id  BIGINT,
  schedule_id BIGINT,
  code        INT,
  msg         VARCHAR(64),
  created_at  DATETIME(3) DEFAULT NOW(3)
) ENGINE=InnoDB;


-- =====================================================================
-- 场景准备：
--   场景 A（重复选课）：班次 1，容量 1000，用一个固定学生并发 500 次
--   场景 B（超卖）：    班次 2，容量压到 150，用 500 个不同学生抢
-- =====================================================================
-- A：班次 1 恢复成"有余量"的状态
UPDATE edu_online.course_schedule SET max_count = 1000, current_count = 0
 WHERE schedule_id = 1 AND term_id = 202501;

-- B：班次 2 容量设 150（远小于并发 500，制造抢购）
UPDATE edu_online.course_schedule SET max_count = 150, current_count = 0
 WHERE schedule_id = 2 AND term_id = 202501;

-- 清掉这两个班次已有的选课（避免干扰）
DELETE FROM edu_online.selection WHERE term_id = 202501 AND schedule_id IN (1, 2);

SELECT schedule_id, term_id, max_count, current_count FROM edu_online.course_schedule
 WHERE schedule_id IN (1, 2) AND term_id = 202501;


-- =====================================================================
-- 验证 SQL（压测后执行）
-- =====================================================================
-- ① 零超选：必须为 0 行
SELECT COUNT(*) AS oversold_schedules
FROM edu_online.course_schedule
WHERE current_count > max_count;

-- ② 零重复：必须为 0 行
SELECT COUNT(*) AS dup_selection
FROM (SELECT student_id, schedule_id, term_id
      FROM edu_online.selection
      WHERE deleted_at = '1970-01-01 00:00:00'
      GROUP BY student_id, schedule_id, term_id
      HAVING COUNT(*) > 1) t;

-- ③ current_count 与实际选课数是否一致（对账）
SELECT cs.schedule_id, cs.max_count, cs.current_count,
       (SELECT COUNT(*) FROM edu_online.selection s
         WHERE s.schedule_id = cs.schedule_id AND s.term_id = cs.term_id
           AND s.select_status = 1 AND s.deleted_at = '1970-01-01 00:00:00') AS real_cnt,
       cs.current_count -
       (SELECT COUNT(*) FROM edu_online.selection s
         WHERE s.schedule_id = cs.schedule_id AND s.term_id = cs.term_id
           AND s.select_status = 1 AND s.deleted_at = '1970-01-01 00:00:00') AS diff
FROM edu_online.course_schedule cs
WHERE cs.schedule_id IN (1, 2) AND cs.term_id = 202501;
