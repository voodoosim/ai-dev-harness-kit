#!/usr/bin/env bash
# =============================================================
#  dashboard-roll.sh  —  관제탑 집계기
#  여러 프로젝트의 STATUS.md + git 상태를 읽어 DASHBOARD.md 를 재생성한다.
#  판정은 감(感)이 아니라 숫자 규칙으로만 한다.
# =============================================================
set -uo pipefail

VERSION="1.1.0"

# ---------- 기본 설정 (dashboard.conf 로 덮어쓰기) ----------
PROJECTS=()                 # 명시 목록. 비어 있으면 SCAN_DIR 을 훑는다
SCAN_DIR="${HOME}/dev"      # 1단계 하위 디렉터리 중 git 저장소를 자동 수집
OUT="DASHBOARD.md"
WARN_DAYS=7                 # 🟡 기준: 마지막 커밋 경과일
DANGER_DAYS=14              # 🔴 기준
DEEP=0                      # 각 프로젝트에서 gate-check.sh 까지 실행
STATUS_FILE="STATUS.md"

CONF="$(dirname "$0")/dashboard.conf"
[ -f "dashboard.conf" ] && CONF="dashboard.conf"
[ -f "$CONF" ] && . "$CONF"

while [ $# -gt 0 ]; do
  case "$1" in
    --deep) DEEP=1; shift ;;
    --out) OUT="${2:-DASHBOARD.md}"; shift 2 ;;
    --scan) SCAN_DIR="${2:-}"; PROJECTS=(); shift 2 ;;
    --version) echo "dashboard-roll ${VERSION}"; exit 0 ;;
    -h|--help)
      cat <<'EOF'
사용법: ./dashboard-roll.sh [옵션]
  --deep         각 프로젝트에서 gate-check.sh 를 실행해 게이트 통과 여부까지 반영
  --scan 경로    해당 경로의 1단계 하위 git 저장소를 자동 수집
  --out 파일     출력 파일 (기본 DASHBOARD.md)
설정 파일: dashboard.conf  (PROJECTS / SCAN_DIR / WARN_DAYS / DANGER_DAYS)
EOF
      exit 0 ;;
    *) echo "알 수 없는 옵션: $1"; exit 2 ;;
  esac
done

# ---------- 프로젝트 수집 ----------
if [ "${#PROJECTS[@]}" -eq 0 ]; then
  [ -d "$SCAN_DIR" ] || { echo "스캔 경로 없음: $SCAN_DIR (dashboard.conf 에서 지정하세요)"; exit 2; }
  while IFS= read -r d; do PROJECTS+=("$d"); done < <(
    find "$SCAN_DIR" -maxdepth 2 -name .git -type d 2>/dev/null \
      | sed 's#/\.git$##' | sort
  )
fi
[ "${#PROJECTS[@]}" -eq 0 ] && { echo "대상 프로젝트가 없습니다."; exit 2; }

NOW_TS="$(date +%s)"
ROWS=""; ALERTS=""; N_G=0; N_Y=0; N_R=0

field() { # STATUS.md 표에서 값 추출:  | 항목 | 값 |
  grep -m1 -E "^\| *$2 *\|" "$1" 2>/dev/null \
    | awk -F'|' '{print $3}' | sed 's/^ *//; s/ *$//; s/\*\*//g'
}

for P in "${PROJECTS[@]}"; do
  [ -d "$P/.git" ] || continue
  NAME="$(basename "$P")"
  SF="$P/$STATUS_FILE"

  # --- git 사실관계 ---
  LAST_TS="$(git -C "$P" log -1 --pretty=%ct 2>/dev/null || echo 0)"
  if [ "$LAST_TS" -gt 0 ]; then
    DAYS=$(( (NOW_TS - LAST_TS) / 86400 ))
    LAST_SUBJ="$(git -C "$P" log -1 --pretty=%s | cut -c1-40)"
  else
    DAYS=999; LAST_SUBJ="(커밋 없음)"
  fi
  BRANCH="$(git -C "$P" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  DIRTY="$(git -C "$P" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

  # --- STATUS.md 사실관계 ---
  if [ -f "$SF" ]; then
    GATE="$(field "$SF" "현재 게이트")"; [ -z "$GATE" ] && GATE="?"
    AGENT="$(field "$SF" "담당 AI")"; [ -z "$AGENT" ] && AGENT="-"
    TODO_N="$(grep -cE '^[-*] \[ \] +[^[:space:]]' "$SF" 2>/dev/null)"; TODO_N="${TODO_N:-0}"
    BLOCK="$(sed -n '/### 차단 요인/,/^###/p' "$SF" 2>/dev/null \
              | grep '^- ' | grep -v '없음' | head -1 | sed 's/^- //' | cut -c1-40)"
    HAS_STATUS=1
  else
    GATE="?"; AGENT="-"; TODO_N=0; BLOCK=""; HAS_STATUS=0
  fi

  # --- 게이트 검증 (--deep) ---
  GC="-"
  if [ "$DEEP" -eq 1 ] && [ -x "$P/gate-check.sh" ]; then
    if (cd "$P" && ./gate-check.sh >/dev/null 2>&1); then GC="통과"; else GC="실패"; fi
  fi

  # --- 판정 규칙 ---
  MARK="🟢"; REASONS=()
  if [ "$HAS_STATUS" -eq 0 ]; then MARK="🔴"; REASONS+=("STATUS.md 없음 — 인수인계 불가"); fi
  if [ "$DAYS" -ge "$DANGER_DAYS" ]; then MARK="🔴"; REASONS+=("${DAYS}일간 커밋 없음"); fi
  if [ -n "$BLOCK" ]; then MARK="🔴"; REASONS+=("차단: $BLOCK"); fi
  if [ "$GC" = "실패" ]; then MARK="🔴"; REASONS+=("게이트 검증 실패"); fi
  if [ "$MARK" != "🔴" ]; then
    if [ "$DAYS" -ge "$WARN_DAYS" ]; then MARK="🟡"; REASONS+=("${DAYS}일간 커밋 없음"); fi
    if [ "$TODO_N" -eq 0 ] && [ "$HAS_STATUS" -eq 1 ]; then MARK="🟡"; REASONS+=("다음 할 일 미기재"); fi
    if [ "$DIRTY" -ge 10 ]; then MARK="🟡"; REASONS+=("미커밋 ${DIRTY}건"); fi
  fi
  case "$MARK" in 🟢) N_G=$((N_G+1));; 🟡) N_Y=$((N_Y+1));; 🔴) N_R=$((N_R+1));; esac

  AGO="$([ "$DAYS" -ge 999 ] && echo '-' || echo "${DAYS}일 전")"
  ROWS+="| $MARK | **$NAME** | $GATE | $AGENT | \`$BRANCH\` | $LAST_SUBJ | $AGO | $TODO_N | $GC |"$'\n'

  if [ "${#REASONS[@]}" -gt 0 ]; then
    ALERTS+="- $MARK **$NAME** — $(printf '%s · ' "${REASONS[@]}" | sed 's/ · $//')"$'\n'
  fi
done

TOTAL=$((N_G+N_Y+N_R))
{
cat <<EOF
# DASHBOARD — 프로젝트 관제탑

> 자동 생성: $(date '+%Y-%m-%d %H:%M') · \`dashboard-roll.sh\` · 직접 수정하지 마세요.

**전체 ${TOTAL}개** · 🟢 정상 ${N_G} · 🟡 주의 ${N_Y} · 🔴 위험 ${N_R}

| | 프로젝트 | 게이트 | 담당 | 브랜치 | 마지막 작업 | 경과 | 할일 | 검증 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
${ROWS}
EOF

if [ -n "$ALERTS" ]; then
  echo "## 조치 필요"
  echo
  printf '%s\n' "$ALERTS"
else
  echo "## 조치 필요"
  echo
  echo "- 없음"
  echo
fi

cat <<EOF
---

### 판정 규칙
- 🔴 — STATUS.md 없음 / 마지막 커밋 ${DANGER_DAYS}일 초과 / 차단 요인 기재됨 / 게이트 검증 실패
- 🟡 — 마지막 커밋 ${WARN_DAYS}일 초과 / 다음 할 일 미기재 / 미커밋 10건 이상
- 🟢 — 위 항목 해당 없음

_검증 열은 \`--deep\` 실행 시에만 채워집니다._
EOF
} > "$OUT"

printf "%s 생성 완료 · 총 %d개 (🟢%d 🟡%d 🔴%d)\n" "$OUT" "$TOTAL" "$N_G" "$N_Y" "$N_R"
[ "$N_R" -gt 0 ] && exit 1 || exit 0
