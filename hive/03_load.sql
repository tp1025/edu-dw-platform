-- =====================================================================
-- 把 TSV 装进 4 张外部表的分区，并做两级对账
-- 前提：4 个 tsv 已通过 docker cp 放进容器 /tmp/ 目录
-- =====================================================================

USE edu_dw;

-- 小数据量走本地模式，避免启动 MapReduce 拖慢
SET hive.exec.mode.local.auto=true;
SET hive.exec.mode.local.auto.inputbytes.max=134217728;

-- ---------------------------------------------------------------------
-- 装载（LOCAL INPATH = 复制，源文件保留；分区 dt 手工指定为今天）
-- ---------------------------------------------------------------------
LOAD DATA LOCAL INPATH '/tmp/ods_class.tsv'     INTO TABLE ods_class     PARTITION (dt='2026-11-15');
LOAD DATA LOCAL INPATH '/tmp/ods_student.tsv'   INTO TABLE ods_student   PARTITION (dt='2026-11-15');
LOAD DATA LOCAL INPATH '/tmp/ods_selection.tsv' INTO TABLE ods_selection PARTITION (dt='2026-11-15');
LOAD DATA LOCAL INPATH '/tmp/ods_score.tsv'     INTO TABLE ods_score     PARTITION (dt='2026-11-15');

-- ---------------------------------------------------------------------
-- 验收 1：分区列表
-- ---------------------------------------------------------------------
SHOW PARTITIONS ods_student;

-- ---------------------------------------------------------------------
-- 验收 2：行数对账
--   期望：class 400 / student 20000 / selection 480005 / score 474922
-- ---------------------------------------------------------------------
SELECT 'ods_class' AS tbl, COUNT(*) AS cnt FROM ods_class WHERE dt='2026-11-15'
UNION ALL
SELECT 'ods_student',   COUNT(*) FROM ods_student   WHERE dt='2026-11-15'
UNION ALL
SELECT 'ods_selection', COUNT(*) FROM ods_selection WHERE dt='2026-11-15'
UNION ALL
SELECT 'ods_score',     COUNT(*) FROM ods_score     WHERE dt='2026-11-15';

-- ---------------------------------------------------------------------
-- 验收 3：脏数据是否原样进仓（这是 ODS 全字符串设计的价值）
--   期望能看到 total_score = -5 / 150 / 缺考
-- ---------------------------------------------------------------------
SELECT score_id, student_id, total_score
FROM ods_score
WHERE dt='2026-11-15' AND (total_score = '-5' OR total_score = '150' OR total_score = '缺考')
ORDER BY score_id;

-- ---------------------------------------------------------------------
-- 验收 4：抽样字段对账（取 student_id 最大的 5 行，与 MySQL 逐字段比对）
-- ---------------------------------------------------------------------
SELECT row_id, student_id, class_id, student_no, student_name, gender,
       id_card_hash, SUBSTR(id_card_cipher, 1, 16) AS cipher_head
FROM ods_student
WHERE dt='2026-11-15'
ORDER BY CAST(student_id AS BIGINT) DESC
LIMIT 5;

-- ---------------------------------------------------------------------
-- 验收 5：分区裁剪对比（同一查询加/不加分区条件）
-- ---------------------------------------------------------------------
EXPLAIN
SELECT COUNT(*) FROM ods_score WHERE dt='2026-11-15';
