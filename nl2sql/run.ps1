# =====================================================================
# Text2SQL 评测一键运行脚本
#
# 用法（在 PowerShell 里）：
#   cd C:\Users\c1669\Documents\deepseek-harness\default-workspace\nl2sql
#   powershell -ExecutionPolicy Bypass -File .\run.ps1
#
# 脚本会：
#   1. 自动找可用的 Python（本机系统 python 是空壳，用打包版）
#   2. 提示输入 DeepSeek API Key（不回显到脚本里，只存在当前会话）
#   3. 先跑 3 条验证 Key 可用（成本约 0.05 元）
#   4. 再跑完整两组：naive（朴素 schema）和 semantic（完整语义层）
# =====================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

Write-Host ''
Write-Host '================================================' -ForegroundColor Cyan
Write-Host '  Text2SQL 评测（语义层对照实验）' -ForegroundColor Cyan
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ''

# ---------- 1. 找 Python ----------
$py = 'C:\Users\c1669\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
if (-not (Test-Path $py)) {
    $c = Get-Command python -ErrorAction SilentlyContinue
    if ($c -and $c.Source -notmatch 'WindowsApps') {
        $py = $c.Source
    } else {
        Write-Host '找不到可用的 Python，请检查环境' -ForegroundColor Red
        exit 1
    }
}
Write-Host "Python: $py" -ForegroundColor DarkGray
$ver = & $py --version 2>&1
Write-Host "版本  : $ver" -ForegroundColor DarkGray

# ---------- 2. 依赖检查 ----------
& $py -c "import pymysql, yaml" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '缺少依赖，正在安装 pymysql + pyyaml ...' -ForegroundColor Yellow
    & $py -m pip install --quiet pymysql pyyaml
}

# ---------- 3. 数据库密码 ----------
if (-not $env:MYSQL_PWD) {
    Write-Host ''
    Write-Host '请输入 MySQL 密码（也可提前设置 $env:MYSQL_PWD）' -ForegroundColor Yellow
    $sec = Read-Host '密码'
    if ([string]::IsNullOrWhiteSpace($sec)) {
        Write-Host '未提供数据库密码，退出' -ForegroundColor Red
        exit 1
    }
    $env:MYSQL_PWD = $sec
}

# ---------- 4. API Key ----------
if (-not $env:DEEPSEEK_API_KEY) {
    Write-Host ''
    Write-Host '请粘贴 DeepSeek API Key（sk- 开头，输入时屏幕会显示，正常）' -ForegroundColor Yellow
    $env:DEEPSEEK_API_KEY = Read-Host 'API Key'
}
if ([string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
    Write-Host '未提供 API Key，退出' -ForegroundColor Red
    exit 1
}
Write-Host ("API Key: " + $env:DEEPSEEK_API_KEY.Substring(0, [Math]::Min(8, $env:DEEPSEEK_API_KEY.Length)) + '...') -ForegroundColor DarkGray

# ---------- 5. 先校验评测集 ----------
Write-Host ''
Write-Host '--- [1/4] 校验标准 SQL（不花 API 费用）---' -ForegroundColor Green
& $py runner/check_golden.py
if ($LASTEXITCODE -ne 0) { Write-Host '评测集校验失败' -ForegroundColor Red; exit 1 }

# ---------- 6. 试跑 3 条 ----------
Write-Host ''
Write-Host '--- [2/4] 试跑 3 条，验证 Key 可用（约 0.05 元）---' -ForegroundColor Green
& $py runner/run_eval.py --mode semantic --provider deepseek --limit 3
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '试跑失败。常见原因：' -ForegroundColor Red
    Write-Host '  · API Key 复制不完整（少了字符）'
    Write-Host '  · 账户没有余额（DeepSeek 需充值或用赠送额度）'
    Write-Host '  · 网络无法访问 api.deepseek.com'
    exit 1
}

# ---------- 7. 正式跑两组 ----------
Write-Host ''
Write-Host '--- [3/4] A 组：naive（只给表名+字段名）---' -ForegroundColor Green
& $py runner/run_eval.py --mode naive --provider deepseek

Write-Host ''
Write-Host '--- [4/4] B 组：semantic（完整语义层）---' -ForegroundColor Green
& $py runner/run_eval.py --mode semantic --provider deepseek

# ---------- 8. 汇总 ----------
Write-Host ''
Write-Host '================================================' -ForegroundColor Cyan
Write-Host '  完成！结果文件：' -ForegroundColor Cyan
Write-Host '================================================' -ForegroundColor Cyan
Get-ChildItem results\*.json | ForEach-Object { Write-Host ("  " + $_.Name + "  " + [Math]::Round($_.Length/1KB,1) + " KB") }

$naive = Get-Content results\naive.json -Raw -Encoding UTF8 | ConvertFrom-Json
$sem = Get-Content results\semantic.json -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ''
Write-Host '              执行成功率   结果一致率' -ForegroundColor White
Write-Host ("A 组 naive   : {0,6:P1}      {1,6:P1}" -f $naive.summary.exec_success_rate, $naive.summary.strict_pass_rate)
Write-Host ("B 组 semantic: {0,6:P1}      {1,6:P1}" -f $sem.summary.exec_success_rate, $sem.summary.strict_pass_rate)

$diff = $sem.summary.strict_pass_rate - $naive.summary.strict_pass_rate
Write-Host ''
Write-Host ("语义层带来的提升：{0:+0.0%;-0.0%}" -f $diff) -ForegroundColor Yellow
Write-Host ''
Write-Host '下一步：把这两个数字填进 REPORT.md 的 {{占位符}}' -ForegroundColor Cyan
Write-Host ''
