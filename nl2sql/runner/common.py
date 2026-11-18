# -*- coding: utf-8 -*-
"""公共工具：数据库连接、SQL 执行、结果集归一化与比对"""
import os
import re
import sys

import pymysql
import yaml

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DB_CONFIG = {
    "host": os.environ.get("NL2SQL_DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("NL2SQL_DB_PORT", "3307")),
    "user": os.environ.get("NL2SQL_DB_USER", "root"),
    "password": os.environ.get("NL2SQL_MYSQL_PWD") or os.environ.get("MYSQL_PWD", ""),
    "database": os.environ.get("NL2SQL_DB_NAME", "edu_dw"),
    "charset": "utf8mb4",
    "connect_timeout": 15,
}

FORBIDDEN = re.compile(
    r"\b(insert|update|delete|drop|truncate|alter|create|grant|revoke|replace)\b",
    re.IGNORECASE,
)


def load_yaml(rel_path):
    path = os.path.join(BASE, rel_path)
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def get_conn():
    if not DB_CONFIG["password"]:
        sys.exit(
            "未提供数据库密码。请设置环境变量 MYSQL_PWD（或 NL2SQL_MYSQL_PWD）后重试。\n"
            "  PowerShell:  $env:MYSQL_PWD='你的密码'"
        )
    return pymysql.connect(**DB_CONFIG)


def is_safe_select(sql):
    """只允许单条 SELECT / WITH 查询"""
    s = sql.strip().rstrip(";")
    if not s:
        return False, "空语句"
    if ";" in s:
        return False, "包含多条语句"
    if not re.match(r"^\s*(select|with)\b", s, re.IGNORECASE):
        return False, "不是 SELECT 查询"
    if FORBIDDEN.search(s):
        return False, "包含写操作关键字"
    return True, ""


def run_sql(conn, sql, max_rows=10000):
    """执行查询，返回 (columns, rows)"""
    with conn.cursor() as cur:
        cur.execute(sql)
        cols = [d[0] for d in cur.description] if cur.description else []
        rows = cur.fetchmany(max_rows) if cur.description else []
    return cols, rows


def normalize_value(v, ndigits=4):
    if v is None:
        return None
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (int, float)):
        # 统一保留 4 位小数，避免 0.1048 与 0.10480 被判为不同
        return round(float(v), ndigits)
    if isinstance(v, bytes):
        return v.hex()
    s = str(v).strip()
    return s


def normalize_rows(rows, ndigits=4):
    """归一化：数值统一小数位 + 忽略行顺序（按内容排序）"""
    norm = [tuple(normalize_value(v, ndigits) for v in row) for row in rows]
    return sorted(norm, key=lambda r: tuple(str(x) for x in r))


def compare_results(gen_rows, gold_rows, ndigits=4):
    """
    结果集比对，返回 (status, detail)
      PASS          —— 完全一致（忽略行序）
      PASS_LENIENT  —— 行数一致，且标准答案的每个值都出现在生成结果里（允许生成结果多列）
      RESULT_MISMATCH —— 数值或行数不同
    """
    g = normalize_rows(gen_rows, ndigits)
    w = normalize_rows(gold_rows, ndigits)

    if g == w:
        return "PASS", {"gen_rows": len(g), "gold_rows": len(w)}

    if len(g) == len(w):
        flat_gen = [v for row in g for v in row if v is not None]
        flat_gold = [v for row in w for v in row if v is not None]
        # 标准答案的每个值都能在生成结果中找到
        if all(v in flat_gen for v in flat_gold):
            return "PASS_LENIENT", {"gen_rows": len(g), "gold_rows": len(w)}

    return "RESULT_MISMATCH", {
        "gen_rows": len(g),
        "gold_rows": len(w),
        "gen_sample": g[:3],
        "gold_sample": w[:3],
    }


def is_reject(sql):
    """模型是否输出了拒绝标记"""
    if sql is None:
        return True
    s = str(sql).strip().upper()
    return s == "" or "INSUFFICIENT_SCHEMA" in s


def extract_sql(text):
    """从模型输出里抽出 SQL（去掉 ```sql 代码块、解释性文字）"""
    if not text:
        return ""
    t = text.strip()
    if "INSUFFICIENT_SCHEMA" in t.upper():
        return "INSUFFICIENT_SCHEMA"
    m = re.search(r"```(?:sql)?\s*(.*?)```", t, re.DOTALL | re.IGNORECASE)
    if m:
        t = m.group(1)
    # 取第一条 SELECT/WITH 到分号
    m = re.search(r"(?is)\b(select|with)\b.*?;", t)
    if m:
        return m.group(0).strip()
    m = re.search(r"(?is)\b(select|with)\b.*$", t)
    if m:
        return m.group(0).strip().rstrip(";")
    return t
