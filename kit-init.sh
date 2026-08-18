#!/usr/bin/env bash
# =============================================================
#  kit-init.sh  —  하네스 킷 배포기
#  새 프로젝트에 킷 전체를 한 번에 설치한다.
#  스크립트 · 훅 · 템플릿 · AGENTS.md 심볼릭 링크까지.
#
#  사용:  /경로/kit/kit-init.sh            # 현재 디렉터리에 설치
#         /경로/kit/kit-init.sh --check    # 설치 상태만 점검
#         /경로/kit/kit-init.sh --update   # 스크립트만 최신본으로 교체
# =============================================================
set -uo pipefail

KIT_VERSION="2.1.0"
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$(pwd)"
MODE="install"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check)  MODE="check"; shift ;;
    --update) MODE="update"; shift ;;
    --force)  FORCE=1; shift ;;
    --to)     DST="${2:-.}"; shift 2 ;;
    --version) echo "kit-init ${KIT_VERSION}"; exit 0 ;;
    -h|--help)
      cat <<'EOF'
사용법: kit-init.sh [옵션]
  (기본)      현재 디렉터리에 킷 전체 설치
  --update    스크립트 3종만 최신본으로 교체 (설정·문서는 보존)
  --check     설치 상태 점검 후 종료
  --to 경로   대상 디렉터리 지정
  --force     기존 파일 덮어쓰기
EOF
      exit 0 ;;
    *) echo "알 수 없는 옵션: $1"; exit 2 ;;
  esac
done

cd "$DST" || exit 2
DST="$(pwd)"
SCRIPTS=(gate-check.sh status-sync.sh dashboard-roll.sh)

if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'
else G=""; Y=""; R=""; B=""; N=""; fi
ok(){ printf "  %s✓%s %s\n" "$G" "$N" "$1"; }
sk(){ printf "  %s-%s %s\n" "$Y" "$N" "$1"; }
er(){ printf "  %s✗%s %s\n" "$R" "$N" "$1"; }

# ---------- 점검 모드 ----------
if [ "$MODE" = "check" ]; then
  printf "\n%s킷 설치 점검%s · %s\n──────────────────────────────\n" "$B" "$N" "$(basename "$DST")"
  for f in "${SCRIPTS[@]}"; do [ -x "$f" ] && ok "$f" || er "$f 없음"; done
  [ -f AGENTS.md ] && ok "AGENTS.md" || er "AGENTS.md 없음"
  [ -L CLAUDE.md ] || [ -f CLAUDE.md ] && ok "CLAUDE.md" || er "CLAUDE.md 없음"
  [ -f STATUS.md ] && ok "STATUS.md" || er "STATUS.md 없음"
  [ -d docs/_templates ] && ok "docs/_templates" || er "docs/_templates 없음"
  [ -f .githooks/post-commit ] && ok ".githooks/post-commit" || er "훅 없음"
  HP="$(git config core.hooksPath 2>/dev/null)"
  [ "$HP" = ".githooks" ] && ok "core.hooksPath=.githooks" || er "core.hooksPath 미설정 (현재: ${HP:-없음})"
  [ -f .kit-version ] && ok "킷 버전 $(cat .kit-version)" || sk ".kit-version 없음"
  echo
  exit 0
fi

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "git 저장소가 아닙니다. git init 후 다시 실행하세요."; exit 2; }

printf "\n%s킷 설치%s v%s → %s\n──────────────────────────────\n" "$B" "$N" "$KIT_VERSION" "$(basename "$DST")"

# ---------- 1. 스크립트 ----------
for f in "${SCRIPTS[@]}"; do
  if [ ! -f "$SRC/$f" ]; then er "$f (원본 없음: $SRC)"; continue; fi
  cp "$SRC/$f" "$DST/$f" && chmod +x "$DST/$f" && ok "$f"
done
echo "$KIT_VERSION" > .kit-version

if [ "$MODE" = "update" ]; then
  printf "\n스크립트를 v%s 로 교체했습니다. 설정·문서는 그대로입니다.\n\n" "$KIT_VERSION"
  exit 0
fi

# ---------- 2. AGENTS.md (단일 원본) ----------
if [ -f AGENTS.md ] && [ "$FORCE" -eq 0 ]; then sk "AGENTS.md (기존 유지)"
else
  cat > AGENTS.md <<'EOF'
# 프로젝트 규칙

> 모든 AI 도구의 단일 원본. CLAUDE.md / .cursorrules / GEMINI.md 는 이 파일을 가리킵니다.
> **짧게 유지하세요.** 이 파일은 매 작업마다 컨텍스트에 로드되며, 길수록 작업당 비용이 오르고
> 현재 작업과 무관한 제약까지 에이전트가 성실히 처리하려 듭니다.
> 절차 규칙은 여기 쓰지 말고 `./gate-check.sh` 가 실패할 때 출력하게 하세요.

## 필수
- 모든 문서·보고·커밋 메시지는 한국어로 작성한다.
- 작업 종료 전 `./gate-check.sh` 를 실행하고 **exit 0** 을 확인한다. 실패 시 완료로 보고하지 않는다.
- STATUS.md 의 "다음 할 일"과 "차단 요인"은 사람이 직접 쓴다. 자동 구역은 수정하지 않는다.
- 비밀키·`.env` 는 커밋하지 않는다.

## 이 프로젝트 고유 규칙
<!-- 코드를 읽어서는 알 수 없는 것만 적으세요. 파일 경로 나열은 금물 — 금방 낡습니다.
     예: 배포 절차, 마이그레이션 규칙, 도메인 용어 정의, 건드리면 안 되는 영역 -->
- (여기에 추가)
EOF
  ok "AGENTS.md (최소 규칙 — 15줄)"
fi

# ---------- 3. AI별 설정 파일 연결 ----------
link_to_agents() { # $1 = 대상 파일
  if [ -L "$1" ]; then sk "$1 (링크 유지)"
  elif [ -f "$1" ] && [ "$FORCE" -eq 0 ]; then sk "$1 (기존 파일 유지 — 수동 확인 필요)"
  else ln -sf AGENTS.md "$1" && ok "$1 → AGENTS.md"; fi
}
# Claude Code 는 AGENTS.md 자동 로드가 아직 없어 @import 로 연결한다
if [ -f CLAUDE.md ] && grep -q "@AGENTS.md" CLAUDE.md 2>/dev/null; then sk "CLAUDE.md (import 유지)"
elif [ -f CLAUDE.md ] && [ "$FORCE" -eq 0 ]; then sk "CLAUDE.md (기존 파일 유지)"
else printf '@AGENTS.md\n' > CLAUDE.md && ok "CLAUDE.md (@AGENTS.md import)"; fi
link_to_agents ".cursorrules"
link_to_agents "GEMINI.md"

# ---------- 4. 문서 템플릿 ----------
mkdir -p docs/_templates
if [ -f docs/_templates/기본.md ] && [ "$FORCE" -eq 0 ]; then sk "docs/_templates (기존 유지)"
else
  cat > docs/_templates/기본.md <<'EOF'
# (제목)

## 목표
- 무엇을 왜 하는가

## 범위
- 포함:
- 제외:

## 완료 조건
- [ ] 
EOF
  ok "docs/_templates/기본.md"
fi

# ---------- 5. 설정 파일 ----------
if [ -f gate-check.conf ]; then sk "gate-check.conf (기존 유지)"
elif [ -f "$SRC/gate-check.conf.example" ]; then cp "$SRC/gate-check.conf.example" gate-check.conf && ok "gate-check.conf"
fi
# .gate 는 만들지 않습니다 — 없으면 패스트트랙(가벼운 검사)이 기본.
# 전체 게이트(G0~G4)를 적용할 프로젝트에서만:  echo G0 > .gate
[ -f .gate ] && ok ".gate ($(cat .gate))" || sk ".gate 없음 → 패스트트랙 모드"

# ---------- 6. 훅 설치 ----------
if [ -x ./status-sync.sh ]; then
  ./status-sync.sh --install >/dev/null 2>&1 && ok ".githooks/post-commit + core.hooksPath"
fi

# ---------- 7. STATUS.md 초기화 ----------
if [ -f STATUS.md ]; then sk "STATUS.md (기존 유지)"
elif [ -x ./status-sync.sh ]; then ./status-sync.sh --no-stage >/dev/null 2>&1 && ok "STATUS.md 생성"
fi

# ---------- 8. .gitignore ----------
grep -q '^\.kit/$' .gitignore 2>/dev/null || printf '\n# 킷\n.env\n.kit/\n' >> .gitignore

printf "\n%s설치 완료%s\n\n다음 단계:\n" "$B$G" "$N"
echo "  1. git add .githooks AGENTS.md CLAUDE.md .cursorrules GEMINI.md docs STATUS.md .gitignore"
echo "     git commit -m 'chore: 하네스 킷 도입'"
echo "  2. AGENTS.md 를 프로젝트에 맞게 수정"
echo "  3. ./gate-check.sh 로 현재 상태 확인"
echo
echo "  기본은 패스트트랙(빌드·테스트·린트·인수인계·커밋 검사)입니다."
echo "  전체 게이트가 필요한 프로젝트에서만:  echo G0 > .gate"
echo "  효과 측정:  ./gate-check.sh --stats"
echo
