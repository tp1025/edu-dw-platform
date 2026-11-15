@echo off
REM =====================================================================
REM 在 Windows 本地导出 4 张 ODS 表为 TSV（供上传到 Hive）
REM 用法：双击运行，或在 cmd 里执行 export_ods.bat
REM 产物：当前目录下 ods_class.tsv / ods_student.tsv / ods_selection.tsv / ods_score.tsv
REM 要点：
REM   -B  批量模式（TSV，自动转义特殊字符）
REM   -N  不输出列名表头（否则会多一行脏数据）
REM   HEX() 处理二进制密文字段
REM   不导出 dt 列 —— 它在 Hive 里是分区列，装载时指定
REM =====================================================================

REM MySQL 客户端路径（按自己环境改）
set MYSQL="C:\Program Files\MySQL\MySQL Server 26.10\bin\mysql.exe"

REM 密码不写死：优先读环境变量，没有则交互输入
if not defined MYSQL_PWD set /p MYSQL_PWD=Enter MySQL password:

REM 连接参数（主机/端口/用户名按自己环境改）
set CONN=-h 127.0.0.1 -P 3307 -u root --protocol=TCP --default-character-set=utf8mb4 -B -N

echo [1/4] ods_class ...
%MYSQL% %CONN% -e "SELECT row_id,class_id,major_id,teacher_id,class_no,class_name,enroll_year,deleted_at,created_at,updated_at,src_table,etl_time FROM edu_dw.ods_class" > ods_class.tsv

echo [2/4] ods_student ...
%MYSQL% %CONN% -e "SELECT row_id,student_id,class_id,student_no,student_name,gender,deleted_at,created_at,updated_at,id_card_hash,HEX(id_card_cipher),phone_hash,HEX(phone_cipher),src_table,etl_time FROM edu_dw.ods_student" > ods_student.tsv

echo [3/4] ods_selection ...
%MYSQL% %CONN% -e "SELECT row_id,selection_id,student_id,schedule_id,term_id,select_status,creator,remark,deleted_at,created_at,updated_at,src_table,etl_time FROM edu_dw.ods_selection" > ods_selection.tsv

echo [4/4] ods_score ...
%MYSQL% %CONN% -e "SELECT row_id,score_id,student_id,schedule_id,exam_type,term_id,total_score,score_status,is_manual_adjust,rule_version,creator,remark,deleted_at,created_at,updated_at,usual_score,final_score,src_table,etl_time FROM edu_dw.ods_score" > ods_score.tsv

echo.
echo ===== 导出完成，文件大小 =====
dir ods_*.tsv
echo.
echo ===== 行数核对（应分别为 400 / 20000 / 480005 / 474922）=====
for %%f in (ods_class ods_student ods_selection ods_score) do (
  find /c /v "" %%f.tsv
)
pause
