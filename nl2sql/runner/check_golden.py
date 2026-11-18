# -*- coding: utf-8 -*-
"""校验评测集：确认每条 golden SQL 都能执行，并打印真实结果

用法（PowerShell）：
  $env:MYSQL_PWD='你的密码'
  python runner/check_golden.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import get_conn, load_yaml, run_sql, is_safe_select  # noqa: E402


def main():
    questions = load_yaml("golden_set/questions.yaml")["questions"]
    conn = get_conn()
    ok = fail = skip = 0
    print(f"{'ID':<5}{'类别':<10}{'状态':<8}结果预览")
    print("-" * 100)
    for q in questions:
        qid, cat, sql = q["id"], q.get("category", ""), q.get("golden_sql")
        try:
            if sql is None:
                skip += 1
                expect = q.get("expect", "INSUFFICIENT_SCHEMA")
                print(f"{qid:<5}{cat:<10}{'SKIP':<8}应拒绝题（期望模型输出 {expect}）")
                continue
            safe, why = is_safe_select(sql)
            if not safe:
                fail += 1
                print(f"{qid:<5}{cat:<10}{'UNSAFE':<8}{why}")
                continue
            cols, rows = run_sql(conn, sql)
            ok += 1
            preview = str(rows[:2])[:70]
            print(f"{qid:<5}{cat:<10}{'OK':<8}{len(rows)} 行  {preview}")
        except Exception as e:
            fail += 1
            print(f"{qid:<5}{cat:<10}{'ERROR':<8}{type(e).__name__}: {str(e)[:80]}")
    conn.close()
    print("-" * 100)
    print(f"可执行 {ok} 条 | 失败 {fail} 条 | 应拒绝 {skip} 条 | 合计 {len(questions)} 条")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
