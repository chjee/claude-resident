# Telegram ↔ Claude Code ↔ OMX 연동

> OpenClaw ACP를 걷어내고, Claude Code Channels를 통해 텔레그램에서 직접 Claude와 통신하고  
> 필요시 OMX(오마이코덱스)와 연계하는 구조

---

## 0. 왜 필요한가

Claude Code를 "장기 세션 + 원격 채팅 인터페이스"로 운영하려는 사람들이 공통으로 부딪히는 문제가 있다.

**공통 pain point (Claude Code GitHub 이슈 기준):**
- 세션이 끊기면 컨텍스트가 완전히 유실됨
- `--resume`이 기대만큼 맥락을 복원하지 못함
- 장기 작업에서 메모리/맥락 유지가 어려움
- 결국 로컬 메모리 파일, 세션 복원 레이어를 직접 만드는 workaround가 필요해짐

관련 이슈: [#7584](https://github.com/anthropics/claude-code/issues/7584) · [#12646](https://github.com/anthropics/claude-code/issues/12646) · [#2954](https://github.com/anthropics/claude-code/issues/2954) · [#3138](https://github.com/anthropics/claude-code/issues/3138)

**이 설계가 메우는 것:**
- Channels로 텔레그램 입구 구성 (메시지 수신/발신)
- `CLAUDE.md` + `memory/*`로 세션 복원 규칙 보강 (컨텍스트 유실 대응)
- 실행은 omx-bridge로 분리 (Claude 세션 부하 최소화)

---

## 0-1. 유사 레포 대비 차별점

텔레그램 ↔ Claude 연동을 시도한 공개 레포는 이미 여럿 있다.

| 레포 | 방식 | 한계 |
|------|------|------|
| [RichardAtCT/claude-code-telegram](https://github.com/RichardAtCT/claude-code-telegram) | claude CLI를 subprocess로 실행, 메시지 파이핑 | 세션 복원 없음, 메모리 관리 없음 |
| [coleam00/remote-agentic-coding-system](https://github.com/coleam00/remote-agentic-coding-system) | 원격 에이전트 실행 중심 | 대화형 인터페이스 약함 |
| [JessyTsui/Claude-Code-Remote](https://github.com/JessyTsui/Claude-Code-Remote) | 원격 제어 레이어 | 메모리/캐릭터 유지 없음 |
| [Nickqiaoo/chatcode](https://github.com/Nickqiaoo/chatcode) | 채팅 → 코드 실행 연동 | 단발성, 세션 연속성 없음 |

**이 설계의 차별점:**

1. **공식 Channels 플러그인 사용** — subprocess 해킹 없이 Anthropic 공식 MCP 방식
2. **세션 복원 프로토콜** — `CLAUDE.md` Startup Sequence + `memory/` 파일로 재시작 후에도 맥락 복원
3. **캐릭터/페르소나 유지** — `soul.md`로 Andy 정체성을 세션과 무관하게 보존
4. **실행 분리** — Claude는 판단만, 코딩 실행은 omx-bridge → OMX로 위임 (컨텍스트 오염 방지)
5. **다중 인스턴스 지원** — `claude-resident@andy`, `claude-resident@john` 등 systemd 템플릿 유닛으로 인스턴스별 독립 운영
6. **XDG 디렉토리 준수** — config(`~/.config/`) / state·memory·log(`~/.local/state/`) 분리로 백업·배포 용이

---

## 1. 배경

### 현재 구조 (OpenClaw ACP)

```
텔레그램 메시지
    ↓
OpenClaw ACP
    ↓
Claude API (토큰 과금) ← 비용 발생
    ↓ (필요시)
omx-bridge → OMX 실행
    ↓
텔레그램 결과 전송
```

**문제:** OpenClaw ACP가 Claude API를 토큰 과금 방식으로 호출 → 사용량에 따라 비용 발생

### 목표 구조 (Claude Code Channels)

```
텔레그램 메시지
    ↓
Claude Code Channels (Telegram MCP Plugin)
    ↓
로컬 Claude Code 세션 (구독 기반, 추가 API 과금 없음)
    ↓ (필요시)
omx-bridge POST /jobs
    ↓
omx exec --full-auto → TelegramNotifyService → 텔레그램 결과
```

**핵심:** Claude.ai 구독(Pro/Max) 안에서 동작 → 별도 API 토큰 과금 없음

---

## 2. Claude Code Channels 현황 (2026-04-13 기준)

| 항목 | 내용 |
|------|------|
| 상태 | **Research Preview** (정식 출시 아님, API 변경 가능) |
| 인증 | claude.ai 로그인 필수 (API 키 불가) |
| 비용 | 별도 API 과금 없음, 구독 한도 내 동작 |
| 지원 플랫폼 | Telegram, Discord, iMessage(macOS 전용), fakechat(데모) |
| 필수 조건 | Bun, Claude Code v2.1.80+ |
| 세션 | **살아있어야 이벤트 수신 가능** → 영속화 필수 |

---

## 3. 핵심 과제: 세션/메모리 관리

Claude Code Channels는 세션이 살아있는 동안만 동작한다.  
WSL2 재시작, 세션 종료 시 **컨텍스트가 완전히 사라진다.**

OpenClaw는 이를 명시적 Session Startup Sequence로 해결했다:

```
/new 또는 /reset 트리거
    ↓
SOUL.md + USER.md + memory/*.md 읽기
    ↓
Andy 페르소나로 인사
```

Claude Code에서 이 흐름을 재현하는 것이 핵심 설계 과제다.

---

## 4. 세션 복원 메커니즘

```
WSL2 시작 or 수동 실행
    ↓
claude-resident andy start
    ├── tmux 세션 `claude-resident-andy` 생성
    ├── claude --channels plugin:telegram@claude-plugins-official 실행
    └── 5초 후 __STARTUP__ 전송 (Telegram Bot API 직접 호출)
         ↓
         CLAUDE.md의 Session Startup Sequence 실행
         ↓
         soul.md → user.md → recent.md 읽기
         (필요 시 workflow.md / projects.md 추가)
         ↓
         텔레그램: "🟢 앤디 온라인 · [날짜/시간] · [한 줄 상태]"
```

### CLAUDE.md 핵심 구조

```markdown
# Session Startup Sequence
첫 메시지 수신 또는 __STARTUP__ 트리거 시:
1. soul.md → user.md → recent.md 순서로 읽기
2. 필요 시 workflow.md / projects.md 추가 로드
3. 텔레그램: "🟢 앤디 온라인 · [날짜/시간] · [한 줄 요약]"
→ 파일 읽기 전까지 어떤 질문에도 답하지 않는다.

# Who You Are (Andy)
[soul.md 핵심 내용 인라인 — 파일 읽기 전 fallback용]

# OMX 호출 지침
코딩/개발 작업은 omx-bridge에 위임:
  curl -s -X POST http://localhost:3992/jobs \
    -H "Content-Type: application/json" \
    -d '{"prompt": "...", "cwd": "..."}'
omx-bridge 장애 시: "⚠️ omx-bridge 응답 없음" 전송 후 보류.

# 메모리 저장 규칙
대화 종료 / OMX 작업 완료 / 중요한 결정 시 recent.md 업데이트.
recent.md는 50줄 이내로 유지.
```

운영 원칙:
- 텔레그램 응답은 짧고 명확하게 (모바일 기준)
- 코딩/수정/테스트/대량 편집 → OMX 위임
- 질문/설계/검토/간단한 확인 → Claude 직접 처리
- 응답 접두어: `[앤디]` (Claude), `✅/❌ omx job` (omx-bridge) — 발신자 구분

---

## 5. Memory 파일 구조

```
~/.config/claude-resident/<name>/   ← 인스턴스 홈 (설정·메모리·로그 모두)
    ├── CLAUDE.md                   ← 항상 로드, Startup Sequence 포함
    ├── agent.log                   ← 실행 로그
    └── memory/
        ├── soul.md       ← 캐릭터/페르소나 (변경 거의 없음)
        ├── user.md       ← 사용자 정보 (가끔 업데이트)
        ├── workflow.md   ← 역할 분담 + omx-bridge 호출법 (변경 거의 없음)
        ├── projects.md   ← 진행 중/완료 프로젝트 현황 (프로젝트 변경 시)
        └── recent.md     ← 최근 맥락 롤링 요약 50줄 이내 (세션마다 업데이트)
```

> 인스턴스 하나 = 디렉토리 하나. 새 머신 설치 또는 마이그레이션 시 통째로 복사:
> ```bash
> rsync -av ~/.config/claude-resident/andy/ new-machine:~/.config/claude-resident/andy/
> ```

**recent.md 업데이트 트리거:**

| 트리거 | 예시 |
|--------|------|
| 대화 종료 신호 | "잘자", "내일봐", "수고", "bye", "끊을게" |
| OMX 작업 완료 | 작업 결과 알림 수신 후 |
| 중요한 결정 | 아키텍처 결정, 방향 전환, 새 프로젝트 시작 |

**recent.md 크기 관리:**
- 항목당 최대 5줄, 전체 50줄 이내
- 초과 시 오래된 항목을 `projects.md`로 이동 후 삭제
- 완료 + 한 달 이상 지난 항목은 삭제

---

## 6. 세션 영속화

### claude-resident 스크립트

`<name> [start|stop|restart|status|shutdown]` 형식으로 인스턴스별 관리. 전체 코드: `drafts/claude-resident`

```
claude-resident andy start 동작:
1. 기존 tmux 세션(claude-resident-andy) 존재 여부 확인
2. omx-bridge/.env 에서 TELEGRAM_BOT_TOKEN, TELEGRAM_NOTIFY_CHAT_ID 로드
3. tmux 세션에서 claude --channels ... 실행
   (로그: ~/.local/state/claude-resident/andy/agent.log)
4. 백그라운드에서 5초 후 __STARTUP__ 메시지를 Telegram Bot API로 전송
```

### systemd 자동 시작

```bash
# 설치
cp drafts/claude-resident ~/.local/bin/claude-resident
chmod +x ~/.local/bin/claude-resident
ln -s ~/.local/bin/claude-resident ~/.local/bin/cr   # 별칭

cp drafts/claude-resident@.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now claude-resident@andy.service
```

### WSL2 수동 시작 (systemd 없이)

```bash
# ~/.bashrc 에 추가
if [ -z "$TMUX" ] && [ "$TERM_PROGRAM" != "vscode" ]; then
  claude-resident andy start
fi
```

---

## 7. 미해결 문제

### 컨텍스트 관리 (Compaction)

OpenClaw는 `contextPruning TTL: 30m`, `historyLimit: 20`으로 명시적 제어했지만  
Claude Code는 자동 압축만 있고 직접 제어 불가.

**3단 대응 전략:**

| 레이어 | 방법 | 역할 |
|--------|------|------|
| 기본 | `andy-restart.timer` 매일 새벽 6시 | compaction 자체 예방 |
| 운영 | 이벤트마다 `recent.md` 갱신 | 재시작 후 복원 품질 보장 |
| 예외 | Claude 자가 경고 → 수동 재시작 | 예상치 못한 급증 대응 |

**중요:** `andy-restart.timer`는 compaction 예방용이고,  
`recent.md`는 복원 품질 보장용이다. 자동 종료 저장(`__SHUTDOWN__`)은  
best-effort이므로 두 가지 모두 운영해야 효과가 있다.

배포:
```bash
cp drafts/claude-resident-restart@.timer ~/.config/systemd/user/
cp drafts/claude-resident-restart@.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable claude-resident-restart@andy.timer
```

### __STARTUP__ 트리거 방식

**임시안 (현재 설계):** `start-andy.sh`가 Telegram Bot API로 직접 전송
- 장점: 별도 컴포넌트 불필요, 구현 즉시 가능
- 한계: polling 시작 전 도착 시 유실 가능, 운영/시스템 신호가 사용자 채팅과 같은 채널에 섞임

**운영안 (향후 개선):** 아래 중 하나로 승격
- 세션 내부 명령 (`/clear` 후 CLAUDE.md 재로드 유도)
- 별도 control chat 구성 (관리용 텔레그램 채팅 분리)
- 재시도 로직 추가 (전송 후 30초 내 온라인 알림 없으면 재전송)

→ PoC는 임시안으로 시작, 안정화 후 운영안으로 전환.

### omx-bridge 장애 시

```
curl POST /jobs 실패
    ↓
앤디: "⚠️ omx-bridge 응답 없음. 수동 확인 필요"
    ↓
사용자: systemctl --user restart omx-bridge.service
    ↓
재요청
```

### Permission Relay

초기: Permission Relay (텔레그램에서 `yes/no <id>` 로 원격 승인)  
불편하면: `--dangerously-skip-permissions` 전환 (신뢰 환경 전용)

---

## 8. OpenClaw vs Claude Code Channels

| 항목 | OpenClaw ACP | Claude Code Channels |
|------|-------------|---------------------|
| 비용 | API 토큰 과금 | 구독 한도 내 (추가 없음) |
| 인증 | API 키 | claude.ai 로그인 |
| 세션 관리 | 자동 | tmux + claude-resident |
| 세션 복원 | /new·/reset 트리거 | __STARTUP__ 트리거 |
| 메모리 | SOUL/USER/memory 자동 | CLAUDE.md + memory/ 수동 |
| 컨텍스트 제어 | TTL + historyLimit | 제어 불가 (자동 압축) |
| OMX 연계 | omx-bridge plugin | omx-bridge HTTP 호출 |
| 안정성 | 안정 | Research Preview |
| 캐릭터 | Andy | Andy (이전 가능) |

---

## 9. 구현 체크리스트

### Phase 1: 준비
- [ ] Bun 설치 (`curl -fsSL https://bun.sh/install | bash`)
- [ ] claude.ai 구독 상태 확인 (Pro/Max)
- [ ] 텔레그램 봇 토큰 확인 (`omx-bridge/.env` 재활용)

### Phase 2-A: 신규 설치

```bash
NAME=andy  # 인스턴스 이름

mkdir -p ~/.config/claude-resident/$NAME/memory

cp memory/soul.md.example     ~/.config/claude-resident/$NAME/memory/soul.md
cp memory/user.md.example     ~/.config/claude-resident/$NAME/memory/user.md
cp memory/workflow.md.example ~/.config/claude-resident/$NAME/memory/workflow.md
cp memory/projects.md.example ~/.config/claude-resident/$NAME/memory/projects.md
cp memory/recent.md.example   ~/.config/claude-resident/$NAME/memory/recent.md
cp CLAUDE.md                  ~/.config/claude-resident/$NAME/CLAUDE.md

# <name> 플레이스홀더 교체
sed -i "s/<name>/$NAME/g" ~/.config/claude-resident/$NAME/CLAUDE.md
```

- [ ] `soul.md` / `user.md` 내용 작성 (캐릭터·사용자 정보)

### Phase 2-B: OpenClaw에서 마이그레이션

```bash
NAME=andy  # 인스턴스 이름
OPENCLAW_DIR=~/.openclaw/workspace

mkdir -p ~/.config/claude-resident/$NAME/memory

# 기존 OpenClaw 메모리 이전
cp $OPENCLAW_DIR/SOUL.md ~/.config/claude-resident/$NAME/memory/soul.md
cp $OPENCLAW_DIR/USER.md ~/.config/claude-resident/$NAME/memory/user.md

# 최근 맥락 이전 (가장 최신 파일)
LATEST=$(ls -t $OPENCLAW_DIR/memory/*.md 2>/dev/null | head -1)
[ -n "$LATEST" ] && cp "$LATEST" ~/.config/claude-resident/$NAME/memory/recent.md

cp memory/workflow.md.example ~/.config/claude-resident/$NAME/memory/workflow.md
cp memory/projects.md.example ~/.config/claude-resident/$NAME/memory/projects.md
cp CLAUDE.md                  ~/.config/claude-resident/$NAME/CLAUDE.md

sed -i "s/<name>/$NAME/g" ~/.config/claude-resident/$NAME/CLAUDE.md
```

> ⚠️ OpenClaw SOUL.md/USER.md 포맷이 다를 수 있으므로 이전 후 내용 확인 권장

### Phase 3: Channels 설정
- [ ] `/plugin marketplace add anthropics/claude-plugins-official`
- [ ] `/plugin install telegram@claude-plugins-official`
- [ ] `/telegram:configure <BOT_TOKEN>`
- [ ] 페어링 완료 (`/telegram:access pair <code>`)
- [ ] allowlist 설정 (`/telegram:access policy allowlist`)

### Phase 4: 세션 영속화
- [ ] `claude-resident` → `~/.local/bin/claude-resident` (chmod +x)
- [ ] 심볼릭 링크: `ln -s ~/.local/bin/claude-resident ~/.local/bin/cr`
- [ ] `claude-resident@.service` → `~/.config/systemd/user/`
- [ ] `claude-resident-restart@.timer` → `~/.config/systemd/user/`
- [ ] `claude-resident-restart@.service` → `~/.config/systemd/user/`
- [ ] `systemctl --user daemon-reload`
- [ ] `systemctl --user enable --now claude-resident@$NAME.service`
- [ ] `systemctl --user enable claude-resident-restart@$NAME.timer`
- [ ] 세션 복원 테스트: kill → 재시작 → 텔레그램 온라인 알림 확인

### Phase 5: OMX 연계 검증
- [ ] 텔레그램 코딩 요청 → omx-bridge 호출 → 결과 수신 확인
- [ ] `[앤디]` / `✅ omx job` 접두어 구분 확인

---

## 10. 파일 목록

```
(레포 루트)
    claude-resident                    → ~/.local/bin/claude-resident  (chmod +x)
    claude-resident@.service           → ~/.config/systemd/user/
    claude-resident-restart@.timer     → ~/.config/systemd/user/
    claude-resident-restart@.service   → ~/.config/systemd/user/
    CLAUDE.md                          → ~/.config/claude-resident/<name>/CLAUDE.md
    memory/
        soul.md            → ~/.config/claude-resident/<name>/memory/soul.md
        user.md            → ~/.config/claude-resident/<name>/memory/user.md
        workflow.md        → ~/.config/claude-resident/<name>/memory/workflow.md
        projects.md        → ~/.config/claude-resident/<name>/memory/projects.md
        recent.md          → ~/.config/claude-resident/<name>/memory/recent.md
```

**서비스 관리 명령어 (andy 인스턴스 기준):**

```bash
# 상태 확인
systemctl --user status claude-resident@andy
claude-resident andy status

# 재시작
systemctl --user restart claude-resident@andy

# 로그
journalctl --user -u claude-resident@andy -f
tail -f ~/.local/state/claude-resident/andy/agent.log
```

---

## 참고 자료

- [Claude Code Channels 공식 문서](https://code.claude.com/docs/en/channels)
- [Channels Reference](https://code.claude.com/docs/en/channels-reference)
- [공식 플러그인 소스 (Telegram)](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/telegram)
- omx-bridge: `~/workspace/omx-bridge`
- OpenClaw 메모리: `~/.openclaw/workspace/`
