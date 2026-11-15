-- =====================================================================
-- Hive ODS 层建表：4 张外部表，按 dt 分区
-- 设计对齐 MySQL 侧 ODS 规范：全 STRING、无业务约束、保留系统字段
-- 与 MySQL 的唯一差异：dt 从普通列升级为分区列（分区裁剪）
-- 执行方式：把本文件内容粘到 beeline，或 beeline -f 01_ddl.sql
-- =====================================================================

CREATE DATABASE IF NOT EXISTS edu_dw;
USE edu_dw;

-- ---------------------------------------------------------------------
-- 1) ods_class：行政班级（400 行）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ods_class;
CREATE EXTERNAL TABLE ods_class (
  row_id        STRING  COMMENT 'ODS 行号',
  class_id      STRING  COMMENT '班级ID',
  major_id      STRING  COMMENT '专业ID',
  teacher_id    STRING  COMMENT '班主任ID',
  class_no      STRING  COMMENT '班级编号',
  class_name    STRING  COMMENT '班级名称',
  enroll_year   STRING  COMMENT '入学年份',
  deleted_at    STRING  COMMENT '软删除时间',
  created_at    STRING  COMMENT '创建时间',
  updated_at    STRING  COMMENT '更新时间',
  src_table     STRING  COMMENT '来源表',
  etl_time      STRING  COMMENT '抽取时间'
)
PARTITIONED BY (dt STRING COMMENT '批次日期')
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
LOCATION 'file:///opt/hive/data/warehouse/ods_class'
TBLPROPERTIES ('serialization.null.format'='NULL');

-- ---------------------------------------------------------------------
-- 2) ods_student：学生（20000 行）
--    密文字段用 HEX 表示（二进制无法直接存 TSV）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ods_student;
CREATE EXTERNAL TABLE ods_student (
  row_id          STRING,
  student_id      STRING,
  class_id        STRING,
  student_no      STRING,
  student_name    STRING,
  gender          STRING,
  deleted_at      STRING,
  created_at      STRING,
  updated_at      STRING,
  id_card_hash    STRING  COMMENT '身份证哈希(SHA256)',
  id_card_cipher  STRING  COMMENT '身份证密文(HEX)',
  phone_hash      STRING  COMMENT '手机号哈希',
  phone_cipher    STRING  COMMENT '手机号密文(HEX)',
  src_table       STRING,
  etl_time        STRING
)
PARTITIONED BY (dt STRING)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
LOCATION 'file:///opt/hive/data/warehouse/ods_student'
TBLPROPERTIES ('serialization.null.format'='NULL');

-- ---------------------------------------------------------------------
-- 3) ods_selection：选课流水（480005 行，含脏数据）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ods_selection;
CREATE EXTERNAL TABLE ods_selection (
  row_id        STRING,
  selection_id  STRING,
  student_id    STRING,
  schedule_id   STRING,
  term_id       STRING,
  select_status STRING,
  creator       STRING,
  remark        STRING,
  deleted_at    STRING,
  created_at    STRING,
  updated_at    STRING,
  src_table     STRING,
  etl_time      STRING
)
PARTITIONED BY (dt STRING)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
LOCATION 'file:///opt/hive/data/warehouse/ods_selection'
TBLPROPERTIES ('serialization.null.format'='NULL');

-- ---------------------------------------------------------------------
-- 4) ods_score：成绩（474922 行，含 -5/150/缺考 等脏数据）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ods_score;
CREATE EXTERNAL TABLE ods_score (
  row_id          STRING,
  score_id        STRING,
  student_id      STRING,
  schedule_id     STRING,
  exam_type       STRING,
  term_id         STRING,
  total_score     STRING  COMMENT '总评（脏数据：-5/150/缺考）',
  score_status    STRING,
  is_manual_adjust STRING,
  rule_version    STRING,
  creator         STRING,
  remark          STRING,
  deleted_at      STRING,
  created_at      STRING,
  updated_at      STRING,
  usual_score     STRING,
  final_score     STRING,
  src_table       STRING,
  etl_time        STRING
)
PARTITIONED BY (dt STRING)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
LOCATION 'file:///opt/hive/data/warehouse/ods_score'
TBLPROPERTIES ('serialization.null.format'='NULL');

-- ---------------------------------------------------------------------
-- 验收 1：4 张表都建成外部表 + 分区列
-- ---------------------------------------------------------------------
SHOW TABLES;
DESCRIBE FORMATTED ods_class;
