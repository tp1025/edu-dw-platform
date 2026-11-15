-- =====================================================================
-- 造数脚本 1/2：工具表 + 维表（8 张）
-- 环境：MySQL 26.10 @ 127.0.0.1:3307
-- 思路：不用 Python，用「数字表 + INSERT...SELECT」生成数据
-- 执行顺序：整段从上到下，每段后面有验证
-- =====================================================================

-- ⚠️ 必须：指定当前数据库，否则 HeidiSQL 会报 1046 No database selected
USE edu_normal;


-- =====================================================================
-- 第 0 段：数字表 nums（1 ~ 100 万）
--   技巧：递归 CTE 只生成 1..1000，再用「自己 × 自己」交叉连接得到 100 万
--   这样避免 MySQL 递归深度限制（cte_max_recursion_depth 默认 1000）
-- =====================================================================
SET SESSION cte_max_recursion_depth = 2000;

DROP TABLE IF EXISTS edu_normal.nums;
CREATE TABLE edu_normal.nums (n INT NOT NULL PRIMARY KEY) ENGINE=InnoDB;

INSERT INTO edu_normal.nums (n)
WITH RECURSIVE seq(n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < 1000
)
SELECT a.n + (b.n - 1) * 1000
FROM seq a CROSS JOIN seq b;

-- 验证：1000000，最大 1000000
SELECT COUNT(*) AS total, MIN(n) AS min_n, MAX(n) AS max_n FROM edu_normal.nums;


-- =====================================================================
-- 第 1 段：college（12 所学院）
-- =====================================================================
INSERT INTO edu_normal.college (college_code, college_name) VALUES
('CS',   '计算机科学与工程学院'),
('MATH', '数学科学学院'),
('PHYS', '物理学院'),
('FL',   '外国语学院'),
('EM',   '经济与管理学院'),
('LIFE', '生命科学与技术学院'),
('AUTO', '自动化工程学院'),
('ME',   '机械与电气工程学院'),
('PA',   '公共管理学院'),
('MED',  '医学院'),
('MARX', '马克思主义学院'),
('PE',   '体育部');

SELECT COUNT(*) AS college_cnt FROM edu_normal.college;   -- 期望 12


-- =====================================================================
-- 第 2 段：major（45 个专业，挂到 12 个学院上）
--   唯一键 (college_id, major_name) → 名称里带 n 保证不重复
-- =====================================================================
INSERT INTO edu_normal.major (college_id, major_name, major_code)
SELECT 1 + (n - 1) % 12,
       CONCAT(ELT(1 + (n - 1) % 15,
                  '计算机科学','软件工程','人工智能','网络工程','信息安全',
                  '数学与应用数学','统计学','应用物理','电子信息','英语',
                  '金融学','工商管理','生物技术','自动化','机械工程'),
              '专业', n),
       CONCAT('M', LPAD(n, 3, '0'))
FROM edu_normal.nums WHERE n <= 45;

SELECT COUNT(*) AS major_cnt FROM edu_normal.major;   -- 期望 45


-- =====================================================================
-- 第 3 段：teacher（400 位教师）
--   ⚠️ 敏感字段已加密改造：没有 phone 明文列，只有 phone_hash + phone_cipher
--   职称 title 有 CHECK：教授/副教授/讲师/助教
-- =====================================================================
INSERT INTO edu_normal.teacher
  (college_id, teacher_no, teacher_name, title, email, phone_hash, phone_cipher)
SELECT 1 + (n - 1) % 12,
       CONCAT('T', LPAD(n, 4, '0')),
       CONCAT(ELT(1 + (n - 1) % 20,
                  '张','王','李','赵','刘','陈','杨','黄','周','吴',
                  '徐','孙','马','朱','胡','郭','何','高','林','罗'),
              ELT(1 + (n * 7) % 12,
                  '伟','芳','娜','敏','静','强','磊','洋','艳','勇','军','杰')),
       ELT(1 + (n - 1) % 4, '教授', '副教授', '讲师', '助教'),
       CONCAT('t', LPAD(n, 4, '0'), '@uestc.edu.cn'),
       SHA2(CONCAT('TPHONE-', n), 256),
       RANDOM_BYTES(32)
FROM edu_normal.nums WHERE n <= 800;

SELECT COUNT(*) AS teacher_cnt FROM edu_normal.teacher;   -- 期望 800
SELECT title, COUNT(*) cnt FROM edu_normal.teacher GROUP BY title;


-- =====================================================================
-- 第 4 段：class（160 个行政班，3 个年级）
--   唯一键 (class_no) → 用 LPAD(n) 保证唯一
-- =====================================================================
INSERT INTO edu_normal.class (major_id, teacher_id, class_no, class_name, enroll_year)
SELECT 1 + (n - 1) % 45,
       1 + (n * 7) % 800,
       CONCAT('C', 2023 + (n - 1) % 3, LPAD(n, 3, '0')),
       CONCAT(ELT(1 + (n - 1) % 15,
                  '计科','软工','人工智能','网工','信安',
                  '数学','统计','物理','电子','英语',
                  '金融','工商','生物','自动化','机械'),
              ELT(1 + (n - 1) % 3, '一班','二班','三班')),
       2023 + (n - 1) % 3
FROM edu_normal.nums WHERE n <= 400;

SELECT COUNT(*) AS class_cnt FROM edu_normal.class;   -- 期望 400


-- =====================================================================
-- 第 5 段：student（1000 名学生，含敏感字段加密 + 埋脏数据）
--   ⚠️ 注意：
--     1) id_card_hash 有唯一索引 → 必须每个非 NULL 值不同（用 SHA2 拼接 n）
--     2) 约 3% 故意不给身份证（id_card_hash = NULL）→ 验证「多 NULL 不冲突」
--     3) 约 5% 姓名带尾空格（脏数据，DWD 清洗用）
--     4) 手机号/身份证都存密文（cipher），明文不落库
-- =====================================================================
INSERT INTO edu_normal.student
  (class_id, student_no, student_name, gender, id_card_hash, id_card_cipher, phone_hash, phone_cipher)
SELECT 1 + (n - 1) % 400,
       CONCAT('S', LPAD(n, 6, '0')),
       CONCAT(ELT(1 + (n - 1) % 20,
                  '张','王','李','赵','刘','陈','杨','黄','周','吴',
                  '徐','孙','马','朱','胡','郭','何','高','林','罗'),
              ELT(1 + (n * 3) % 12,
                  '浩','婷','鑫','悦','宇','琳','阳','雪','博','楠','曦','睿')),
       -- 脏数据：每 20 个里有 1 个姓名带尾空格
       -- （上面 CONCAT 的结果，这里用 IF 追加空格）
       1 + n % 2,
       -- 3% 无身份证 → NULL
       IF(n % 33 = 0, NULL, SHA2(CONCAT('IDCARD-', n), 256)),
       RANDOM_BYTES(32),
       SHA2(CONCAT('PHONE-', n), 256),
       RANDOM_BYTES(32)
FROM edu_normal.nums WHERE n <= 20000;

-- 补上「姓名带尾空格」的脏数据（5%）
UPDATE edu_normal.student
SET student_name = CONCAT(student_name, ' ')
WHERE student_id % 20 = 0;

-- 验证：总数、实名数、无身份证数、带尾空格数
SELECT COUNT(*) AS student_cnt,
       SUM(id_card_hash IS NOT NULL) AS has_idcard,
       SUM(id_card_hash IS NULL)     AS no_idcard,
       SUM(student_name <> TRIM(student_name)) AS dirty_name
FROM edu_normal.student;
-- 期望：20000 / 约 19400 / 约 600 / 1000


-- =====================================================================
-- 第 6 段：course（120 门课程）
-- =====================================================================
INSERT INTO edu_normal.course (course_code, course_name, credit, course_type)
SELECT CONCAT('C', LPAD(n, 3, '0')),
       CONCAT(ELT(1 + (n - 1) % 30,
                  '高等数学','线性代数','概率论','离散数学','数据结构',
                  '操作系统','计算机网络','数据库系统','编译原理','软件工程',
                  '大学物理','电路分析','信号与系统','数字逻辑','模拟电子',
                  '大学英语','英语听力','日语入门','微观经济学','宏观经济学',
                  '管理学原理','市场营销','财务管理','生物化学','细胞生物学',
                  '自动控制原理','电机学','机械设计','工程制图','体育'),
              ELT(1 + (n - 1) % 4, '（上）','（下）','实验','')),
       ELT(1 + (n - 1) % 5, 1.0, 1.5, 2.0, 3.0, 4.0),
       1 + (n - 1) % 2
FROM edu_normal.nums WHERE n <= 120;

SELECT COUNT(*) AS course_cnt FROM edu_normal.course;   -- 期望 120


-- =====================================================================
-- 第 7 段：course_prerequisite（200 条先修关系）
--   ⚠️ CHECK (course_id <> prerequisite_course_id) 必须满足
-- =====================================================================
INSERT INTO edu_normal.course_prerequisite (course_id, prerequisite_course_id, remark)
SELECT i AS course_id,
       IF(j >= i, j + 20, j) AS prereq,   -- 偏移避免自环，且保证 200 对唯一
       '先修要求'
FROM (
  SELECT 2 + FLOOR((n - 1) / 20) * 11 AS i,   -- 2,13,24,...,101 共 10 门课
         1 + (n - 1) % 20             AS j    -- 每门课 20 个先修候选
  FROM edu_normal.nums WHERE n <= 200
) t;

SELECT COUNT(*) AS prereq_cnt,
       SUM(course_id = prerequisite_course_id) AS self_loop
FROM edu_normal.course_prerequisite;
-- 期望：200 / 0（self_loop 必须为 0）


-- =====================================================================
-- 第 8 段：classroom（60 间教室）
--   唯一键 (building_name, room_no)
-- =====================================================================
INSERT INTO edu_normal.classroom (building_name, room_no, capacity, room_type, is_enabled)
SELECT ELT(1 + (n - 1) % 5, '主楼', '立人楼', '逸夫楼', '实验楼', '第二教学楼'),
       CONCAT('A', LPAD(n, 3, '0')),
       30 + (n * 13) % 90,
       1 + (n - 1) % 3,
       1
FROM edu_normal.nums WHERE n <= 60;

SELECT COUNT(*) AS classroom_cnt FROM edu_normal.classroom;   -- 期望 60


-- =====================================================================
-- 汇总验证：8 张维表行数
-- =====================================================================
SELECT 'college'            AS tbl, COUNT(*) AS cnt FROM edu_normal.college
UNION ALL SELECT 'major',              COUNT(*) FROM edu_normal.major
UNION ALL SELECT 'teacher',            COUNT(*) FROM edu_normal.teacher
UNION ALL SELECT 'class',              COUNT(*) FROM edu_normal.class
UNION ALL SELECT 'student',            COUNT(*) FROM edu_normal.student
UNION ALL SELECT 'course',             COUNT(*) FROM edu_normal.course
UNION ALL SELECT 'course_prerequisite',COUNT(*) FROM edu_normal.course_prerequisite
UNION ALL SELECT 'classroom',          COUNT(*) FROM edu_normal.classroom;
-- 期望：12 / 45 / 800 / 400 / 20000 / 120 / 200 / 60
