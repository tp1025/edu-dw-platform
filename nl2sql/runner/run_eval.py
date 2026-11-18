# -*- coding: utf-8 -*-
"""Text2SQL 评测主脚本

功能：
  1. 构造 Prompt（naive / semantic 两种模式的唯一差别就在 schema 描述）
  2. 调用 LLM 生成 SQL（DeepSeek API，或从文件读取）
  3. 执行生成的 SQL，与 golden SQL 做结果集比对
  4. 输出准确率报告（JSON + 控制台）

用法：
  # A. 调 API（推荐）
  $env:MYSQL_PWD='数据库密码'
  $env:DEEPSEEK_API_KEY='sk-xxx'
  python runner/run_eval.py --mode semantic --provider deepseek

  # B. 从文件读（手工贴 prompt 的兜底方案，文件放 generated/semantic/Q01.sql）
  python runner/run_eval.py --mode semantic --provider file

  # C. 只跑对照实验的两组
  python runner/run_eval.py --mode naive    --provider deepseek
  python runner/run_eval.py --mode semantic --provider deepseek
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (  # noqa: E402
    BASE, compare_results, extract_sql, get_conn, is_reject, is_safe_select,
    load_yaml, run_sql,
)

DEEPSEEK_URL = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com/chat/completions")
DEEPSEEK_MODEL = os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")


# ---------------------------------------------------------------------
# Prompt 构造：两种模式的唯一差别就是 schema 的丰富程度
# ---------------------------------------------------------------------
def _all_tables(sem):
    tabs = dict(sem.get("tables") or {})
    for k, v in (sem.get("dws_tables") or {}).items():
        tabs[k] = v
    return tabs


def render_naive_schema(sem):
    """朴素模式：只给表名 + 字段名 + 类型（等价 SHOW COLUMNS），不含任何业务语义"""
    lines = ["【可用表结构】"]
    for name, t in _all_tables(sem).items():
        cols = ", ".join(f"{f['name']}({f.get('type','')})" for f in t.get("fields", []))
        lines.append(f"{name}: {cols}")
    return "\n".join(lines)


def render_semantic_schema(sem):
    """语义模式：完整语义层（字段含义 + 口径 + 枚举值 + 使用边界 + 表间关系）"""
    import yaml as _yaml

    payload = {
        "global": sem.get("global"),
        "tables": sem.get("tables"),
        "dws_tables": sem.get("dws_tables"),
        "relations": sem.get("relations"),
    }
    return "【语义层：表结构 + 业务口径 + 枚举值 + 表间关系】\n" + _yaml.safe_dump(
        payload, allow_unicode=True, sort_keys=False, width=200
    )


SYSTEM_PROMPT = (
    "你是 MySQL 专家。根据给定的表结构回答问题，**只输出一条可执行的 SELECT 语句**。\n"
    "规则：\n"
    "1. 不要输出任何解释、思路或 Markdown 代码块标记，只输出 SQL 本身。\n"
    "2. 如果给定表无法回答问题（例如涉及敏感字段），只输出：INSUFFICIENT_SCHEMA\n"
    "3. 涉及学生/教师的身份证号、手机号等敏感信息，一律输出 INSUFFICIENT_SCHEMA。\n"
    "4. 只读查询，禁止 INSERT/UPDATE/DELETE/DROP 等写操作。"
)


def build_messages(sem, question, mode):
    schema = render_naive_schema(sem) if mode == "naive" else render_semantic_schema(sem)
    user = f"{schema}\n\n【问题】\n{question}\n\n请只输出 SQL。"
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user},
    ]


# ---------------------------------------------------------------------
# LLM 调用
# ---------------------------------------------------------------------
def call_deepseek(messages, retries=3, timeout=90):
    api_key = os.environ.get("DEEPSEEK_API_KEY", "")
    if not api_key:
        raise RuntimeError("未设置 DEEPSEEK_API_KEY 环境变量")
    body = json.dumps(
        {"model": DEEPSEEK_MODEL, "messages": messages, "temperature": 0, "max_tokens": 800}
    ).encode("utf-8")
    req = urllib.request.Request(
        DEEPSEEK_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    last_err = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.loads(r.read().decode("utf-8"))
            return data["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            last_err = f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:200]}"
        except Exception as e:
            last_err = f"{type(e).__name__}: {e}"
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"调用失败: {last_err}")


def load_from_file(mode, qid):
    path = os.path.join(BASE, "generated", mode, f"{qid}.sql")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


# ---------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["naive", "semantic"], default="semantic")
    ap.add_argument("--provider", choices=["deepseek", "file"], default="deepseek")
    ap.add_argument("--limit", type=int, default=0, help="只跑前 N 条（调试用）")
    ap.add_argument("--save-prompt", action="store_true", help="把 Prompt 存到文件（手工贴用）")
    args = ap.parse_args()

    sem = load_yaml("semantic_layer/tables.yaml")
    questions = load_yaml("golden_set/questions.yaml")["questions"]
    if args.limit:
        questions = questions[: args.limit]

    os.makedirs(os.path.join(BASE, "prompts", args.mode), exist_ok=True)
    conn = get_conn()

    details = []
    print(f"\n模式={args.mode}  提供方={args.provider}  题目数={len(questions)}\n")
    print(f"{'ID':<5}{'类别':<10}{'状态':<16}耗时    说明")
    print("-" * 105)

    for q in questions:
        qid, cat, question = q["id"], q.get("category", ""), q["question"]
        t0 = time.time()
        rec = {
            "id": qid, "category": cat, "question": question,
            "golden_sql": q.get("golden_sql"), "trap": q.get("trap"),
        }

        # ---------- 1. 生成 ----------
        try:
            if args.provider == "deepseek":
                raw = call_deepseek(build_messages(sem, question, args.mode))
            else:
                raw = load_from_file(args.mode, qid)
                if raw is None:
                    rec.update(status="NO_INPUT", note=f"缺少 generated/{args.mode}/{qid}.sql")
                    details.append(rec)
                    print(f"{qid:<5}{cat:<10}{'NO_INPUT':<16}{'-':<8}缺生成文件")
                    continue
            if args.save_prompt:
                with open(os.path.join(BASE, "prompts", args.mode, f"{qid}.txt"), "w",
                          encoding="utf-8") as f:
                    f.write(json.dumps(build_messages(sem, question, args.mode),
                                       ensure_ascii=False, indent=2))
        except Exception as e:
            rec.update(status="GEN_FAIL", note=str(e)[:120])
            details.append(rec)
            print(f"{qid:<5}{cat:<10}{'GEN_FAIL':<16}{'-':<8}{str(e)[:50]}")
            continue

        rec["raw_output"] = raw
        sql = extract_sql(raw)
        rec["generated_sql"] = sql

        # ---------- 2. 应拒绝题 ----------
        if q.get("golden_sql") is None:
            ok = is_reject(sql)
            rec.update(status="PASS" if ok else "SHOULD_REJECT")
            details.append(rec)
            print(f"{qid:<5}{cat:<10}{rec['status']:<16}{time.time()-t0:5.1f}s  "
                  f"{'正确拒绝' if ok else '未拒绝: ' + str(sql)[:40]}")
            continue

        # ---------- 3. 安全检查 ----------
        safe, why = is_safe_select(sql)
        if not safe:
            rec.update(status="UNSAFE_SQL", note=why)
            details.append(rec)
            print(f"{qid:<5}{cat:<10}{'UNSAFE_SQL':<16}{time.time()-t0:5.1f}s  {why}")
            continue

        # ---------- 4. 执行 + 比对 ----------
        try:
            gen_rows = run_sql(conn, sql)[1]
        except Exception as e:
            rec.update(status="EXEC_FAIL", note=str(e)[:120])
            details.append(rec)
            print(f"{qid:<5}{cat:<10}{'EXEC_FAIL':<16}{time.time()-t0:5.1f}s  {str(e)[:50]}")
            continue

        gold_rows = run_sql(conn, q["golden_sql"])[1]
        status, detail = compare_results(gen_rows, gold_rows)
        rec.update(status=status, detail=detail, elapsed=round(time.time() - t0, 1))
        details.append(rec)
        note = "" if status == "PASS" else json.dumps(detail, ensure_ascii=False, default=str)[:60]
        print(f"{qid:<5}{cat:<10}{status:<16}{time.time()-t0:5.1f}s  {note}")

    conn.close()

    # ---------- 汇总 ----------
    total = len(details)
    passed = [d for d in details if d["status"] == "PASS"]
    lenient = [d for d in details if d["status"] == "PASS_LENIENT"]
    exec_ok = [d for d in details if d["status"] not in ("EXEC_FAIL", "UNSAFE_SQL", "GEN_FAIL", "NO_INPUT")]

    by_cat = defaultdict(lambda: {"total": 0, "strict": 0, "lenient": 0})
    for d in details:
        c = d["category"]
        by_cat[c]["total"] += 1
        if d["status"] == "PASS":
            by_cat[c]["strict"] += 1
        if d["status"] in ("PASS", "PASS_LENIENT"):
            by_cat[c]["lenient"] += 1

    fail_reasons = Counter(d["status"] for d in details if d["status"] not in ("PASS", "PASS_LENIENT"))

    summary = {
        "mode": args.mode,
        "provider": args.provider,
        "model": DEEPSEEK_MODEL if args.provider == "deepseek" else "file",
        "run_at": datetime.now().isoformat(timespec="seconds"),
        "total": total,
        "exec_success": len(exec_ok),
        "exec_success_rate": round(len(exec_ok) / total, 4) if total else 0,
        "strict_pass": len(passed),
        "strict_pass_rate": round(len(passed) / total, 4) if total else 0,
        "pass_with_lenient": len(passed) + len(lenient),
        "pass_rate_with_lenient": round((len(passed) + len(lenient)) / total, 4) if total else 0,
        "by_category": {
            k: {
                **v,
                "strict_rate": round(v["strict"] / v["total"], 4),
                "lenient_rate": round(v["lenient"] / v["total"], 4),
            }
            for k, v in by_cat.items()
        },
        "fail_reasons": dict(fail_reasons),
    }

    out_dir = os.path.join(BASE, "results")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{args.mode}.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "details": details}, f, ensure_ascii=False,
                  indent=2, default=str)

    print("\n" + "=" * 105)
    print(f"执行成功率 : {summary['exec_success']}/{total} = {summary['exec_success_rate']:.1%}")
    print(f"结果一致率 : {summary['strict_pass']}/{total} = {summary['strict_pass_rate']:.1%} "
          f"(宽松计法 {summary['pass_rate_with_lenient']:.1%})")
    print("\n按题型（严格 / 宽松）：")
    for k, v in summary["by_category"].items():
        print(f"  {k:<10} strict {v['strict']}/{v['total']} ({v['strict_rate']:.0%})"
              f"   lenient {v['lenient']}/{v['total']} ({v['lenient_rate']:.0%})")
    if fail_reasons:
        print("\n失败原因：")
        for k, n in fail_reasons.items():
            print(f"  {k:<18} {n} 条")
    print(f"\n明细已写入: {out_path}")

    # 全部生成失败（如 API Key 无效）→ 返回非 0，让外层脚本能中断
    if total > 0 and len(exec_ok) == 0:
        print("\n⚠️ 所有题目都生成失败，请检查 API Key / 网络 / 余额", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
