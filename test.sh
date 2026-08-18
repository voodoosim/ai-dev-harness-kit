#!/usr/bin/env bash
# 킷 자동 테스트 — 엣지 케이스 검증
KIT="$(cd "$(dirname "$0")" && pwd)"
LAB="${TMPDIR:-/tmp}/kitlab"
PASS=0; FAIL=0; FAILED=()

t() { # t "이름" "명령" "기대exit"
  local name="$1" cmd="$2" want="${3:-0}" out rc
  out="$(eval "$cmd" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then PASS=$((PASS+1)); printf "  ✓ %s\n" "$name"
  else FAIL=$((FAIL+1)); FAILED+=("$name (exit=$rc, 기대=$want)"); printf "  ✗ %s (exit=%s 기대=%s)\n" "$name" "$rc" "$want"
       printf '%s\n' "$out" | tail -4 | sed 's/^/      /'; fi
}
tgrep() { # tgrep "이름" "파일" "패턴"  — 존재해야 통과
  if grep -qE "$3" "$2" 2>/dev/null; then PASS=$((PASS+1)); printf "  ✓ %s\n" "$1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); printf "  ✗ %s (패턴 없음: %s)\n" "$1" "$3"; fi
}
newrepo() { rm -rf "$LAB/$1"; mkdir -p "$LAB/$1"; cd "$LAB/$1"; git init -q .; git config user.email a@b; git config user.name t; }
gc() { git add -A >/dev/null 2>&1; git commit -qm "$1" >/dev/null 2>&1; }

rm -rf "$LAB"; mkdir -p "$LAB"

echo; echo "▶ 1. 설치 · 멱등성"
newrepo r1
t "빈 저장소 설치" "$KIT/kit-init.sh"
t "재설치(멱등)" "$KIT/kit-init.sh"
tgrep "AGENTS.md 존재" AGENTS.md "필수"
t ".gitignore 중복 없음" "[ \$(grep -c '^\.kit/\$' .gitignore) -eq 1 ]"
t "심볼릭 링크 유효" "[ -L .cursorrules ] && [ \"\$(readlink .cursorrules)\" = AGENTS.md ]"
t "점검 모드" "$KIT/kit-init.sh --check"
t "업데이트 모드" "$KIT/kit-init.sh --update"

echo; echo "▶ 2. 커밋 없는 저장소 · git 아닌 곳"
newrepo r2
t "커밋 0개에서 gate-check" "cp $KIT/gate-check.sh . && ./gate-check.sh" 1
mkdir -p "$LAB/nogit" && cd "$LAB/nogit" && cp $KIT/status-sync.sh .
t "git 아닌 곳 status-sync (exit 2)" "./status-sync.sh" 2
cp $KIT/kit-init.sh .
t "git 아닌 곳 kit-init (exit 2)" "./kit-init.sh" 2

echo; echo "▶ 3. 인수인계 보존"
newrepo r3
$KIT/kit-init.sh >/dev/null 2>&1
python3 -c "
p='STATUS.md';s=open(p).read()
s=s.replace('- [ ] ','- [ ] 결제 연동')
s=s.replace('### 인수인계 메모\n- ','### 인수인계 메모\n- 중요: DB 마이그레이션 롤백 불가')
open(p,'w').write(s)"
gc "feat: 최초"
for i in 1 2 3; do ./status-sync.sh >/dev/null 2>&1; done
tgrep "수동 메모 3회 동기화 후 보존" STATUS.md "롤백 불가"
t "자동 구역 마커 정확히 1쌍" "[ \$(grep -c 'status-sync:auto:start' STATUS.md) -eq 1 ]"
python3 -c "
p='STATUS.md';s=open(p).read();open(p,'w').write(s.replace('<!-- status-sync:auto:start -->','').replace('<!-- status-sync:auto:end -->',''))"
./status-sync.sh >/dev/null 2>&1
tgrep "마커 삭제돼도 내용 보존" STATUS.md "롤백 불가"

echo; echo "▶ 4. 게이트 모드"
newrepo r4
echo '{"name":"a","scripts":{"test":"echo ok"}}' > package.json
$KIT/kit-init.sh >/dev/null 2>&1
python3 -c "p='STATUS.md';s=open(p).read();open(p,'w').write(s.replace('- [ ] ','- [ ] 할일'))"
gc "feat: 초기"
t "패스트트랙 통과" "./gate-check.sh"
echo "G3" > .gate
printf '## 목표\n가\n' > docs/불완전.md
gc "docs: 불완전 문서"
t "전체 게이트에서 문서 미비 탐지" "./gate-check.sh" 1
printf '## 목표\n가\n## 범위\n나\n## 완료 조건\n다\n' > docs/불완전.md
gc "docs: 문서 보완"
t "문서 보완 후 통과" "./gate-check.sh"

echo; echo "▶ 5. 테스트 실패 · 위반 커밋"
newrepo r5
echo '{"name":"b","scripts":{"test":"exit 1"}}' > package.json
$KIT/kit-init.sh >/dev/null 2>&1
python3 -c "p='STATUS.md';s=open(p).read();open(p,'w').write(s.replace('- [ ] ','- [ ] 할일'))"
gc "feat: 초기"
t "테스트 실패 감지" "./gate-check.sh" 1
t "--skip test 로 우회" "./gate-check.sh --skip test"
gc "잘못된 메시지"
t "커밋 규칙 위반 감지" "./gate-check.sh --skip test" 1

echo; echo "▶ 6. 클론 · 자가복구 · 분리 HEAD"
cd "$LAB" && rm -rf r6c && git clone -q r4 r6c && cd r6c
t "클론 직후 core.hooksPath 없음" "[ -z \"\$(git config core.hooksPath)\" ]"
./gate-check.sh >/dev/null 2>&1
t "gate-check 실행 후 자가복구" "[ \"\$(git config core.hooksPath)\" = .githooks ]"
git checkout -q HEAD~1 2>/dev/null
t "분리 HEAD 에서 status-sync 동작" "./status-sync.sh"
git checkout -q - 2>/dev/null

echo; echo "▶ 7. 공백·한글 경로"
rm -rf "$LAB/한글 프로젝트"; mkdir -p "$LAB/한글 프로젝트"; cd "$LAB/한글 프로젝트"
git init -q .; git config user.email a@b; git config user.name t
echo '{"name":"k","scripts":{"test":"echo ok"}}' > package.json
t "공백+한글 경로 설치" "$KIT/kit-init.sh"
python3 -c "p='STATUS.md';s=open(p).read();open(p,'w').write(s.replace('- [ ] ','- [ ] 할일'))"
gc "feat: 초기"
t "공백 경로 gate-check" "./gate-check.sh"

echo; echo "▶ 7-b. 회귀 테스트"
newrepo r7b
$KIT/kit-init.sh >/dev/null 2>&1
python3 -c "p='STATUS.md';s=open(p).read();open(p,'w').write(s.replace('- [ ] ','- [ ] 할일'))"
gc "feat: 초기"
t "패스트트랙: 테스트 없어도 통과(경고)" "./gate-check.sh"
echo "G3" > .gate
t "전체 게이트: 테스트 없으면 실패" "./gate-check.sh" 1
rm -f .gate
# 원자적 쓰기: 쓰기 불가 상황에서도 기존 파일 보존
python3 -c "p='STATUS.md';s=open(p).read();open(p,'w').write(s.replace('- [ ] 할일','- [ ] 절대사라지면안됨'))"
chmod 500 . 2>/dev/null; ./status-sync.sh >/dev/null 2>&1; chmod 700 . 2>/dev/null
tgrep "쓰기 실패해도 내용 보존" STATUS.md "절대사라지면안됨"

echo; echo "▶ 8. 관제탑"
cd "$LAB"
t "빈 스캔 경로 (exit 2)" "$KIT/dashboard-roll.sh --scan $LAB/없는경로 --out $LAB/d.md" 2
t "정상 스캔" "$KIT/dashboard-roll.sh --scan $LAB --out $LAB/DASH.md" 1
tgrep "표 생성" "$LAB/DASH.md" '^\| '
tgrep "STATUS 없는 프로젝트 탐지" "$LAB/DASH.md" 'STATUS.md 없음'
t "--deep 실행" "$KIT/dashboard-roll.sh --scan $LAB --out $LAB/DASH2.md --deep" 1

echo; echo "▶ 9. 측정 지표"
cd "$LAB/r4"
t "--stats 출력" "./gate-check.sh --stats"
tgrep "통과율 계산" <(./gate-check.sh --stats) '첫 시도'
cd "$LAB/r2"
t "기록 없을 때 --stats" "cp $KIT/gate-check.sh . && ./gate-check.sh --stats"

echo; echo "▶ 10. 훅 재진입 · 중복 실행"
cd "$LAB/r4"
for i in 1 2 3; do echo "x$i" > f$i.txt; gc "chore: 반복 $i"; done
t "연속 커밋 3회 정상" "[ \$(git log --oneline | wc -l) -ge 4 ]"
t "자동 구역 여전히 1쌍" "[ \$(grep -c 'status-sync:auto:start' STATUS.md) -eq 1 ]"

echo
echo "══════════════════════════════════════"
printf "결과: 통과 %d · 실패 %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf "\n실패 목록:\n"; for f in "${FAILED[@]}"; do echo "  · $f"; done; exit 1; fi
