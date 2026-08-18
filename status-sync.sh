#!/usr/bin/env bash
# =============================================================
#  status-sync.sh  —  STATUS.md 자동 인수인계 기록기
#  git 상태를 읽어 STATUS.md 의 자동 구역만 갱신한다.
#  수동 작성 구역(다음 할 일 / 차단 요인 / 메모)은 절대 건드리지 않는다.
#
#  사용:  ./status-sync.sh            # 1회 갱신
#         ./status-sync.sh --install  # post-commit 훅으로 설치
#         ./status-sync.sh --uninstall
# =============================================================
set -uo pipefail

VERSION="2.1.0"
MARK_S="<!-- status-sync:auto:start -->"
MARK_E="<!-- status-sync:auto:end -->"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "git 저장소가 아닙니다."; exit 2; }
cd "$ROOT" || exit 2

STATUS_FILE="STATUS.md"
LOG_COUNT=5
STAGE=1          # 갱신 후 git add 여부
[ -f "gate-check.conf" ] && . ./gate-check.conf

# ---------- 인자 ----------
MODE="run"
while [ $# -gt 0 ]; do
  case "$1" in
    --install)   MODE="install"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --no-stage)  STAGE=0; shift ;;
    --version)   echo "status-sync ${VERSION}"; exit 0 ;;
    -h|--help)
      cat <<'EOF'
사용법: ./status-sync.sh [옵션]
  --install     .githooks/post-commit 설치 + core.hooksPath 설정 (저장소에 공유됨)
  --uninstall   훅 제거
  --no-stage    갱신 후 git add 하지 않음
설정: gate-check.conf 의 STATUS_FILE 을 공유합니다.
EOF
      exit 0 ;;
    *) echo "알 수 없는 옵션: $1"; exit 2 ;;
  esac
done

# 훅은 .git/hooks 가 아니라 저장소에 추적되는 .githooks/ 에 둔다.
# .git/hooks 는 git 이 추적하지 않아 클론·다른 AI 환경에서 사라진다.
HOOKDIR="$ROOT/.githooks"
HOOK="$HOOKDIR/post-commit"

if [ "$MODE" = "install" ]; then
  mkdir -p "$HOOKDIR"
  if [ -f "$ROOT/.git/hooks/post-commit" ] && grep -q "status-sync" "$ROOT/.git/hooks/post-commit" 2>/dev/null; then
    rm -f "$ROOT/.git/hooks/post-commit"
    echo "구버전 .git/hooks/post-commit 을 제거했습니다."
  fi
  cat > "$HOOK" <<'HOOKEOF'
#!/usr/bin/env bash
# status-sync post-commit hook (저장소에 커밋되어 모든 클론에서 동작)
ROOT="$(git rev-parse --show-toplevel)"
[ -x "$ROOT/status-sync.sh" ] && "$ROOT/status-sync.sh" || true
HOOKEOF
  chmod +x "$HOOK"
  git config core.hooksPath .githooks
  echo "설치 완료: .githooks/post-commit  (core.hooksPath = .githooks)"
  echo "→ .githooks/ 를 커밋하면 클론·다른 AI 환경에서도 그대로 동작합니다."
  echo "  git add .githooks && git commit -m 'chore: 훅 공유 설정'"
  exit 0
fi

if [ "$MODE" = "uninstall" ]; then
  rm -f "$HOOK"
  git config --unset core.hooksPath 2>/dev/null
  rm -f "$ROOT/.git/hooks/post-commit" 2>/dev/null
  echo "훅과 core.hooksPath 설정을 제거했습니다."
  exit 0
fi

# ---------- 담당 AI 감지 ----------
detect_agent() {
  if [ -n "${AI_AGENT:-}" ]; then echo "$AI_AGENT"; return; fi
  if [ -n "${CLAUDECODE:-}${CLAUDE_CODE:-}" ]; then echo "Claude Code"; return; fi
  if [ -n "${CURSOR_TRACE_ID:-}" ] || [ "${TERM_PROGRAM:-}" = "cursor" ]; then echo "Cursor"; return; fi
  if [ -n "${GEMINI_CLI:-}" ]; then echo "Gemini CLI"; return; fi
  if [ -n "${CODEX_SANDBOX:-}${OPENAI_CODEX:-}" ]; then echo "Codex"; return; fi
  local n; n="$(git config user.name 2>/dev/null)"
  echo "${n:-사람}"
}

# ---------- 현재 게이트 판정 ----------
detect_gate() {
  # .gate 가 있으면 전체 게이트 모드, 없으면 패스트트랙이 기본
  if [ -f ".gate" ]; then tr -d ' \n' < .gate; return; fi
  echo "패스트트랙"
}

AGENT="$(detect_agent)"
GATE="$(detect_gate)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
NOW="$(date '+%Y-%m-%d %H:%M')"

if git rev-parse HEAD >/dev/null 2>&1; then
  LAST_SUBJ="$(git log -1 --pretty=%s)"
  LAST_HASH="$(git log -1 --pretty=%h)"
  LAST_WHEN="$(git log -1 --pretty=%ad --date=format:'%Y-%m-%d %H:%M')"
  CHANGED="$(git show --name-only --pretty=format: HEAD | sed '/^$/d' | head -12)"
  CHANGED_N="$(git show --name-only --pretty=format: HEAD | sed '/^$/d' | wc -l | tr -d ' ')"
  RECENT="$(git log -n "$LOG_COUNT" --pretty='- `%h` %s _(%ad)_' --date=format:'%m-%d %H:%M')"
else
  LAST_SUBJ="(커밋 없음)"; LAST_HASH="-"; LAST_WHEN="-"; CHANGED=""; CHANGED_N=0; RECENT="- (없음)"
fi

DIRTY="$(git status --porcelain | grep -v "$STATUS_FILE" | wc -l | tr -d ' ')"

# 마지막 게이트 검증 결과 (핸드오프 최소 필드 중 '런타임 상태')
# 다음 AI가 "빌드가 깨진 상태로 넘겨받았는지"를 즉시 알 수 있어야 한다.
GLOG=".kit/gate-log.tsv"
if [ -f "$GLOG" ]; then
  GL="$(tail -1 "$GLOG")"
  G_WHEN="$(printf '%s' "$GL" | cut -f1)"
  G_COMMIT="$(printf '%s' "$GL" | cut -f3)"
  G_RES="$(printf '%s' "$GL" | cut -f4)"
  if [ "$G_RES" = "PASS" ]; then VERIFY="✅ 통과 · $G_WHEN"; else VERIFY="❌ 실패 · $G_WHEN"; fi
  [ -n "$G_COMMIT" ] && [ "$G_COMMIT" != "$(git rev-parse --short HEAD 2>/dev/null)" ] \
    && VERIFY="$VERIFY (이후 커밋 있음 — 재검증 필요)"
else
  VERIFY="미실행 — \`./gate-check.sh\` 를 돌리세요"
fi

# ---------- 자동 구역 본문 ----------
AUTO="$(cat <<EOF
$MARK_S
<!-- 이 구역은 status-sync.sh 가 자동 생성합니다. 직접 수정하지 마세요. -->

## 자동 기록 (갱신: $NOW)

| 항목 | 값 |
| --- | --- |
| 현재 게이트 | **$GATE** |
| 담당 AI | $AGENT |
| 브랜치 | \`$BRANCH\` |
| 마지막 작업 | $LAST_SUBJ |
| 커밋 | \`$LAST_HASH\` · $LAST_WHEN |
| 마지막 검증 | $VERIFY |
| 변경 파일 | ${CHANGED_N}개 |
| 미커밋 변경 | ${DIRTY}개 |

### 마지막 커밋에서 변경된 파일
$( [ -n "$CHANGED" ] && printf '%s\n' "$CHANGED" | sed 's/^/- `/; s/$/`/' || echo "- (없음)" )

### 최근 커밋
$RECENT

$MARK_E
EOF
)"

# ---------- STATUS.md 작성 ----------
TEMPLATE_MANUAL="$(cat <<'EOF'

---

## 수동 기록 (다음 AI에게 넘기는 내용)

### 다음 할 일
- [ ] 

### 차단 요인
- 없음

### 인수인계 메모
- 
EOF
)"

if [ ! -f "$STATUS_FILE" ]; then
  { echo "# STATUS — 인수인계 문서"; echo; echo "$AUTO"; echo "$TEMPLATE_MANUAL"; } > "$STATUS_FILE"
  echo "생성: $STATUS_FILE"
elif grep -qF "$MARK_S" "$STATUS_FILE" && grep -qF "$MARK_E" "$STATUS_FILE"; then
  TMP="$(mktemp)"
  awk -v s="$MARK_S" -v e="$MARK_E" '
    index($0,s){print "___AUTO_BLOCK___"; skip=1; next}
    index($0,e){skip=0; next}
    !skip{print}
  ' "$STATUS_FILE" > "$TMP"
  # 원자적 쓰기: 임시 파일에 완성한 뒤 교체한다.
  # 직접 덮어쓰면 쓰는 도중 실패했을 때 인수인계 문서가 통째로 날아간다.
  TMP2="$(mktemp)"
  if awk -v auto="$AUTO" '{ if ($0=="___AUTO_BLOCK___") print auto; else print }' "$TMP" > "$TMP2" \
     && [ -s "$TMP2" ]; then
    mv "$TMP2" "$STATUS_FILE"
  else
    rm -f "$TMP2"; echo "경고: STATUS.md 갱신 실패 — 기존 파일을 유지합니다." >&2
  fi
  rm -f "$TMP"
else
  # 마커 없는 기존 파일 → 자동 구역을 맨 앞에 삽입, 본문은 그대로 보존
  TMP="$(mktemp)"
  { echo "$AUTO"; echo; cat "$STATUS_FILE"; } > "$TMP"
  mv "$TMP" "$STATUS_FILE"
  echo "기존 $STATUS_FILE 에 자동 구역을 삽입했습니다."
fi

[ "$STAGE" -eq 1 ] && git add "$STATUS_FILE" 2>/dev/null

# ---------- 경고 ----------
if grep -qE '^\- \[ \] *$' "$STATUS_FILE"; then
  printf '\e[33m⚠ STATUS.md 의 "다음 할 일"이 비어 있습니다. 작업을 종료하기 전에 채워주세요.\e[0m\n'
fi

echo "STATUS.md 갱신됨 · 게이트 $GATE · 담당 $AGENT"
