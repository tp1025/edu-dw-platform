-- =====================================================================
-- 增量抽取 + 幂等写入 最小实验
-- 目标：把「全量覆盖」升级成「增量抽取 + 幂等写入」，并能回答
--       ① 增量怎么切分  ② 幂等怎么做  ③ 迟到数据怎么办
-- 设计：
--   · 源表：edu_online.selection（478,001 行）
--   · 落地表：edu_dw.ods_selection_incr（带业务主键，支持 upsert）
--   · 水位线：edu_dw.etl_watermark 记录每个表已抽到的最大 updated_at
-- =====================================================================

-- ---------------------------------------------------------------------
-- 第 0 步：建水位线表和增量落地表
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.etl_watermark;
CREATE TABLE edu_dw.etl_watermark (
  table_name VARCHAR(64) PRIMARY KEY,
  last_time  DATETIME    NOT NULL COMMENT '已抽到的最大 updated_at',
  last_dt    CHAR(10)    NOT NULL COMMENT '本次批次日期',
  run_count  INT         NOT NULL DEFAULT 0 COMMENT '累计运行次数',
  updated_at DATETIME    DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='ETL 水位线';

DROP TABLE IF EXISTS edu_dw.ods_selection_incr;
CREATE TABLE edu_dw.ods_selection_incr (
  selection_id  BIGINT       NOT NULL,
  term_id       INT          NOT NULL,
  student_id    BIGINT       NOT NULL,
  schedule_id   BIGINT       NOT NULL,
  select_status TINYINT      NULL,
  creator       BIGINT       NULL,
  remark        VARCHAR(300) NULL,
  deleted_at    DATETIME     NULL,
  created_at    DATETIME     NULL,
  updated_at    DATETIME     NULL COMMENT '源端更新时间（水位线依据）',
  etl_time      DATETIME(3)  DEFAULT CURRENT_TIMESTAMP(3),
  dt            CHAR(10)     NULL,
  PRIMARY KEY (selection_id, term_id),      -- 与源表主键一致 → 支持 upsert
  KEY idx_updated (updated_at)
) ENGINE=InnoDB COMMENT='选课增量落地表（可 upsert）';


-- ---------------------------------------------------------------------
-- 第 1 步：初始化水位线（用极早时间触发 bootstrap 全量）
-- ---------------------------------------------------------------------
INSERT INTO edu_dw.etl_watermark (table_name, last_time, last_dt, run_count)
VALUES ('selection', '1970-01-01 00:00:00', '2026-11-15', 0);

SELECT '【第1步】水位线初始化' AS step, table_name, last_time, run_count
FROM edu_dw.etl_watermark;


-- ---------------------------------------------------------------------
-- 第 2 步：首次运行（bootstrap，等价全量）
--   WHERE updated_at > 水位线 + ON DUPLICATE KEY UPDATE → 幂等
-- ---------------------------------------------------------------------
SET @wm := (SELECT last_time FROM edu_dw.etl_watermark WHERE table_name='selection');

INSERT INTO edu_dw.ods_selection_incr
  (selection_id, term_id, student_id, schedule_id, select_status, creator, remark,
   deleted_at, created_at, updated_at, dt)
SELECT selection_id, term_id, student_id, schedule_id, select_status, creator, remark,
       deleted_at, created_at, updated_at, '2026-11-15'
FROM edu_online.selection
WHERE updated_at > @wm
ON DUPLICATE KEY UPDATE
  select_status = VALUES(select_status),
  updated_at    = VALUES(updated_at),
  etl_time      = CURRENT_TIMESTAMP(3);

UPDATE edu_dw.etl_watermark
SET last_time = (SELECT MAX(updated_at) FROM edu_online.selection),
    run_count = run_count + 1
WHERE table_name = 'selection';

SELECT '【第2步】bootstrap 后' AS step,
       (SELECT COUNT(*) FROM edu_online.selection)     AS 源表行数,
       (SELECT COUNT(*) FROM edu_dw.ods_selection_incr) AS 落地表行数,
       (SELECT last_time FROM edu_dw.etl_watermark WHERE table_name='selection') AS 水位线;


-- ---------------------------------------------------------------------
-- 第 3 步：制造增量 —— 改 50 行 + 新增 10 行
--   UPDATE 会自动把 updated_at 推到当前时间（表定义带 ON UPDATE）
-- ---------------------------------------------------------------------
UPDATE edu_online.selection
SET select_status = 2
WHERE selection_id BETWEEN 100 AND 149 AND term_id = 202501;

INSERT INTO edu_online.selection
  (selection_id, student_id, schedule_id, term_id, select_status, deleted_at, created_at)
SELECT 9000000 + n, student_id, schedule_id, term_id, 1, '1970-01-01 00:00:00', NOW()
FROM edu_online.selection
WHERE term_id = 202501
ORDER BY selection_id
LIMIT 10;

SELECT '【第3步】制造的变化量' AS step,
       (SELECT COUNT(*) FROM edu_online.selection
         WHERE updated_at > (SELECT last_time FROM edu_dw.etl_watermark WHERE table_name='selection')
       ) AS 待抽取行数_应约60,
       (SELECT COUNT(*) FROM edu_online.selection) AS 源表总数;
