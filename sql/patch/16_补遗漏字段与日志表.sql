-- =====================================================================
-- 造数前最后一次补漏（对照《阶段1-数据库设计定稿.md》逐表核对发现）
-- 环境：MySQL 26.10 @ 127.0.0.1:3307 ｜ 前提：相关表 0 行
-- =====================================================================


-- =====================================================================
-- 遗漏 1【必须】teacher 缺「职称」title
--   定稿里有 title（教授/副教授/讲师/助教），实际表没有
--   影响：做不了「按职称统计教师」「教授授课占比」这类分析
-- =====================================================================
ALTER TABLE edu_normal.teacher
  ADD COLUMN title VARCHAR(30) NULL COMMENT '职称：教授/副教授/讲师/助教' AFTER teacher_name,
  ADD CONSTRAINT ck_teacher_title
      CHECK (title IS NULL OR title IN ('教授','副教授','讲师','助教'));


-- =====================================================================
-- 遗漏 2【建议】selection 缺「操作人」和「退课原因」
--   影响：退课是谁操作的、为什么退，都查不到（业务留痕缺失）
-- =====================================================================
ALTER TABLE edu_online.selection
  ADD COLUMN creator BIGINT       NULL COMMENT '操作人：学生本人/教务' AFTER select_status,
  ADD COLUMN remark  VARCHAR(300) NULL COMMENT '退课原因、作废说明' AFTER creator;


-- =====================================================================
-- 遗漏 3【建议】score 缺「录入人」
--   影响：谁录的成绩追溯不到（配合 score_change_log 才算完整审计）
-- =====================================================================
ALTER TABLE edu_online.score
  ADD COLUMN creator BIGINT NULL COMMENT '录入人：授课教师/教务' AFTER rule_version;


-- =====================================================================
-- 遗漏 4【建议】reward_punish 缺 term_id（所属学期）
--   影响：按学期统计奖助金额要拿 rp_date 反推学期，容易和学期口径不一致
-- =====================================================================
ALTER TABLE edu_normal.reward_punish
  ADD COLUMN term_id INT NULL COMMENT '所属学期，如 202601；跨学期项可为 NULL' AFTER student_id;


-- =====================================================================
-- 遗漏 5【必须】两张审计日志表完全没建
--   你的决策：「改分必须留痕」「补签是敏感操作」
--   现在没有任何日志表，这条承诺无法兑现
--   注意：日志表是「只追加」的，不设 deleted_at（不参与软删除）
-- =====================================================================

CREATE TABLE IF NOT EXISTS edu_online.score_change_log (
  log_id        BIGINT       NOT NULL AUTO_INCREMENT COMMENT '日志主键',
  score_id      BIGINT       NOT NULL COMMENT '被改的成绩记录（→score.score_id）',
  term_id       INT          NOT NULL COMMENT '学期（与主表对齐）',
  change_field  VARCHAR(32)  NOT NULL COMMENT 'total_score/usual_score/final_score/score_status',
  old_value     VARCHAR(64)  NULL,
  new_value     VARCHAR(64)  NULL,
  operator_id   BIGINT       NOT NULL COMMENT '教师/教务',
  change_reason VARCHAR(200) NULL COMMENT '改分原因',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (log_id),
  KEY idx_score (score_id, term_id),
  KEY idx_term_time (term_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='成绩变更审计（只追加）';


CREATE TABLE IF NOT EXISTS edu_online.attendance_change_log (
  log_id        BIGINT       NOT NULL AUTO_INCREMENT COMMENT '日志主键',
  att_id        BIGINT       NOT NULL COMMENT '被改的考勤记录（→attendance.att_id）',
  term_id       INT          NOT NULL COMMENT '学期（与主表对齐）',
  change_field  VARCHAR(32)  NOT NULL COMMENT 'att_status/late_minutes/early_minutes/is_makeup',
  old_value     VARCHAR(64)  NULL,
  new_value     VARCHAR(64)  NULL,
  operator_id   BIGINT       NOT NULL COMMENT '教师/教务',
  change_reason VARCHAR(200) NULL COMMENT '补签原因、调整说明',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (log_id),
  KEY idx_att (att_id, term_id),
  KEY idx_term_time (term_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='考勤变更审计（只追加）';


-- =====================================================================
-- 验证
-- =====================================================================

-- ① teacher 应有 title
SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='teacher' AND COLUMN_NAME='title';

-- ② selection / score 应有 creator
SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_online' AND COLUMN_NAME IN ('creator','remark')
  AND TABLE_NAME IN ('selection','score') ORDER BY 1,2;

-- ③ reward_punish 应有 term_id
SELECT COLUMN_NAME FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='reward_punish' AND COLUMN_NAME='term_id';

-- ④ 两张日志表存在
SELECT TABLE_SCHEMA, TABLE_NAME FROM information_schema.TABLES
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME LIKE '%_change_log';

-- ⑤ 表总数：edu_normal 11 / edu_online 8（6 业务 + 2 日志）
SELECT TABLE_SCHEMA, COUNT(*) tbls FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') GROUP BY 1;

-- ⑥ CHECK 总数应为 23（原 22 + ck_teacher_title）
SELECT COUNT(*) AS check_total FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA IN ('edu_normal','edu_online') AND CONSTRAINT_TYPE='CHECK';
