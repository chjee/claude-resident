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
6. **XDG 디렉토리 준수** — config(`~/.config/`)와 runtime state/log(`~/.local/state/`) 분리로 백업·배포 용이

---

## 0-2. 기본 운영 가정

이 문서의 기본 가정은 **1머신 1resident** 다.

- 개인 노트북에서 resident 하나를 장기 상주시킨다
- Claude resident와 OpenClaw를 함께 쓸 수는 있지만, 같은 봇 토큰을 공유하지 않는다
- 다중 인스턴스(`andy`, `john`)는 가능한 구조이지만, 기본 운영 경로로는 가정하지 않는다

즉 문서와 스크립트는 **단일 인스턴스 안정성**을 우선하고, 다중 인스턴스는 필요해질 때 확장하는 전략을 기준으로 한다.

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
    ├── 인스턴스 디렉토리를 cwd로 잡고
    │   claude --add-dir ~/workspace --channels plugin:telegram@claude-plugins-official 실행
    │   (CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 설정)
    └── 5초 후 __STARTUP__ 전송 (Telegram Bot API 직접 호출)
         ↓
         CLAUDE.md의 Session Startup Sequence 실행
         ↓
         soul.md → user.md → daily/today + daily/yesterday 읽기
         (필요 시 last-active.md / MEMORY.md / workflow.md / projects.md 추가)
         ↓
         텔레그램: "🟢 앤디 온라인 · [날짜/시간] · [한 줄 상태]"
```

### CLAUDE.md 핵심 구조

```markdown
# Session Startup Sequence
첫 메시지 수신 또는 __STARTUP__ 트리거 시:
1. soul.md → user.md → memory/daily/오늘.md → memory/daily/어제.md 순서로 읽기
2. 필요 시 last-active.md / MEMORY.md / workflow.md / projects.md 추가 로드
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
대화 종료 / OMX 작업 완료 / 중요한 결정 시 memory/daily/YYYY-MM-DD.md에 append.
last-active.md는 daily append 성공 후 갱신한다.
```

운영 원칙:
- 텔레그램 응답은 짧고 명확하게 (모바일 기준)
- 코딩/수정/테스트/대량 편집 → OMX 위임
- 질문/설계/검토/간단한 확인 → Claude 직접 처리
- 응답 접두어: `[앤디]` (Claude), `✅/❌ omx job` (omx-bridge) — 발신자 구분

---

## 5. Memory 파일 구조

```
~/.config/claude-resident/<name>/   ← 인스턴스 설정 홈 (Claude cwd)
    ├── CLAUDE.md                   ← resident 세션에서 항상 로드
    └── memory/
        ├── soul.md       ← 캐릭터/페르소나 (변경 거의 없음)
        ├── user.md       ← 사용자 정보 (가끔 업데이트)
        ├── MEMORY.md     ← 장기 기억 큐레이션 (필요 시 로드)
        ├── workflow.md   ← 역할 분담 + omx-bridge 호출법 (변경 거의 없음)
        ├── projects.md   ← 진행 중/완료 프로젝트 현황 (프로젝트 변경 시)
        ├── last-active.md ← 장기 중단/주말 복구용 포인터
        └── daily/
            └── YYYY-MM-DD.md ← 날짜별 단기 작업 로그

~/.local/state/claude-resident/<name>/
    └── agent.log         ← 실행 로그
```

> 인스턴스 하나 = 설정 디렉토리 하나. 새 머신 설치 또는 마이그레이션 시 설정 디렉토리를 복사하면 resident 메모리가 함께 이동한다:
> ```bash
> rsync -av ~/.config/claude-resident/andy/ new-machine:~/.config/claude-resident/andy/
> ```

**daily 업데이트 트리거:**

| 트리거 | 예시 |
|--------|------|
| 대화 종료 신호 | "잘자", "내일봐", "수고", "bye", "끊을게" |
| OMX 작업 완료 | 작업 결과 알림 수신 후 |
| 중요한 결정 | 아키텍처 결정, 방향 전환, 새 프로젝트 시작 |

**daily 보존 정책:**
- `memory/daily/YYYY-MM-DD.md`는 최근 60일만 보존
- 60일 초과 파일은 새벽 restart maintenance 단계에서 정리
- `[memory-candidate]`, `[project-candidate]`, `[workflow-candidate]` 태그가 남은 파일은 삭제하지 않고 warning만 남김

---

## 6. 세션 영속화

### claude-resident 스크립트

`<name> [start|stop|restart|status|check|shutdown|cleanup-memory|logs|attach]` 형식으로 인스턴스별 관리. 전체 코드: `claude-resident`

```
claude-resident andy start 동작:
1. 기존 tmux 세션(claude-resident-andy) 존재 여부 확인
2. `~/.config/claude-resident/<name>/` 와 `~/.local/state/claude-resident/<name>/` 초기화
3. omx-bridge/.env 에서 TELEGRAM_BOT_TOKEN, TELEGRAM_NOTIFY_CHAT_ID 로드
4. tmux 세션을 인스턴스 설정 디렉토리에서 시작하고 `claude --add-dir ~/workspace --channels ...` 실행
   - resident `CLAUDE.md`는 cwd 기준으로 즉시 로드
   - `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` 로 workspace 내 repo `CLAUDE.md`도 필요 시 함께 로드
   - 로그: `~/.local/state/claude-resident/<name>/agent.log`
5. 백그라운드에서 5초 후 __STARTUP__ 메시지를 Telegram Bot API로 전송
6. `check` 명령으로 resident 실행 전 필수 파일/토큰/tmux 세션 상태를 점검 가능
```

### systemd 자동 시작

```bash
# 설치
./install.sh
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
| 기본 | `claude-resident-restart@.timer` 매일 새벽 6시 | compaction 자체 예방 |
| 복구 | CLAUDE.md Post-Compaction Recovery | compaction 감지 시 soul/user 자동 재로드 |
| 운영 | 이벤트마다 daily 갱신 | 재시작 후 복원 품질 보장 |
| 예외 | Claude 자가 경고 → 수동 재시작 | 예상치 못한 급증 대응 |

**중요:** `claude-resident-restart@.timer`는 compaction 예방용이고,
daily 메모리는 복원 품질 보장용이다. 자동 종료 저장(`__SHUTDOWN__`)은
best-effort이므로 두 가지 모두 운영해야 효과가 있다.

`claude-resident-restart@.service`는 직접 `claude-resident <name> start`를 호출하지 않고
`systemctl --user restart claude-resident@<name>.service`로 main service를 재시작한다.
그래야 tmux 세션과 하위 Claude/plugin 프로세스가 `claude-resident@<name>.service`
cgroup 아래에서 일관되게 관리된다.

배포:
```bash
./install.sh
systemctl --user enable claude-resident-restart@andy.timer
systemctl --user enable --now claude-resident-health@andy.timer
```

새벽 재시작 전에는 `claude-resident <name> cleanup-memory`가 실행되어 60일 초과 daily 파일을 정리한다.
candidate 태그가 남은 파일은 삭제하지 않고 warning 로그만 남긴다.

### 프로세스 소멸 복구 (헬스체크 타이머)

`Type=oneshot` 구조 특성상 systemd는 tmux 내부 프로세스 종료를 감지하지 못한다.
`claude-resident-health@.timer`가 5분마다 tmux 세션 생존 여부를 확인하고, 소멸 시 자동 복구한다.

- **복구 범위**: 프로세스/세션 소멸. Claude hang이나 plugin 응답 불능은 감지하지 못함
- **의도적 정지 보호**: `systemctl --user is-active` gate로 `systemctl stop` 후에는 복구하지 않음
- **주의**: 운영 중 정지는 반드시 `systemctl --user stop claude-resident@<name>.service` 사용. `claude-resident <name> stop` 직접 실행 시 systemd 상태가 active로 남아 health timer가 되살림
- **주의**: tmux 세션이 살아 있어도 Telegram poller를 다른 Claude 세션이 가져간 경우는 감지하지 못함. `claude-resident <name> check`의 global token warning과 `TELEGRAM_STATE_DIR` 분리 상태를 확인한다.

```bash
systemctl --user enable --now claude-resident-health@andy.timer
```

### __STARTUP__ 트리거 방식

**임시안 (현재 설계):** `claude-resident`가 Telegram Bot API로 직접 전송
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

## 9. 실제 설치 기록 (john 인스턴스, 2026-04-14)

존 노트북(WSL2, Ubuntu)에서 첫 인스턴스 설치 완료. 이 과정에서 발견한 이슈와 해결책을 반영한 가이드다.

### 사전 조건

| 항목 | 확인 |
|------|------|
| `bun` 설치 | `curl -fsSL https://bun.sh/install | bash` (unzip 먼저 필요: `sudo apt-get install -y unzip`) |
| `tmux` 설치 | `tmux -V` (없으면 `sudo apt-get install -y tmux`) |
| Claude Code | `claude --version` (v2.1.80+) |
| claude.ai 구독 | Pro/Max (API 키 불가) |
| 텔레그램 봇 | 인스턴스별 전용 봇 권장 (봇 간 polling 충돌 방지) |

> **봇 충돌 주의**: OpenClaw와 claude-resident가 같은 봇 토큰을 공유하면 409 Conflict 발생. 인스턴스별로 다른 봇을 사용하거나, 테스트 시 OpenClaw를 중지할 것.

> **운영 권장**: 기본은 한 머신에 resident 하나만 두고 운영한다. 같은 머신에서 여러 resident를 동시에 돌리는 건 필요해질 때만 확장한다.

---

### Phase 1: Telegram 플러그인 설치

```bash
# Claude Code 세션에서 실행
claude plugin install telegram@claude-plugins-official
```

기본 Telegram 플러그인 상태 디렉토리 준비:

```bash
mkdir -p ~/.claude/channels/telegram
```

> resident 운영에서는 실제 봇 토큰/알림 chat_id를 보통 인스턴스 `.env`에 둔다. 전역 `~/.claude/channels/telegram/.env`는 resident 없이 Claude Telegram 플러그인만 단독 테스트할 때 주로 쓴다.

allowlist 설정 (페어링 없이 바로 허용):

```bash
cat > ~/.claude/channels/telegram/access.json << 'EOF'
{
    "dmPolicy": "open",
    "allowFrom": ["<내_텔레그램_chat_id>"],
    "groups": {},
    "pending": {}
}
EOF
```

> **chat_id 확인법**: 봇에게 DM을 보낸 후 `https://api.telegram.org/bot<TOKEN>/getUpdates` 로 확인하거나, 봇 채팅에서 전송 후 pending 항목의 `senderId` 확인.

---

### Phase 2: 인스턴스 디렉토리 구성

```bash
NAME=john  # 인스턴스 이름

mkdir -p ~/.config/claude-resident/$NAME/memory
mkdir -p ~/.local/state/claude-resident/$NAME
```

**인스턴스별 설정** (`~/.config/claude-resident/$NAME/.env`):

```bash
cat > ~/.config/claude-resident/$NAME/.env << 'EOF'
TELEGRAM_BOT_TOKEN=<인스턴스_전용_봇_토큰>
TELEGRAM_NOTIFY_CHAT_ID=<내_텔레그램_chat_id>
WEBHOOK_PORT=3993
# 선택: 기본값은 ~/.config/claude-resident/$NAME/telegram
# TELEGRAM_STATE_DIR=~/.config/claude-resident/$NAME/telegram
# 선택: 기본값은 bypassPermissions
# CLAUDE_RESIDENT_PERMISSION_MODE=acceptEdits
# 선택: startup/shutdown 트리거 타이밍 조정
# CLAUDE_RESIDENT_STARTUP_DELAY_SEC=5
# CLAUDE_RESIDENT_TRIGGER_RETRY_DELAY_SEC=2
# CLAUDE_RESIDENT_STARTUP_RETRIES=3
# CLAUDE_RESIDENT_SHUTDOWN_RETRIES=2
EOF
```

> 이 파일이 있으면 `omx-bridge/.env`보다 우선 적용된다.
> `WEBHOOK_PORT`는 resident별 omx-bridge MCP 알림 포트를 구분할 때 사용한다.
> `TELEGRAM_STATE_DIR`는 Telegram plugin의 `access.json`, `bot.pid`, inbox를 인스턴스별로 분리한다.

> ⚠️ Telegram을 resident 전용으로 쓸 경우, 같은 bot token을 `~/.claude/channels/telegram/.env`에 두지 않는다.
> 전역 Claude 세션이 같은 token으로 Telegram plugin을 띄우면 Telegram long polling 소유권을 가져가 resident가 응답하지 않을 수 있다.

**CLAUDE.md 작성** (`~/.config/claude-resident/$NAME/CLAUDE.md`):

레포의 `CLAUDE.md`를 복사 후 인스턴스에 맞게 수정:
- 이름/호칭 변경 (`앤디` → `존` 등)
- 온/오프라인 메시지 문구 조정
- 주요 경로의 `<name>` 플레이스홀더 교체

**메모리 파일 작성**:

```
~/.config/claude-resident/$NAME/memory/
    soul.md         — 캐릭터/페르소나 (이름, 역할, 말투)
    user.md         — 사용자 정보 (chat_id, 이름, 작업 스타일)
    MEMORY.md       — 장기 기억 큐레이션 (필요 시)
    workflow.md     — 반복 운영 절차 (필요 시)
    projects.md     — 프로젝트 상태 (필요 시)
    last-active.md  — 장기 중단/주말 복구용 포인터 (없어도 시작 가능)
    daily/          — 날짜별 단기 작업 로그 (없어도 시작 가능)
```

**OpenClaw에서 마이그레이션하는 경우**:

```bash
OPENCLAW_DIR=~/.openclaw/workspace

# soul.md / user.md 이전
cp $OPENCLAW_DIR/SOUL.md ~/.config/claude-resident/$NAME/memory/soul.md
cp $OPENCLAW_DIR/USER.md ~/.config/claude-resident/$NAME/memory/user.md

# 최근 맥락 이전 (가장 최신 파일을 오늘 daily로 복사)
LATEST=$(ls -t $OPENCLAW_DIR/memory/*.md 2>/dev/null | head -1)
mkdir -p ~/.config/claude-resident/$NAME/memory/daily
[ -n "$LATEST" ] && cp "$LATEST" ~/.config/claude-resident/$NAME/memory/daily/$(date +%F).md

# OpenClaw openclaw.json에서 봇 토큰, chat_id 확인
cat ~/.openclaw/openclaw.json | python3 -m json.tool | grep -E "botToken|allowFrom"
```

> ⚠️ OpenClaw의 SOUL.md/USER.md 포맷이 다를 수 있으므로 이전 후 내용 확인 권장

---

### Phase 3: 바이너리 및 systemd 설치

```bash
./install.sh
```

> 현재 레포의 `claude-resident@.service`와 `claude-resident` 스크립트는 `~/.bun/bin`을 포함하는 PATH를 전제로 이미 맞춰져 있다. 레포 파일을 그대로 설치했다면 별도 PATH 수정을 다시 할 필요는 없다.

---

### Phase 4: 서비스 시작

```bash
systemctl --user start claude-resident@$NAME.service
systemctl --user status claude-resident@$NAME.service
claude-resident $NAME check
```

이 서비스는 `Type=oneshot`, `RemainAfterExit=yes` 로 동작하는 `tmux` 런처라서, `systemctl --user status`에서 `active (exited)`로 보이는 것이 정상이다.
실제 resident가 살아 있는지는 아래 둘로 확인한다.

- `claude-resident $NAME check`
- `tmux has-session -t claude-resident-$NAME`

**최초 기동 시 `bypassPermissions` 확인 처리**:

tmux 세션에서 확인 창이 뜨면 선택해야 한다:

```bash
claude-resident $NAME attach
# "2. Yes, I accept" 선택 후 Ctrl+B D로 detach
```

또는:

```bash
tmux send-keys -t claude-resident-$NAME "2" Enter
```

이후 재시작 시에는 자동으로 처리된다.

---

### Phase 5: 검증

텔레그램에서 확인:
- `🟢 존 온라인` 메시지 수신 여부
- 메시지 보내면 Claude 응답 여부 (타이핑 → 응답)

```bash
# 사전 점검
claude-resident $NAME check

# 로그 확인
claude-resident $NAME logs

# tmux 세션 직접 확인
claude-resident $NAME attach
```

`check` 명령은 다음을 본다:

- `claude`, `tmux`, `bun` 존재 여부
- `CLAUDE.md`, `memory/soul.md`, `memory/user.md`
- `memory/daily/` 또는 과도기 fallback `memory/recent.md`
- 인스턴스 `.env` 또는 fallback `.env`
- `TELEGRAM_BOT_TOKEN`, `TELEGRAM_NOTIFY_CHAT_ID`, `WEBHOOK_PORT`
- `TELEGRAM_STATE_DIR`, `CLAUDE_RESIDENT_PERMISSION_MODE` 반영 결과
- tmux 세션 실행 여부

---

### Phase 5-1: 그룹 채팅방 연동 (선택)

봇을 그룹에 초대한 후 `access.json`의 `groups`에 해당 채팅방의 **실제 chat_id**를 추가해야 한다.

> ⚠️ `"*"` 와일드카드는 동작하지 않는다. `server.ts`가 `access.groups[groupId]`로 직접 키 조회를 하기 때문에 정확한 chat_id가 필요하다.

**그룹 chat_id 확인 방법:**

```bash
# 1. 인스턴스 세션 잠깐 중단
systemctl --user stop claude-resident@$NAME.service

# 2. 그룹에서 봇 멘션 (@봇이름 텍스트)

# 3. getUpdates로 chat_id 캡처 (봇이 멈춰있는 동안만 가능)
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates?offset=-5&timeout=15" | \
  python3 -c "
import json, sys
for upd in json.load(sys.stdin).get('result', []):
    chat = upd.get('message', {}).get('chat', {})
    if chat.get('type') in ('group', 'supergroup'):
        print(f\"chat_id={chat['id']} title={chat['title']}\")
"

# 4. access.json에 추가
```

`$TELEGRAM_STATE_DIR/access.json` (기본값: `~/.config/claude-resident/$NAME/telegram/access.json`):

```json
{
    "dmPolicy": "open",
    "allowFrom": ["<내_chat_id>"],
    "groups": {
        "<group_chat_id>": {
            "requireMention": true
        }
    },
    "pending": {}
}
```

```bash
# 5. 세션 재시작
systemctl --user start claude-resident@$NAME.service
```

이후 그룹에서 봇을 멘션하면 메시지가 전달된다.

---

### Phase 6: OMX 연계 (추후)

omx-bridge `NOTIFY_MODE=claude` 전환 후 E2E 검증:

```bash
# omx-bridge .env 수정
NOTIFY_MODE=claude
CLAUDE_NOTIFY_URL=http://127.0.0.1:3993/notify

systemctl --user restart omx-bridge
```

---

## 10. 구현 체크리스트 (앤디 이식용)

- [ ] `sudo apt-get install -y unzip` → `curl -fsSL https://bun.sh/install | bash`
- [ ] `claude plugin install telegram@claude-plugins-official`
- [ ] `~/.config/claude-resident/andy/.env` — 인스턴스 봇 토큰/chat_id
- [ ] `~/.config/claude-resident/andy/CLAUDE.md` — 작성
- [ ] `~/.config/claude-resident/andy/memory/` — soul.md, user.md, daily/
- [ ] `~/.config/claude-resident/andy/telegram/` — access.json, bot.pid 등 인스턴스 전용 Telegram state
- [ ] `claude-resident@.service` PATH에 `%h/.bun/bin:` 추가
- [ ] systemd 파일 설치 + `daemon-reload`
- [ ] `systemctl --user start claude-resident@andy.service`
- [ ] 최초 기동 시 bypassPermissions "2. Yes, I accept" 선택
- [ ] 텔레그램 온라인 알림 확인
- [ ] 메시지 응답 확인
- [ ] (선택) 그룹 채팅방 연동: 세션 중단 → getUpdates로 chat_id 캡처 → access.json groups에 추가 → 재시작
- [ ] (추후) omx-bridge NOTIFY_MODE=claude 전환

---

## 11. 파일 목록

```
(레포 루트)
    claude-resident                    → ~/.local/bin/claude-resident  (chmod +x)
    claude-resident@.service           → ~/.config/systemd/user/
    claude-resident-restart@.timer     → ~/.config/systemd/user/
    claude-resident-restart@.service   → ~/.config/systemd/user/
    claude-resident-health@.service    → ~/.config/systemd/user/
    claude-resident-health@.timer      → ~/.config/systemd/user/
    install.sh                         → installs binary + systemd units
    CLAUDE.md                          → ~/.config/claude-resident/<name>/CLAUDE.md
    memory/
        soul.md.example    → ~/.config/claude-resident/<name>/memory/soul.md
        user.md.example    → ~/.config/claude-resident/<name>/memory/user.md
        workflow.md.example → ~/.config/claude-resident/<name>/memory/workflow.md
        projects.md.example → ~/.config/claude-resident/<name>/memory/projects.md
        daily/
            YYYY-MM-DD.md.example → ~/.config/claude-resident/<name>/memory/daily/YYYY-MM-DD.md

    (runtime)
    ~/.local/state/claude-resident/<name>/agent.log
```

**서비스 관리 명령어 (andy 인스턴스 기준):**

```bash
# 상태 확인
systemctl --user status claude-resident@andy
claude-resident andy status
claude-resident andy check

# 재시작
systemctl --user restart claude-resident@andy

# 로그
journalctl --user -u claude-resident@andy -f
claude-resident andy logs
```

> `agent.log`는 TTY 제어문자를 제거한 plain-text 로그를 남기도록 되어 있다. resident가 실제로 어떤 메시지를 받았고 어떤 상태로 올라왔는지 확인하는 용도로 쓴다.

---

## 참고 자료

- [Claude Code Channels 공식 문서](https://code.claude.com/docs/en/channels)
- [Channels Reference](https://code.claude.com/docs/en/channels-reference)
- [공식 플러그인 소스 (Telegram)](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/telegram)
- omx-bridge: `~/workspace/omx-bridge`
- OpenClaw 메모리: `~/.openclaw/workspace/`
