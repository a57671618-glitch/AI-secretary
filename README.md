# 오르빗 업무 운영실

Next.js App Router 기반의 업무 비서 프로토타입입니다. 대시보드, 업무 등록과 상태 관리, Tiptap 문서와 버전 이력, 승인 기록, 비공개 첨부파일, AI 어시스턴트를 제공합니다.

## 이 기기에서 실행

1. Node.js 22 이상에서 `npm install`을 실행합니다.
2. `.env.example`을 `.env.local`로 복사하고 `ORBIT_LOCAL_DEMO=1`을 설정합니다. 로컬 설정 파일이 이미 있으면 그 파일을 사용합니다.
3. `npm run dev -- --port 3100`을 실행한 뒤 [로컬 미리보기](http://127.0.0.1:3100)를 엽니다.

로컬 모드는 루프백에서만 실행되며 PGlite의 PostgreSQL과 로컬 파일 저장소를 사용합니다. 업무와 파일은 `.orbit-local/` 아래에 저장됩니다. n8n 연결이 설정되면 샘플 원고에서도 실제 Gemini API를 호출합니다. 연결 정보가 없으면 어시스턴트에 규칙 기반 데모로 표시됩니다.

## n8n 연동

[오르빗 워크스페이스 · Gemini API](http://localhost:5678/workflow/IHVDxs6L2NVQYWix)는 `POST /webhook/orbit-workspace-ai-v1`에서 인증된 요청을 받습니다. 기존 수동 검수 워크플로우와 독립적으로 운영됩니다.

- `N8N_WEBHOOK_URL`에는 웹훅 URL을 넣습니다. 로컬 개발은 루프백 HTTP를, Vercel은 Vercel 서버에서 접근할 수 있는 HTTPS 주소를 사용합니다.
- `N8N_WEBHOOK_SECRET`은 서버에만 설정합니다. Route Handler가 `X-Orbit-Webhook-Secret` 헤더로 전달하고 n8n은 SHA-256 값으로 대조합니다.
- 웹훅 입력은 `action`, `prompt`, `title`, `manuscript`이고 응답은 `summary`, `draft`, `findings`입니다. 실행 데이터 저장은 이 워크플로우에서 비활성화돼 있습니다.

## Vercel 환경

- Clerk의 공개 키와 서버 키를 입력합니다. 개인 기록은 로그인 계정에, 조직 기록은 선택한 Clerk 조직에 속합니다. 조직에서는 관리자만 승인 결정을 기록할 수 있습니다.
- Neon PostgreSQL 연결 문자열을 `DATABASE_URL`로 설정한 뒤, 대상 데이터베이스를 확인하고 `npm run db:migrate`로 포함된 마이그레이션을 적용합니다.
- Vercel **Private** Blob 스토어를 프로젝트에 연결합니다. 서버로 들어오는 파일은 4MB 이하로 제한됩니다.
- 위 n8n 환경 변수를 Preview 또는 Production에 넣고 배포합니다. `ORBIT_LOCAL_DEMO`는 개발 실행에서만 적용됩니다.
- `npm run typecheck`와 `npm run build`로 검사할 수 있습니다.

승인 기록은 저장된 문서 버전을 대상으로 합니다. 메일과 일정은 초안을 반환하며 외부 발송, 게시, 캘린더 등록은 현재 승인 기록 이후에 연결할 범위입니다.
