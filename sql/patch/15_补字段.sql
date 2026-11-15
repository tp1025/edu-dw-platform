-- =====================================================================
-- 造数前最后补齐：attendance 缺 7 个字段、score 缺 3 个字段
-- 环境：MySQL 26.10 @ 127.0.0.1:3307 ｜ 前提：两表 0 行
-- 为什么必须补：
--   attendance 没有 late_minutes → 「迟到>30分钟算1次缺勤」的折算口径算不出来
--   attendance 没有 check_time   → 「未核对报表」做不出来
--   score 没有 is_manual_adjust  → 重算总评会覆盖人工改过的值（D3 决策落地缺失）
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) attendance 补齐
-- ---------------------------------------------------------------------
ALTER TABLE edu_online.attendance
  ADD COLUMN is_makeup     TINYINT      NOT NULL DEFAULT 0 COMMENT '1 事后补签' AFTER att_status,
  ADD COLUMN late_minutes  INT          NULL COMMENT '迟到分钟（仅 att_status=2 有值）' AFTER is_makeup,
  ADD COLUMN early_minutes INT          NULL COMMENT '早退分钟（仅 att_status=3 有值）' AFTER late_minutes,
  ADD COLUMN sign_method   TINYINT      NULL COMMENT '1二维码/2教师录入/3导入' AFTER att_time,
  ADD COLUMN check_by      BIGINT       NULL COMMENT '最后核对人；NULL=尚未核对' AFTER sign_method,
  ADD COLUMN check_time    DATETIME     NULL COMMENT '最后核对时间；NULL=尚未核对' AFTER check_by,
  ADD COLUMN remark        VARCHAR(300) NULL COMMENT '请假单号、补签说明' AFTER check_time,
  ADD CONSTRAINT ck_att_late        CHECK (late_minutes  IS NULL OR late_minutes  >= 0),
  ADD CONSTRAINT ck_att_early       CHECK (early_minutes IS NULL OR early_minutes >= 0),
  ADD CONSTRAINT ck_att_late_pair    CHECK (att_status = 2 OR late_minutes  IS NULL),
  ADD CONSTRAINT ck_att_early_pair   CHECK (att_status = 3 OR early_minutes IS NULL),
  ADD CONSTRAINT ck_att_check_pair   CHECK (check_time IS NULL OR check_by IS NOT NULL);

-- 验证：应看到 7 个新列 + 5 条新 CHECK
SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME='attendance' ORDER BY ORDINAL_POSITION;

SELECT CONSTRAINT_NAME FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA='edu_online' AND TABLE_NAME='attendance' AND CONSTRAINT_TYPE='CHECK';


-- ---------------------------------------------------------------------
-- 2) score 补齐
-- ---------------------------------------------------------------------
ALTER TABLE edu_online.score
  ADD COLUMN is_manual_adjust TINYINT      NOT NULL DEFAULT 0 COMMENT '0自动计算/1人工调整' AFTER score_status,
  ADD COLUMN rule_version     VARCHAR(32)  NULL COMMENT '计分规则版本，如 v1-6:4' AFTER is_manual_adjust,
  ADD COLUMN remark           VARCHAR(300) NULL COMMENT '改分/补考说明' AFTER rule_version;

-- 验证
SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME='score'
  AND COLUMN_NAME IN ('is_manual_adjust','rule_version','remark');


-- ---------------------------------------------------------------------
-- 3) 顺带补一条业务约束：班次容量必须非负
-- ---------------------------------------------------------------------
ALTER TABLE edu_online.course_schedule
  ADD CONSTRAINT ck_cs_count CHECK (max_count >= 0 AND current_count >= 0 AND current_count <= max_count);
-- 注意：造数时 max_count 要按真实规模设（720 班次分 50 万选课，约 694 人/班 → max_count 设 800）
