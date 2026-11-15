-- =====================================================================
-- 核心 SQL 20 条（面试能现场手写的版本）
-- 数据：edu_dw 四层数仓（DWD 明细 + DWS 汇总）
-- 分类：A 窗口函数 6 条 / B CTE与递归 4 条 / C 行列转换 3 条
--       D 留存与连续 4 条 / E 复杂聚合 3 条
-- 每条都注明：业务问题 + 关键点（面试会追问什么）
-- =====================================================================
USE edu_dw;


-- #####################################################################
-- A. 窗口函数（6 条）
-- #####################################################################

-- ---------------------------------------------------------------------
-- A1. 每个班级内按学期均分排名
--     业务：班级内部排名，用于评奖学金/预警
--     关键点：RANK / DENSE_RANK / ROW_NUMBER 三者区别
--            · ROW_NUMBER：1,2,3,4（不重复）
--            · RANK：1,1,3（并列占位）
--            · DENSE_RANK：1,1,2（并列不占位）
-- ---------------------------------------------------------------------
SELECT term_id, class_name, student_no, student_name, avg_score,
       ROW_NUMBER() OVER (PARTITION BY term_id, class_id ORDER BY avg_score DESC) AS rn,
       RANK()       OVER (PARTITION BY term_id, class_id ORDER BY avg_score DESC) AS rnk,
       DENSE_RANK() OVER (PARTITION BY term_id, class_id ORDER BY avg_score DESC) AS dense_rnk
FROM edu_dw.dws_student_term
WHERE term_id = 202601 AND class_id = 1
ORDER BY avg_score DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- A2. 每门课程取"均分最高"的 3 个班次（分组 TopN）
--     业务：哪几个教学班教得好
--     关键点：为什么不能直接 WHERE rn<=3 —— 窗口函数在 WHERE 之后才计算，
--            必须套一层子查询/CTE
-- ---------------------------------------------------------------------
SELECT course_name, schedule_id, teacher_name, avg_score, fail_rate, student_cnt, rn
FROM (
  SELECT dc.course_name, f.schedule_id, ds.teacher_name,
         ROUND(AVG(sc.best_score), 2) AS avg_score,
         ROUND(SUM(CASE WHEN sc.first_score < 60 THEN 1 ELSE 0 END) / NULLIF(COUNT(sc.best_score),0), 4) AS fail_rate,
         COUNT(*) AS student_cnt,
         ROW_NUMBER() OVER (PARTITION BY f.course_id
                            ORDER BY AVG(sc.best_score) DESC) AS rn
  FROM edu_dw.fact_selection f
  JOIN edu_dw.dwd_score_agg sc
    ON sc.term_id=f.term_id AND sc.student_id=f.student_id AND sc.schedule_id=f.schedule_id
  JOIN edu_dw.dim_course  dc ON dc.course_id  = f.course_id
  JOIN edu_dw.dim_schedule ds ON ds.schedule_id = f.schedule_id
  WHERE f.is_valid = 1 AND f.term_id = 202601
  GROUP BY f.course_id, dc.course_name, f.schedule_id, ds.teacher_name
) t
WHERE rn <= 3
ORDER BY course_name, rn
LIMIT 12;


-- ---------------------------------------------------------------------
-- A3. 学生成绩在全校的百分位（PERCENT_RANK）
--     业务：判断一个学生处于全校什么位置（比"第几名"更直观）
--     关键点：PERCENT_RANK 公式 = (rank-1)/(rows-1)；
--            另有 CUME_DIST（<= 当前值的累计占比）
-- ---------------------------------------------------------------------
SELECT student_no, student_name, class_name, avg_score,
       ROUND(PERCENT_RANK() OVER (ORDER BY avg_score), 4) AS pct_rank,
       ROUND(CUME_DIST()    OVER (ORDER BY avg_score), 4) AS 累计占比
FROM edu_dw.dws_student_term
WHERE term_id = 202601
ORDER BY avg_score DESC
LIMIT 5;


-- ---------------------------------------------------------------------
-- A4. 每个学生学期均分的环比（与上一学期比）
--     业务：成绩是在变好还是变差
--     关键点：LAG(列, 1) 取上一行；无上一学期时返回 NULL，要用 IFNULL 处理
-- ---------------------------------------------------------------------
SELECT student_no, term_id, avg_score,
       LAG(avg_score, 1) OVER (PARTITION BY student_id ORDER BY term_id) AS prev_score,
       ROUND(avg_score - LAG(avg_score, 1) OVER (PARTITION BY student_id ORDER BY term_id), 2) AS diff,
       CASE WHEN LAG(avg_score,1) OVER (PARTITION BY student_id ORDER BY term_id) IS NULL THEN '首次'
            WHEN avg_score > LAG(avg_score,1) OVER (PARTITION BY student_id ORDER BY term_id) THEN '上升'
            WHEN avg_score < LAG(avg_score,1) OVER (PARTITION BY student_id ORDER BY term_id) THEN '下降'
            ELSE '持平' END AS trend
FROM edu_dw.dws_student_term
WHERE student_id <= 10
ORDER BY student_id, term_id;


-- ---------------------------------------------------------------------
-- A5. 学院内按课程挂科率排名（多级聚合）
--     业务：每个学院里最该整改的课
--     关键点：RANK() 的 PARTITION BY college，不是全局排
-- ---------------------------------------------------------------------
SELECT college_name, course_name, scored_cnt, fail_rate, rank_in_college
FROM (
  SELECT t.*,
         RANK() OVER (PARTITION BY college_name ORDER BY fail_rate DESC) AS rank_in_college
  FROM (
    SELECT md.college_name, dc.course_name,
           MAX(dct.scored_cnt) AS scored_cnt, MAX(dct.fail_rate) AS fail_rate
    FROM edu_dw.dws_course_term dct
    JOIN edu_dw.dim_course   dc ON dc.course_id  = dct.course_id
    JOIN edu_dw.dim_schedule ds ON ds.course_id  = dc.course_id
    JOIN edu_dw.dim_teacher  dt ON dt.teacher_id = ds.teacher_id
    JOIN edu_dw.dim_college  md ON md.college_id = dt.college_id
    WHERE dct.term_id = 202601
    GROUP BY md.college_name, dc.course_name
  ) t
) x
WHERE rank_in_college <= 2
ORDER BY college_name, rank_in_college
LIMIT 10;


-- ---------------------------------------------------------------------
-- A6. 学生选课学分的"滚动累计"（按学期累积）
--     业务：到某学期为止累计修了多少学分
--     关键点：SUM() OVER (ORDER BY ...) 是**累计**，不是总和；
--            加 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW 更明确
-- ---------------------------------------------------------------------
SELECT student_no, term_id, credit_sum,
       SUM(credit_sum) OVER (PARTITION BY student_id ORDER BY term_id) AS cum_credit
FROM edu_dw.dws_student_term
WHERE student_id <= 5
ORDER BY student_id, term_id;


-- #####################################################################
-- B. CTE 与递归（4 条）
-- #####################################################################

-- ---------------------------------------------------------------------
-- B1. 递归查某门课的"全部先修课链路"（多级）
--     业务：学生要选"数据结构"，到底需要先学哪些课
--     关键点：WITH RECURSIVE 必须有两个部分：
--            ① 锚点（起点）② 递归部分；必须有终止条件，否则无限递归
--            实际生产还要加 depth 上限防脏数据成环（见注释）
-- ---------------------------------------------------------------------
WITH RECURSIVE pre AS (
  -- 锚点：直接先修
  SELECT CAST(p.course_id AS UNSIGNED) AS course_id,
         CAST(p.prerequisite_course_id AS UNSIGNED) AS pre_id,
         1 AS depth
  FROM edu_dw.ods_course_prerequisite p
  WHERE CAST(p.course_id AS UNSIGNED) = 100
  UNION ALL
  -- 递归：先修课的先修课
  SELECT pre.course_id, CAST(p.prerequisite_course_id AS UNSIGNED), pre.depth + 1
  FROM pre
  JOIN edu_dw.ods_course_prerequisite p
    ON CAST(p.course_id AS UNSIGNED) = pre.pre_id
  WHERE pre.depth < 10                    -- ← 深度上限，防成环爆炸
)
SELECT DISTINCT pre.pre_id AS 先修课ID, dc.course_name AS 先修课名, pre.depth AS 层级
FROM pre
LEFT JOIN edu_dw.dim_course dc ON dc.course_id = pre.pre_id
ORDER BY pre.depth, pre.pre_id;


-- ---------------------------------------------------------------------
-- B2. 反向递归：哪些课程把"课程10"当先修（后继课程）
--     业务：如果课程2 停开，会阻塞哪些后续课程
--     关键点：把递归的连接方向反过来即可
-- ---------------------------------------------------------------------
WITH RECURSIVE nxt AS (
  SELECT CAST(p.course_id AS UNSIGNED) AS course_id, 1 AS depth
  FROM edu_dw.ods_course_prerequisite p
  WHERE CAST(p.prerequisite_course_id AS UNSIGNED) = 2
  UNION ALL
  SELECT CAST(p.course_id AS UNSIGNED), nxt.depth + 1
  FROM nxt
  JOIN edu_dw.ods_course_prerequisite p
    ON CAST(p.prerequisite_course_id AS UNSIGNED) = nxt.course_id
  WHERE nxt.depth < 10
)
SELECT DISTINCT nxt.course_id AS 后继课ID, dc.course_name AS 后继课名, nxt.depth AS 层级
FROM nxt LEFT JOIN edu_dw.dim_course dc ON dc.course_id = nxt.course_id
ORDER BY nxt.depth
LIMIT 10;


-- ---------------------------------------------------------------------
-- B3. 多层 CTE 拆解复杂统计（可读性优先）
--     业务：课程"选课人数 / 出勤率 / 挂科率"放一张表
--     关键点：复杂 SQL 面试时的正确答法是"拆成 CTE 分步算"，而不是硬写子查询
-- ---------------------------------------------------------------------
WITH sel AS (                     -- 第 1 步：选课人数
  SELECT term_id, course_id, COUNT(*) AS sel_cnt
  FROM edu_dw.fact_selection WHERE is_valid = 1 AND term_id = 202601
  GROUP BY term_id, course_id
),
att AS (                          -- 第 2 步：出勤率
  SELECT f.term_id, f.course_id,
         ROUND(SUM(CASE WHEN a.att_status=1 THEN 1 ELSE 0 END) / COUNT(*), 4) AS attend_rate
  FROM edu_dw.fact_attendance a
  JOIN edu_dw.fact_selection f
    ON f.term_id=a.term_id AND f.student_id=a.student_id AND f.schedule_id=a.schedule_id
  WHERE a.is_valid = 1 AND f.is_valid = 1 AND f.term_id = 202601
  GROUP BY f.term_id, f.course_id
),
sco AS (                          -- 第 3 步：挂科率
  SELECT term_id, course_id, fail_rate, avg_score
  FROM edu_dw.dws_course_term WHERE term_id = 202601
)
SELECT dc.course_name, sel.sel_cnt, att.attend_rate, sco.avg_score, sco.fail_rate
FROM sel
LEFT JOIN att ON att.term_id=sel.term_id AND att.course_id=sel.course_id
LEFT JOIN sco ON sco.term_id=sel.term_id AND sco.course_id=sel.course_id
JOIN edu_dw.dim_course dc ON dc.course_id = sel.course_id
ORDER BY sco.fail_rate DESC
LIMIT 8;


-- ---------------------------------------------------------------------
-- B4. 递归生成连续日期序列（补齐没有数据的日期）
--     业务：报表要求"每天都有数据"，没考的日期要补 0
--     关键点：用递归 CTE 生日期骨架，再 LEFT JOIN 事实表
-- ---------------------------------------------------------------------
WITH RECURSIVE dates(d) AS (
  SELECT DATE'2026-03-02'
  UNION ALL
  SELECT DATE_ADD(d, INTERVAL 1 DAY) FROM dates WHERE d < DATE'2026-03-15'
)
SELECT d.d AS 日期,
       DAYNAME(d.d) AS 星期,
       COUNT(a.attendance_sk) AS 考勤记录数,
       ROUND(SUM(CASE WHEN a.att_status=1 THEN 1 ELSE 0 END) / NULLIF(COUNT(a.attendance_sk),0), 3) AS 出勤率
FROM dates d
LEFT JOIN edu_dw.fact_attendance a
       ON a.session_date = d.d AND a.is_valid = 1
GROUP BY d.d
ORDER BY d.d;


-- #####################################################################
-- C. 行列转换（3 条，MySQL 没有 PIVOT，用 CASE + 聚合）
-- #####################################################################

-- ---------------------------------------------------------------------
-- C1. 学生的三个学期均分转成三列（行转列）
--     业务：报表要"一行一个学生，三列三个学期"
--     关键点：CASE WHEN + MAX/SUM 是 MySQL 的行转列标准写法
-- ---------------------------------------------------------------------
SELECT student_no, student_name,
       MAX(CASE WHEN term_id = 202501 THEN avg_score END) AS 第一学期均分,
       MAX(CASE WHEN term_id = 202502 THEN avg_score END) AS 第二学期均分,
       MAX(CASE WHEN term_id = 202601 THEN avg_score END) AS 第三学期均分,
       ROUND(AVG(avg_score), 2) AS 三学期平均
FROM edu_dw.dws_student_term
WHERE student_id <= 5
GROUP BY student_no, student_name
ORDER BY student_no;


-- ---------------------------------------------------------------------
-- C2. 把考勤状态转成 5 列（考勤状态分布）
--     业务：一个学生一学期出勤/迟到/早退/请假/旷课各多少次
--     关键点：先按 (学生,状态) 聚合，再行转列；注意 SUM 而不是 MAX
-- ---------------------------------------------------------------------
SELECT student_id,
       SUM(CASE WHEN att_status = 1 THEN 1 ELSE 0 END) AS 出勤,
       SUM(CASE WHEN att_status = 2 THEN 1 ELSE 0 END) AS 迟到,
       SUM(CASE WHEN att_status = 3 THEN 1 ELSE 0 END) AS 早退,
       SUM(CASE WHEN att_status = 4 THEN 1 ELSE 0 END) AS 请假,
       SUM(CASE WHEN att_status = 5 THEN 1 ELSE 0 END) AS 旷课,
       COUNT(*) AS 合计
FROM edu_dw.fact_attendance
WHERE is_valid = 1 AND term_id = 202601 AND student_id <= 5
GROUP BY student_id
ORDER BY student_id;


-- ---------------------------------------------------------------------
-- C3. 成绩分段占比转列（一学期一行，五列占比）
--     业务：一个学期的成绩分布图数据
--     关键点：占比要用窗口算总数，不能直接除 COUNT(*)
-- ---------------------------------------------------------------------
SELECT term_id,
       ROUND(SUM(CASE WHEN first_score >= 90 THEN 1 ELSE 0 END) / COUNT(*), 4) AS 优秀率,
       ROUND(SUM(CASE WHEN first_score >= 80 AND first_score < 90 THEN 1 ELSE 0 END) / COUNT(*), 4) AS 良好率,
       ROUND(SUM(CASE WHEN first_score >= 70 AND first_score < 80 THEN 1 ELSE 0 END) / COUNT(*), 4) AS 中等率,
       ROUND(SUM(CASE WHEN first_score >= 60 AND first_score < 70 THEN 1 ELSE 0 END) / COUNT(*), 4) AS 及格率,
       ROUND(SUM(CASE WHEN first_score < 60 THEN 1 ELSE 0 END) / COUNT(*), 4) AS 不及格率
FROM edu_dw.dwd_score_agg
WHERE first_score IS NOT NULL
GROUP BY term_id
ORDER BY term_id;


-- #####################################################################
-- D. 留存与连续（4 条）
-- #####################################################################

-- ---------------------------------------------------------------------
-- D1. 连续旷课 >= 2 次的学生（Gaps and Islands 经典题）
--     业务：连续缺勤才是危险信号，偶尔一次不算
--     关键点：核心技巧 —— "序号减日期/序号" 分组：
--            week_no - ROW_NUMBER() 相同 = 连续区间
-- ---------------------------------------------------------------------
WITH absent AS (
  SELECT student_id, schedule_id, week_no,
         ROW_NUMBER() OVER (PARTITION BY student_id, schedule_id ORDER BY week_no) AS rn
  FROM edu_dw.fact_attendance
  WHERE is_valid = 1 AND att_status = 5          -- 只取旷课
),
grp AS (
  SELECT student_id, schedule_id, week_no, week_no - rn AS island
  FROM absent
)
SELECT student_id, schedule_id, COUNT(*) AS 连续旷课次数,
       MIN(week_no) AS 起始周, MAX(week_no) AS 结束周
FROM grp
GROUP BY student_id, schedule_id, island
HAVING COUNT(*) >= 2
ORDER BY 连续旷课次数 DESC, student_id
LIMIT 10;


-- ---------------------------------------------------------------------
-- D2. 连续两个学期都挂科的学生（自连接）
--     业务：持续性学业问题，优先级高于单学期挂科
--     关键点：自连接 + 学期号差 1；也可以用 LAG 判断
-- ---------------------------------------------------------------------
SELECT a.student_id, a.student_no, a.student_name,
       a.term_id AS 前学期, a.fail_cnt AS 前学期挂科数,
       b.term_id AS 后学期, b.fail_cnt AS 后学期挂科数
FROM edu_dw.dws_student_term a
JOIN edu_dw.dws_student_term b
  ON b.student_id = a.student_id
 AND b.term_id IN (a.term_id + 1, a.term_id + 99)   -- 202501->202502, 202502->202601
WHERE a.fail_cnt >= 2 AND b.fail_cnt >= 2
LIMIT 10;


-- ---------------------------------------------------------------------
-- D3. 首考挂科但补考通过的比例（教学有效性）
--     业务：补考机制救回了多少学生
--     关键点：需要两个口径（first_score vs best_score），
--            这正是 dwd_score_agg 表存在的价值
-- ---------------------------------------------------------------------
SELECT term_id,
       COUNT(*) AS 出分总人次,
       SUM(CASE WHEN first_score < 60 THEN 1 ELSE 0 END) AS 正考挂科,
       SUM(makeup_pass) AS 补考通过,
       ROUND(SUM(makeup_pass) / NULLIF(SUM(CASE WHEN first_score < 60 THEN 1 ELSE 0 END), 0), 4) AS 补考通过率
FROM edu_dw.dwd_score_agg
WHERE first_score IS NOT NULL
GROUP BY term_id
ORDER BY term_id;


-- ---------------------------------------------------------------------
-- D4. 跨学期选课留存率（第 1 学期选课的学生，第 2 学期还选的比例）
--     业务：学生活跃度 / 流失分析
--     关键点：留存 = 后续仍有行为的人数 / 初始人数；
--            用 LEFT JOIN 或 EXISTS 判断"是否有后续行为"
-- ---------------------------------------------------------------------
SELECT a.term_id AS 学期,
       COUNT(DISTINCT a.student_id) AS 本学期学生数,
       COUNT(DISTINCT b.student_id) AS 下学期仍选课,
       ROUND(COUNT(DISTINCT b.student_id) / COUNT(DISTINCT a.student_id), 4) AS 留存率
FROM edu_dw.fact_selection a
LEFT JOIN edu_dw.fact_selection b
       ON b.student_id = a.student_id
      AND b.term_id = CASE a.term_id WHEN 202501 THEN 202502 WHEN 202502 THEN 202601 ELSE NULL END
      AND b.is_valid = 1
WHERE a.is_valid = 1 AND a.term_id IN (202501, 202502)
GROUP BY a.term_id
ORDER BY a.term_id;


-- #####################################################################
-- E. 复杂聚合（3 条）
-- #####################################################################

-- ---------------------------------------------------------------------
-- E1. 求成绩中位数（MySQL 没有 MEDIAN 函数）
--     业务：均分会被极端值拉偏，中位数更稳健
--     关键点：两种解法 ——
--            ① 窗口函数法（本写法）：取 rn 在中间位置的行
--            ② 排序后 LIMIT offset,1（只适合单组数据）
-- ---------------------------------------------------------------------
WITH s AS (
  SELECT total_score,
         ROW_NUMBER() OVER (ORDER BY total_score) AS rn,
         COUNT(*)     OVER ()                     AS cnt
  FROM edu_dw.fact_score
  WHERE is_valid = 1 AND term_id = 202601 AND total_score IS NOT NULL
)
SELECT ROUND(AVG(total_score), 2) AS 中位数,
       MAX(cnt) AS 样本数
FROM s
WHERE rn IN (FLOOR((cnt + 1) / 2), CEIL((cnt + 1) / 2));


-- ---------------------------------------------------------------------
-- E2. 按班级算成绩四分位（NTILE 分桶）
--     业务：班级内部的成绩分层（前 25% / 中间 / 后 25%）
--     关键点：NTILE(4) 是"等分桶"，不等于分位数（人数不能整除时会有偏差）
-- ---------------------------------------------------------------------
SELECT class_name, 分桶, COUNT(*) AS 人数, ROUND(AVG(avg_score), 2) AS 该桶均分
FROM (
  SELECT class_name, avg_score,
         NTILE(4) OVER (PARTITION BY term_id, class_id ORDER BY avg_score) AS 分桶
  FROM edu_dw.dws_student_term
  WHERE term_id = 202601 AND class_id <= 5
) t
GROUP BY class_name, 分桶
ORDER BY class_name, 分桶;


-- ---------------------------------------------------------------------
-- E3. 学期 KPI 的环比增长率
--     业务：这个学期比上个学期好了还是差了
--     关键点：增长率 = (本期-上期)/上期；LAG 取上期；
--            注意除零保护 NULLIF
-- ---------------------------------------------------------------------
SELECT term_name, avg_score, fail_rate, attend_rate,
       ROUND(avg_score - LAG(avg_score) OVER (ORDER BY term_id), 2) AS 均分变化,
       ROUND((fail_rate - LAG(fail_rate) OVER (ORDER BY term_id))
             / NULLIF(LAG(fail_rate) OVER (ORDER BY term_id), 0), 4) AS 挂科率变化率,
       ROUND((attend_rate - LAG(attend_rate) OVER (ORDER BY term_id))
             / NULLIF(LAG(attend_rate) OVER (ORDER BY term_id), 0), 4) AS 出勤率变化率
FROM edu_dw.ads_term_trend
ORDER BY term_id;
