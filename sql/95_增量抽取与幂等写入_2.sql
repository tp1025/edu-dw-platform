-- =====================================================================
-- 增量抽取 + 幂等写入：第 3—8 步
-- =====================================================================

-- ---------------------------------------------------------------------
-- 第 3 步：制造增量（改 50 行 + 新增 10 行）
-- ---------------------------------------------------------------------
UPDATE edu_online.selection
SET select_status = 2
WHERE selection_id BETWEEN 100 AND 149 AND term_id = 202501;

INSERT INTO edu_online.selection
  (selection_id, student_id, schedule_id, term_id, select_status, deleted_at, created_at)
SELECT 9000000 + ROW_NUMBER() OVER (ORDER BY selection_id),
       8800000 + ROW_NUMBER() OVER (ORDER BY selection_id),
       schedule_id, term_id, 1, '1970-01-01 00:00:00', NOW()
FROM edu_online.selection
WHERE term_id = 202501
ORDER BY selection_id
LIMIT 10;

SELECT '【第3步】制造变化' AS step,
       (SELECT COUNT(*) FROM edu_online.selection
         WHERE updated_at > (SELECT last_time FROM edu_dw.etl_watermark WHERE table_name='selection')
       ) AS 待抽取行数_应约60,
       (SELECT COUNT(*) FROM edu_online.selection) AS 源表总数;


-- ---------------------------------------------------------------------
-- 第 4 步：增量抽取预览（只捞变化的数据）
-- ---------------------------------------------------------------------
SELECT '【第4步】增量明细（前 10 条）' AS step;
SELECT selection_id, term_id, select_status, updated_at
FROM edu_online.selection
WHERE updated_at > (SELECT last_time FROM edu_dw.etl_watermark WHERE table_name='selection')
ORDER BY updated_at DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- 第 5 步：幂等写入（upsert）
--   注意 ROW_COUNT 语义：插入 1 行算 1，更新 1 行算 2
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
    run_count = run_count + 2
WHERE table_name = 'selection';

SELECT '【第5步】增量写入后' AS step,
       (SELECT COUNT(*) FROM edu_online.selection)      AS 源表行数,
       (SELECT COUNT(*) FROM edu_dw.ods_selection_incr)  AS 落地表行数,
       (SELECT last_time FROM edu_dw.etl_watermark WHERE table_name='selection') AS 水位线;


-- ---------------------------------------------------------------------
-- 第 6 步：幂等性验证 —— 用同一个水位线再跑一次（模拟任务重试）
--   期望：行数完全不变
-- ---------------------------------------------------------------------
SELECT '【第6步】重跑前的指纹' AS step,
       COUNT(*) AS 行数,
       SUM(CRC32(CONCAT_WS('|', selection_id, select_status, IFNULL(updated_at,'')))) AS 内容指纹
FROM edu_dw.ods_selection_incr;

-- ⚠️ 故意把水位线拨回去，制造"重复抽取"场景
UPDATE edu_dw.etl_watermark
SET last_time = '2026-11-10 22:14:58'
WHERE table_name = 'selection';

INSERT INTO edu_dw.ods_selection_incr
  (selection_id, term_id, student_id, schedule_id, select_status, creator, remark,
   deleted_at, created_at, updated_at, dt)
SELECT selection_id, term_id, student_id, schedule_id, select_status, creator, remark,
       deleted_at, created_at, updated_at, '2026-11-15'
FROM edu_online.selection
WHERE updated_at > '2026-11-10 22:14:58'
ON DUPLICATE KEY UPDATE
  select_status = VALUES(select_status),
  updated_at    = VALUES(updated_at),
  etl_time      = CURRENT_TIMESTAMP(3);

SELECT '【第6步】重跑后的指纹（应与上面完全一致）' AS step,
       COUNT(*) AS 行数,
       SUM(CRC32(CONCAT_WS('|', selection_id, select_status, IFNULL(updated_at,'')))) AS 内容指纹
FROM edu_dw.ods_selection_incr;

UPDATE edu_dw.etl_watermark
SET last_time = (SELECT MAX(updated_at) FROM edu_online.selection)
WHERE table_name = 'selection';


-- ---------------------------------------------------------------------
-- 第 7 步：迟到数据 —— 纯增量会漏掉它
--   插入一条"内容新、但 updated_at 很早"的记录（模拟上游补录历史数据）
-- ---------------------------------------------------------------------
INSERT INTO edu_online.selection
  (selection_id, student_id, schedule_id, term_id, select_status, deleted_at, created_at, updated_at)
VALUES (9999001, 1, 1, 202501, 1, '1970-01-01 00:00:00', '2026-01-01 08:00:00', '2026-01-01 08:00:00');

SELECT '【第7步】迟到数据的影响' AS step,
       (SELECT COUNT(*) FROM edu_online.selection
         WHERE updated_at > (SELECT last_time FROM edu_dw.etl_watermark WHERE table_name='selection')
       ) AS 纯增量能捞到_应为0,
       (SELECT COUNT(*) FROM edu_online.selection)      AS 源表行数,
       (SELECT COUNT(*) FROM edu_dw.ods_selection_incr)  AS 落地表行数_缺1;


-- ---------------------------------------------------------------------
-- 第 8 步：补偿方案 —— 按日期分区覆盖重抽（能捕获任意迟到数据）
--   MySQL 的"分区覆盖"等价写法：先 DELETE 该时间段，再 INSERT 回来
-- ---------------------------------------------------------------------
DELETE FROM edu_dw.ods_selection_incr
WHERE created_at >= '2026-01-01' AND created_at < '2026-01-02';

INSERT INTO edu_dw.ods_selection_incr
  (selection_id, term_id, student_id, schedule_id, select_status, creator, remark,
   deleted_at, created_at, updated_at, dt)
SELECT selection_id, term_id, student_id, schedule_id, select_status, creator, remark,
       deleted_at, created_at, updated_at, '2026-11-15'
FROM edu_online.selection
WHERE created_at >= '2026-01-01' AND created_at < '2026-01-02';

SELECT '【第8步】分区覆盖回刷后' AS step,
       (SELECT COUNT(*) FROM edu_online.selection)      AS 源表行数,
       (SELECT COUNT(*) FROM edu_dw.ods_selection_incr)  AS 落地表行数,
       (SELECT COUNT(*) FROM edu_online.selection) -
       (SELECT COUNT(*) FROM edu_dw.ods_selection_incr)  AS 差异_应为0;


-- ---------------------------------------------------------------------
-- 汇总：水位线状态
-- ---------------------------------------------------------------------
SELECT '【汇总】水位线' AS step, table_name, last_time, run_count FROM edu_dw.etl_watermark;
