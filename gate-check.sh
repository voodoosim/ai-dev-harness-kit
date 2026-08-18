#!/usr/bin/env bash
# =============================================================
#  gate-check.sh  —  게이트 기계 검증기
#  완료 조건 6항목을 사람 판단이 아니라 exit code 로 판정한다.
#  통과: exit 0 / 실패: exit 1 / 설정 오류: exit 2
# =============================================================
set -uo pipefail

VERSION="2.1.0"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 2

# ---------- 기본 설정 (gate-check.conf 로 덮어쓰기 가능) ----------
GATE="G3"                 # 검증할 게이트 (G3=구현완료, G4=출시가능)
BUILD_CMD=""              # 비우면 스택 자동 감지
TEST_CMD=""
LINT_CMD=""
STATUS_FILE="STATUS.md"
DOCS_DIR="docs"
STATUS_REQUIRED=("현재 게이트" "마지막 작업" "다음 할 일" "담당 AI")
DOC_REQUIRED=("## 목표" "## 범위" "## 완료 조건")
COMMIT_PREFIXES="feat|fix|docs|refactor|test|chore|build|perf"
STATUS_MAX_AGE_COMMITS=1  # STATUS.md 가 최근 N 커밋 안에 갱신됐어야 함
SKIP=""
DELEGATE=1               # husky/commitlint/pre-commit 가 있으면 위임
GATE_SET=0               # --gate 로 명시했는지
FASTTRACK=0
LOG=".kit/gate-log.tsv"  # 실행 기록 (측정용)

[ -f "gate-check.conf" ] && . ./gate-check.conf

# ---------- 인자 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE="${2:-G3}"; GATE_SET=1; shift 2 ;;
    --stats) MODE_STATS=1; shift ;;
    --skip) SKIP="${SKIP},${2:-}"; shift 2 ;;
    --no-delegate) DELEGATE=0; shift ;;
    --version) echo "gate-check ${VERSION}"; exit 0 ;;
    -h|--help)
      cat <<'EOF'
사용법: ./gate-check.sh [옵션]
  --gate G3|G4     검증 게이트 (기본: .gate 파일, 없으면 패스트트랙)
  --skip 이름      개별 검사 생략 (build|test|lint|docs|status|commit)
                   예: --skip build --skip lint
  --no-delegate    commitlint/pre-commit 위임 없이 자체 검사만 사용
  --stats          첫 시도 통과율 등 측정 지표 출력
  --version        버전 출력
설정 파일: 프로젝트 루트의 gate-check.conf (쉘 변수 형식)
EOF
      exit 0 ;;
    *) echo "알 수 없는 옵션: $1"; exit 2 ;;
  esac
done

# ---------- --stats : 측정 지표 ----------
if [ "${MODE_STATS:-0}" -eq 1 ]; then
  if [ ! -f "$LOG" ]; then echo "기록 없음: $LOG (gate-check 를 몇 번 실행한 뒤 다시 보세요)"; exit 0; fi
  awk -F'\t' '
    { total++; if (!seen[$3]++) { first++; if ($4=="PASS") firstpass++ } if ($4=="PASS") pass++ }
    END {
      printf "\n게이트 검증 기록\n──────────────────────────────\n"
      printf "  전체 실행        %d회 (통과 %d · 실패 %d)\n", total, pass, total-pass
      printf "  커밋별 첫 시도   %d회 중 %d회 통과", first, firstpass
      if (first>0) printf "  →  %.0f%%", firstpass*100/first
      printf "\n\n  첫 시도 통과율이 추세적으로 오르면 시스템이 작동하는 것입니다.\n"
      printf "  느낌이 아니라 이 숫자로 판단하세요.\n\n"
    }' "$LOG"
  echo "  최근 10회:"
  tail -10 "$LOG" | awk -F'\t' '{printf "    %s  %-6s %s\n", $1, $2, ($4=="PASS"?"✓ 통과":"✗ 실패")}'
  echo
  exit 0
fi

# ---------- 게이트 결정 : .gate 없으면 패스트트랙 ----------
if [ "$GATE_SET" -eq 0 ]; then
  if [ -f ".gate" ]; then GATE="$(tr -d ' \n' < .gate)"
  else GATE="패스트트랙"; FASTTRACK=1; SKIP="${SKIP},docs"; fi
fi

# ---------- 출력 ----------
if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=""; G=""; Y=""; B=""; N=""; fi

PASS=0; FAIL=0; SKIPPED=0
declare -a FAIL_MSGS=()

ok()   { PASS=$((PASS+1));    printf "  %s✓%s %s\n" "$G" "$N" "$1"; }
ng()   { FAIL=$((FAIL+1));    printf "  %s✗%s %s\n" "$R" "$N" "$1"; FAIL_MSGS+=("$1 → $2"); }
skip() { SKIPPED=$((SKIPPED+1)); printf "  %s-%s %s (생략)\n" "$Y" "$N" "$1"; }
is_skipped() { case ",$SKIP," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

run_quiet() { # 명령 실행, 실패 시 마지막 15줄만 보여줌
  local out
  if out="$(eval "$1" 2>&1)"; then return 0
  else printf '%s\n' "$out" | tail -15 | sed 's/^/      │ /'; return 1; fi
}

# ---------- 스택 자동 감지 ----------
detect_stack() {
  if [ -f "package.json" ]; then
    local PM="npm"
    [ -f "pnpm-lock.yaml" ] && PM="pnpm"
    [ -f "yarn.lock" ]      && PM="yarn"
    [ -f "bun.lockb" ]      && PM="bun"
    has() { grep -q "\"$1\"[[:space:]]*:" package.json 2>/dev/null; }
    [ -z "$BUILD_CMD" ] && has build && BUILD_CMD="$PM run build"
    [ -z "$TEST_CMD"  ] && has test  && TEST_CMD="$PM test"
    [ -z "$LINT_CMD"  ] && has lint  && LINT_CMD="$PM run lint"
    STACK="Node ($PM)"
  elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ]; then
    [ -z "$TEST_CMD" ] && TEST_CMD="pytest -q"
    [ -z "$LINT_CMD" ] && { command -v ruff >/dev/null && LINT_CMD="ruff check ."; }
    STACK="Python"
  elif [ -f "go.mod" ]; then
    [ -z "$BUILD_CMD" ] && BUILD_CMD="go build ./..."
    [ -z "$TEST_CMD"  ] && TEST_CMD="go test ./..."
    [ -z "$LINT_CMD"  ] && { command -v golangci-lint >/dev/null && LINT_CMD="golangci-lint run"; }
    STACK="Go"
  else
    STACK="미감지"
  fi
}
detect_stack

# ---------- 0. 환경 자가 복구 ----------
# core.hooksPath 는 .git/config 에 저장되어 클론 시 전파되지 않는다.
# .githooks/ 는 커밋되어 따라오므로, 연결만 다시 붙여준다.
if [ -d ".githooks" ] && [ "$(git config core.hooksPath 2>/dev/null)" != ".githooks" ]; then
  git config core.hooksPath .githooks
  printf "\e[33m⚙ core.hooksPath 가 끊겨 있어 .githooks 로 다시 연결했습니다. (클론 직후 정상)\e[0m\n"
fi

printf "\n%s게이트 검증 [%s]%s  ·  스택: %s  ·  %s\n" "$B" "$GATE" "$N" "$STACK" "$(basename "$ROOT")"
printf "%s\n" "──────────────────────────────────────────────"

# ---------- 1. 빌드 ----------
if is_skipped build; then skip "1. 빌드"
elif [ -z "$BUILD_CMD" ]; then skip "1. 빌드 (빌드 명령 없음)"
elif run_quiet "$BUILD_CMD"; then ok "1. 빌드 통과"
else ng "1. 빌드 실패" "$BUILD_CMD 가 0이 아닌 코드로 종료"; fi

# ---------- 2. 테스트 ----------
if is_skipped test; then skip "2. 테스트"
elif [ -z "$TEST_CMD" ] && [ "$FASTTRACK" -eq 1 ]; then
  skip "2. 테스트 (명령 없음 — 패스트트랙이라 경고만)"
  printf "      │ 배포 대상이라면 테스트를 붙이고 \`echo G0 > .gate\` 로 전체 게이트를 켜세요.\n"
elif [ -z "$TEST_CMD" ]; then ng "2. 테스트 명령 없음" "package.json/pyproject 에 테스트 스크립트를 정의하거나 gate-check.conf 에 TEST_CMD 지정"
elif run_quiet "$TEST_CMD"; then ok "2. 테스트 통과"
else ng "2. 테스트 실패" "$TEST_CMD"; fi

# ---------- 3. 린트 ----------
if is_skipped lint; then skip "3. 린트"
elif [ "$DELEGATE" -eq 1 ] && [ -f ".pre-commit-config.yaml" ] && command -v pre-commit >/dev/null 2>&1; then
  if run_quiet "pre-commit run --all-files"; then ok "3. 린트 통과 (pre-commit 위임)"
  else ng "3. 린트 실패" "pre-commit run --all-files"; fi
elif [ -z "$LINT_CMD" ]; then skip "3. 린트 (린터 없음)"
elif run_quiet "$LINT_CMD"; then ok "3. 린트 통과"
else ng "3. 린트 실패" "$LINT_CMD"; fi

# ---------- 4. 문서 템플릿 필수 섹션 ----------
if is_skipped docs; then skip "4. 문서 템플릿"
elif [ ! -d "$DOCS_DIR" ]; then ng "4. $DOCS_DIR/ 없음" "킷 문서 디렉터리를 만들거나 --skip docs"
else
  DOC_BAD=0
  while IFS= read -r f; do
    case "$f" in */_templates/*) continue ;; esac
    for sec in "${DOC_REQUIRED[@]}"; do
      grep -qF "$sec" "$f" || { printf "      │ %s : '%s' 섹션 누락\n" "$f" "$sec"; DOC_BAD=1; }
    done
  done < <(find "$DOCS_DIR" -name '*.md' -type f 2>/dev/null)
  if [ "$DOC_BAD" -eq 0 ]; then ok "4. 문서 템플릿 준수"
  else ng "4. 문서 템플릿 위반" "docs/_templates 양식의 필수 섹션 누락"; fi
fi

# ---------- 5. STATUS.md 갱신 ----------
if is_skipped status; then skip "5. STATUS.md"
elif [ ! -f "$STATUS_FILE" ]; then ng "5. $STATUS_FILE 없음" "인수인계 문서가 없으면 다음 AI가 이어받을 수 없음"
else
  S_BAD=0
  for key in "${STATUS_REQUIRED[@]}"; do
    grep -qF "$key" "$STATUS_FILE" || { printf "      │ 필수 항목 누락: %s\n" "$key"; S_BAD=1; }
  done
  if git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
    if ! git log -n "$STATUS_MAX_AGE_COMMITS" --name-only --pretty=format: 2>/dev/null \
         | grep -qF "$STATUS_FILE" \
       && ! git status --porcelain 2>/dev/null | grep -qF "$STATUS_FILE"; then
      printf "      │ 최근 %s커밋 동안 %s 가 갱신되지 않음\n" "$STATUS_MAX_AGE_COMMITS" "$STATUS_FILE"; S_BAD=1
    fi
  fi
  # 5-3. 인수인계 실질 검증 — status-sync 가 자동 갱신하므로 "최신"만으로는 부족하다.
  #      사람이 써야 하는 "다음 할 일"이 비어 있으면 인수인계 실패로 본다.
  if grep -q '다음 할 일' "$STATUS_FILE"; then
    TODO_N="$(grep -cE '^[-*] \[ \] +[^[:space:]]' "$STATUS_FILE" 2>/dev/null)"; TODO_N="${TODO_N:-0}"
    if [ "$TODO_N" -eq 0 ]; then
      printf "      │ '다음 할 일'이 비어 있음 — 다음 AI가 무엇을 할지 알 수 없음\n"; S_BAD=1
    fi
  fi
  if [ "$S_BAD" -eq 0 ]; then ok "5. STATUS.md 최신 · 인수인계 내용 있음"
  else ng "5. STATUS.md 미갱신/불완전" "자동 구역이 아니라 '다음 할 일'·'차단 요인'을 사람이 채워야 함"; fi
fi

# ---------- 6. 커밋 메시지 규칙 ----------
if is_skipped commit; then skip "6. 커밋 메시지"
elif ! git rev-parse HEAD >/dev/null 2>&1; then skip "6. 커밋 메시지 (커밋 없음)"
else
  # 기준점: 기본 브랜치와의 분기점. 없으면 HEAD 1개만.
  BASE=""
  for b in main master develop; do
    if git rev-parse --verify "$b" >/dev/null 2>&1 && [ "$(git rev-parse --abbrev-ref HEAD)" != "$b" ]; then
      BASE="$(git merge-base "$b" HEAD 2>/dev/null)"; [ -n "$BASE" ] && break
    fi
  done
  if [ -n "$BASE" ]; then RANGE_ARG="${BASE}..HEAD"; SCOPE="브랜치 전체"
  else RANGE_ARG="-1"; SCOPE="최근 1건"; fi

  # commitlint 가 설정돼 있으면 위임 (자체 정규식보다 정확)
  if [ "$DELEGATE" -eq 1 ] && ls .commitlintrc* commitlint.config.* >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; then
    if [ -n "$BASE" ]; then CL="npx --no-install commitlint --from $BASE --to HEAD"
    else CL="npx --no-install commitlint --last"; fi
    if run_quiet "$CL"; then ok "6. 커밋 메시지 규칙 준수 (commitlint 위임)"
    else ng "6. 커밋 메시지 규칙 위반" "commitlint 출력 참조"; fi
  else
    BAD_MSGS="$(git log $RANGE_ARG --pretty=%s 2>/dev/null | head -20 \
                | grep -Ev "^($COMMIT_PREFIXES)(\(.+\))?: .+" || true)"
    if [ -z "$BAD_MSGS" ]; then ok "6. 커밋 메시지 규칙 준수 ($SCOPE)"
    else printf '%s\n' "$BAD_MSGS" | sed 's/^/      │ 위반: /'
         ng "6. 커밋 메시지 규칙 위반 ($SCOPE)" "형식: <타입>: <한국어 요약>  (타입: ${COMMIT_PREFIXES//|/, })"; fi
  fi
fi

# ---------- 판정 ----------
printf "%s\n" "──────────────────────────────────────────────"

# 실행 기록 (측정용) — ./gate-check.sh --stats 로 확인
mkdir -p "$(dirname "$LOG")" 2>/dev/null
printf '%s\t%s\t%s\t%s\t%d\t%d\n' "$(date '+%Y-%m-%d %H:%M')" "$GATE" \
  "$(git rev-parse --short HEAD 2>/dev/null || echo none)" \
  "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" "$PASS" "$FAIL" >> "$LOG" 2>/dev/null

if [ "$FAIL" -eq 0 ]; then
  printf "%s%s 통과%s  (성공 %d · 생략 %d)\n\n" "$B$G" "$GATE" "$N" "$PASS" "$SKIPPED"
  exit 0
else
  printf "%s%s 미통과%s  (성공 %d · 실패 %d · 생략 %d)\n" "$B$R" "$GATE" "$N" "$PASS" "$FAIL" "$SKIPPED"
  printf "\n%s조치 필요:%s\n" "$B" "$N"
  for m in "${FAIL_MSGS[@]}"; do printf "  · %s\n" "$m"; done
  cat <<EOF

── 참고: 완료의 정의(DoD) ─────────────────────
 1 빌드   2 테스트   3 린트
 4 docs/*.md 필수 섹션: 목표 / 범위 / 완료 조건
 5 STATUS.md 의 '다음 할 일'·'차단 요인'을 사람이 작성
 6 커밋 메시지: <타입>: <한국어 요약>
   타입: ${COMMIT_PREFIXES//|/, }

 게이트: G0 조사 → G1 설계 → G2 분할 → G3 구현 → G4 출시가능
 승격은 사람이 합니다:  echo G4 > .gate
──────────────────────────────────────────────

다음 게이트로 진입할 수 없습니다.

EOF
  exit 1
fi
