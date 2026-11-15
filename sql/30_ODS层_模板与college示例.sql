-- =====================================================================
-- ODS 层模板（以 college 为完整示例）
-- 目标库：edu_dw ｜ 源库：edu_normal / edu_online
-- 规范：贴源、无业务约束、数值字段脱类型、带 3 个系统字段
-- =====================================================================

-- ⚠️ 每段执行前先确认当前库
USE edu_dw;

-- ---------------------------------------------------------------------
-- 第 0 步：清理早期练手的 4 张旧表（它们结构不对，必须删）
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edu_dw.ods_student;
DROP TABLE IF EXISTS edu_dw.ods_course;
DROP TABLE IF EXISTS edu_dw.ods_teacher;
DROP TABLE IF EXISTS edu_dw.ods_selection;

-- =====================================================================
-- 【完整示例】ods_college —— 12 行小表，用来演示规范
-- =====================================================================

-- 1) 删旧表（保证脚本可重复执行）
DROP TABLE IF EXISTS edu_dw.ods_college;

-- 2) 建表：手写，不要用 LIKE（LIKE 会把主键/唯一键/CHECK 一起复制过来）
CREATE TABLE edu_dw.ods_college (
  -- ① ODS 行号：AUTO_INCREMENT 只是行标识，不构成业务约束
  row_id       BIGINT       NOT NULL AUTO_INCREMENT COMMENT 'ODS行号（仅用于定位，非业务主键）',

  -- ② 业务字段：数值型一律脱成 VARCHAR（脏数据最可能出现在这里）
  college_id   VARCHAR(32)  NULL COMMENT '源类型: bigint',
  college_code VARCHAR(255) NULL COMMENT '源类型: varchar(32)',
  college_name VARCHAR(255) NULL COMMENT '源类型: varchar(64)',

  -- ③ 源表的审计字段：日期保留原类型（日期一般不会是脏值）
  deleted_at   DATETIME     NULL COMMENT '源表软删除标记，原样保留（不解释）',
  created_at   DATETIME     NULL,
  updated_at   DATETIME     NULL,

  -- ④ 三个系统字段（ODS 必备）
  src_table    VARCHAR(100) NOT NULL COMMENT '来源表：库名.表名',
  etl_time     DATETIME     NOT NULL COMMENT '抽取时间（技术时间，精确到秒）',
  dt           CHAR(10)     NOT NULL COMMENT '业务批次日期 yyyy-mm-dd（将来做分区键）',

  PRIMARY KEY (row_id)          -- 只留行号主键
  -- ❌ 不要有 uk_*（业务唯一键）
  -- ❌ 不要有 CHECK
  -- ❌ 不要有外键
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-学院（贴源，无业务约束）';

-- 3) 抽取：显式写列名（别用 s.*，将来加列会错位）
INSERT INTO edu_dw.ods_college
  (college_id, college_code, college_name, deleted_at, created_at, updated_at,
   src_table, etl_time, dt)
SELECT CAST(college_id AS CHAR),      -- 数值 → 字符串
       college_code,
       college_name,
       deleted_at,
       created_at,
       updated_at,
       'edu_normal.college',           -- 来源表
       NOW(),                          -- 抽取时间
       '2026-11-10'                    -- 批次日期
FROM edu_normal.college;

-- 4) 对账：行数 + 关键字段校验和
SELECT 'college' AS tbl,
       (SELECT COUNT(*) FROM edu_normal.college)  AS src_cnt,
       (SELECT COUNT(*) FROM edu_dw.ods_college)  AS ods_cnt,
       (SELECT COUNT(*) FROM edu_normal.college)
     - (SELECT COUNT(*) FROM edu_dw.ods_college)  AS diff_cnt,
       (SELECT SUM(CRC32(CONCAT_WS('#', college_id, college_code, college_name)))
          FROM edu_normal.college)                AS src_crc,
       (SELECT SUM(CRC32(CONCAT_WS('#', college_id, college_code, college_name)))
          FROM edu_dw.ods_college)                AS ods_crc;
-- 期望：diff_cnt = 0，src_crc = ods_crc

-- 5) 看一眼数据（确认中文没乱码、系统字段有值）
SELECT row_id, college_code, college_name, src_table, etl_time, dt
FROM edu_dw.ods_college ORDER BY row_id LIMIT 5;


-- =====================================================================
-- 【填空模板】其余 16 张表照这个改（把 {{}} 换掉）
-- =====================================================================

/*
DROP TABLE IF EXISTS edu_dw.ods_{{表名}};

CREATE TABLE edu_dw.ods_{{表名}} (
  row_id       BIGINT       NOT NULL AUTO_INCREMENT COMMENT 'ODS行号',
  {{每个数值型字段}}   VARCHAR(255) NULL COMMENT '源类型: {{原类型}}',
  {{每个字符串字段}}   {{原类型}}    NULL COMMENT '原样保留',
  {{每个日期字段}}     DATETIME     NULL COMMENT '原样保留',
  src_table    VARCHAR(100) NOT NULL COMMENT '来源表',
  etl_time     DATETIME     NOT NULL COMMENT '抽取时间',
  dt           CHAR(10)     NOT NULL COMMENT '业务批次日期',
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='ODS-{{中文表名}}（贴源）';

INSERT INTO edu_dw.ods_{{表名}}
  ({{源表所有字段}}, src_table, etl_time, dt)
SELECT {{源表所有字段（数值型用 CAST(x AS CHAR)）}},
       '{{源库}}.{{源表}}', NOW(), '2026-11-10'
FROM {{源库}}.{{源表}};
*/

-- =====================================================================
-- 【脱类型生成器】把某张表的数值字段一键生成 MODIFY 语句
--   改 TABLE_SCHEMA / TABLE_NAME 即可复用
-- =====================================================================
SELECT GROUP_CONCAT(
         CONCAT('  MODIFY COLUMN `', COLUMN_NAME, '` VARCHAR(255) NULL COMMENT ''原类型: ',
                COLUMN_TYPE, ''',')
         SEPARATOR '\n'
       ) AS alter_numeric_cols
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'edu_normal'
  AND TABLE_NAME   = 'student'
  AND DATA_TYPE IN ('bigint','int','tinyint','smallint','mediumint','decimal','float','double');

-- 用法：把结果粘到 ALTER TABLE 后面（注意去掉最后一个逗号）
-- ALTER TABLE edu_dw.ods_student
--   <粘贴上面的结果>
-- ;


-- =====================================================================
-- 【判断某列要不要脱类型】规则速查
-- =====================================================================
-- 转 VARCHAR：
--   bigint / int / tinyint / smallint / decimal / float / double   ← 数值，脏数据高发
-- 保留原类型：
--   datetime / date / time        ← 日期时间，脏值少；保留能排序、能比较
--   char / varchar                ← 本来就是字符串
--   varbinary（密文字段）          ← 二进制，转 VARCHAR 会破坏字节，必须保留
-- =====================================================================


-- =====================================================================
-- 【全字符串的代价】先在 ODS 上体会一次（为 DWD 做铺垫）
-- =====================================================================
-- 这条能跑但性能差、语义模糊（隐式转换）：
SELECT AVG(college_id) FROM edu_dw.ods_college;
-- 这条才规范：
SELECT AVG(CAST(college_id AS UNSIGNED)) FROM edu_dw.ods_college;
