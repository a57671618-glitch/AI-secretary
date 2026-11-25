BEGIN;

CREATE SCHEMA IF NOT EXISTS orbit_n8n;

CREATE TABLE IF NOT EXISTS orbit_n8n.jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope text NOT NULL,
  request_key text NOT NULL,
  source text NOT NULL CHECK (source IN ('site', 'gmail')),
  kind text NOT NULL CHECK (kind IN ('mail', 'document', 'calendar')),
  request jsonb NOT NULL,
  state text NOT NULL DEFAULT 'queued' CHECK (state IN (
    'queued', 'generating', 'needs_revision', 'pending_approval', 'rejected',
    'approved', 'executing', 'completed', 'generation_failed', 'execution_uncertain', 'execution_failed'
  )),
  draft_version integer NOT NULL DEFAULT 1,
  attempts integer NOT NULL DEFAULT 0,
  automatic_revisions integer NOT NULL DEFAULT 0,
  feedback text,
  draft jsonb,
  review jsonb,
  result jsonb,
  last_error text,
  decision_by text,
  run_after timestamptz NOT NULL DEFAULT now(),
  execution_ref text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (scope, request_key)
);

ALTER TABLE orbit_n8n.jobs ADD COLUMN IF NOT EXISTS execution_attempts integer NOT NULL DEFAULT 0;
ALTER TABLE orbit_n8n.jobs DROP CONSTRAINT IF EXISTS jobs_state_check;
ALTER TABLE orbit_n8n.jobs ADD CONSTRAINT jobs_state_check CHECK (state IN (
  'queued', 'generating', 'needs_revision', 'pending_approval', 'rejected',
  'approved', 'executing', 'completed', 'generation_failed', 'execution_uncertain', 'execution_failed'
));

CREATE TABLE IF NOT EXISTS orbit_n8n.scope_settings (
  scope text PRIMARY KEY,
  preferences text NOT NULL CHECK (char_length(preferences) <= 2000)
);

CREATE TABLE IF NOT EXISTS orbit_n8n.manuscripts (
  job_id uuid NOT NULL REFERENCES orbit_n8n.jobs(id),
  version integer NOT NULL,
  title text NOT NULL,
  content text NOT NULL,
  approved_payload jsonb NOT NULL,
  review jsonb NOT NULL,
  archived_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (job_id, version)
);

INSERT INTO orbit_n8n.manuscripts (job_id, version, title, content, approved_payload, review)
SELECT id, draft_version, draft->>'title', draft->>'body', draft, review
FROM orbit_n8n.jobs
WHERE review @> '{"passed":true}'::jsonb AND draft->>'title' IS NOT NULL AND draft->>'body' IS NOT NULL
ON CONFLICT DO NOTHING;

CREATE INDEX IF NOT EXISTS orbit_n8n_jobs_queue ON orbit_n8n.jobs (state, run_after, created_at);
CREATE INDEX IF NOT EXISTS orbit_n8n_jobs_scope ON orbit_n8n.jobs (scope, created_at DESC);

CREATE TABLE IF NOT EXISTS orbit_n8n.audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES orbit_n8n.jobs(id),
  state text NOT NULL,
  draft_version integer NOT NULL,
  execution_ref text,
  details jsonb NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS orbit_n8n_audit_job ON orbit_n8n.audit (job_id, id);

CREATE OR REPLACE FUNCTION orbit_n8n.audit_job() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO orbit_n8n.audit (job_id, state, draft_version, execution_ref, details)
  VALUES (NEW.id, NEW.state, NEW.draft_version, NEW.execution_ref, jsonb_strip_nulls(jsonb_build_object(
    'actor', NEW.decision_by, 'attempts', NEW.attempts, 'executionAttempts', NEW.execution_attempts, 'error', NEW.last_error,
    'feedback', NEW.feedback, 'result', NEW.result,
    'draft', CASE WHEN NEW.state IN ('pending_approval', 'needs_revision') THEN NEW.draft END,
    'review', CASE WHEN NEW.state IN ('pending_approval', 'needs_revision') THEN NEW.review END
  )));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER orbit_n8n_audit_job AFTER INSERT OR UPDATE ON orbit_n8n.jobs
FOR EACH ROW EXECUTE FUNCTION orbit_n8n.audit_job();

CREATE OR REPLACE FUNCTION orbit_n8n.view_job(job orbit_n8n.jobs) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT to_jsonb(job) - 'execution_ref' - 'request_key';
$$;

CREATE OR REPLACE FUNCTION orbit_n8n.intake(p jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  job orbit_n8n.jobs;
  action text := p->>'action';
  job_scope text := p->>'scope';
  actor text := p->>'actor';
  requested_version integer := (p->>'version')::integer;
  has_approval boolean := coalesce((p->>'mayApprove')::boolean, false);
  target uuid := (p->>'id')::uuid;
BEGIN
  IF p ? 'error' THEN
    RETURN jsonb_build_object('statusCode', 400, 'error', p->>'error');
  END IF;

  IF job_scope = 'gmail:inbox' AND action <> 'receive_gmail' AND NOT has_approval THEN
    RETURN jsonb_build_object('statusCode', 403, 'error', 'Gmail 작업함 권한이 필요합니다.');
  END IF;

  IF action = 'get_settings' THEN
    RETURN jsonb_build_object('statusCode', 200, 'preferences', coalesce((
      SELECT preferences FROM orbit_n8n.scope_settings WHERE scope = job_scope
    ), ''));
  END IF;

  IF action = 'save_settings' THEN
    IF NOT has_approval THEN RETURN jsonb_build_object('statusCode', 403, 'error', '설정 관리 권한이 필요합니다.'); END IF;
    INSERT INTO orbit_n8n.scope_settings (scope, preferences) VALUES (job_scope, p->>'preferences')
      ON CONFLICT (scope) DO UPDATE SET preferences = excluded.preferences;
    RETURN jsonb_build_object('statusCode', 200, 'preferences', p->>'preferences');
  END IF;

  IF action IN ('submit', 'receive_gmail') THEN
    IF action = 'receive_gmail' THEN job_scope := 'gmail:inbox'; END IF;
    IF action = 'submit' AND job_scope = 'gmail:inbox' THEN
      RETURN jsonb_build_object('statusCode', 403, 'error', 'Gmail 작업함은 수신 전용입니다.');
    END IF;
    INSERT INTO orbit_n8n.jobs (scope, request_key, source, kind, request, run_after)
    VALUES (job_scope, p->>'key', CASE WHEN action = 'submit' THEN 'site' ELSE 'gmail' END,
      p->>'kind', p->'request', coalesce((p->>'runAfter')::timestamptz, now()))
    ON CONFLICT (scope, request_key) DO NOTHING RETURNING * INTO job;
    IF FOUND THEN
      RETURN jsonb_build_object('statusCode', 202, 'job', orbit_n8n.view_job(job));
    END IF;
    SELECT * INTO job FROM orbit_n8n.jobs WHERE scope = job_scope AND request_key = p->>'key';
    IF action = 'submit' AND (job.request <> p->'request' OR job.kind <> p->>'kind') THEN
      RETURN jsonb_build_object('statusCode', 409, 'error', '다른 요청에 이미 사용된 요청 키입니다.');
    END IF;
    RETURN jsonb_build_object('statusCode', 200, 'job', orbit_n8n.view_job(job));
  END IF;

  IF action = 'list' THEN
    RETURN jsonb_build_object('statusCode', 200, 'jobs', coalesce((
      SELECT jsonb_agg(item ORDER BY created_at DESC, id DESC) FROM (
        SELECT id, created_at, jsonb_build_object('id', id, 'state', state, 'kind', kind,
          'title', coalesce(draft->>'title', request->>'title'), 'draft_version', draft_version,
          'updated_at', updated_at) AS item
        FROM orbit_n8n.jobs WHERE scope = job_scope
        ORDER BY created_at DESC, id DESC LIMIT 50
      ) recent
    ), '[]'::jsonb));
  END IF;

  IF action = 'get' THEN
    SELECT * INTO job FROM orbit_n8n.jobs WHERE id = target AND scope = job_scope;
    IF FOUND THEN RETURN jsonb_build_object('statusCode', 200, 'job', orbit_n8n.view_job(job)); END IF;
    RETURN jsonb_build_object('statusCode', 404, 'error', '요청을 찾을 수 없습니다.');
  END IF;

  IF NOT has_approval OR coalesce(actor, '') = '' THEN
    RETURN jsonb_build_object('statusCode', 403, 'error', '승인 권한이 필요합니다.');
  END IF;

  SELECT * INTO job FROM orbit_n8n.jobs WHERE id = target AND scope = job_scope FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('statusCode', 404, 'error', '요청을 찾을 수 없습니다.'); END IF;
  IF job.draft_version IS DISTINCT FROM requested_version OR NOT (
    (action IN ('approve', 'reject') AND job.state = 'pending_approval') OR
    (action = 'revise' AND job.state IN ('pending_approval', 'needs_revision', 'generation_failed')) OR
    (action = 'retry_execution' AND job.state = 'execution_failed')
  ) THEN
    RETURN jsonb_build_object('statusCode', 409, 'error', '이미 처리됐거나 초안 버전이나 상태가 바뀌었습니다.');
  END IF;

  IF action IN ('approve', 'retry_execution') AND NOT EXISTS (
    SELECT 1 FROM orbit_n8n.manuscripts m
    WHERE m.job_id = job.id AND m.version = job.draft_version AND m.approved_payload = job.draft
  ) THEN
    RETURN jsonb_build_object('statusCode', 409, 'error', '보관된 검수 원고가 없습니다. 재작성을 요청해 주세요.');
  END IF;

  UPDATE orbit_n8n.jobs SET
    state = CASE WHEN action IN ('approve', 'retry_execution') THEN 'approved'
      WHEN action = 'reject' THEN 'rejected' ELSE 'queued' END,
    decision_by = actor,
    draft_version = draft_version + CASE WHEN action = 'revise' THEN 1 ELSE 0 END,
    feedback = CASE WHEN action IN ('reject', 'revise') THEN p->>'feedback' ELSE feedback END,
    draft = CASE WHEN action = 'revise' THEN NULL ELSE draft END,
    review = CASE WHEN action = 'revise' THEN NULL ELSE review END,
    attempts = CASE WHEN action = 'revise' THEN 0 ELSE attempts END,
    execution_attempts = CASE WHEN action = 'retry_execution' THEN 0 ELSE execution_attempts END,
    automatic_revisions = CASE WHEN action = 'revise' THEN 0 ELSE automatic_revisions END,
    run_after = now(), updated_at = now(), last_error = NULL, execution_ref = NULL
  WHERE id = target RETURNING * INTO job;

  IF action = 'reject' THEN
    -- The first update records the reviewer's decision and preserves the rejected version in the audit.
    -- The next version must pass review and receive its own approval.
    UPDATE orbit_n8n.jobs SET state = 'queued', draft_version = draft_version + 1,
      feedback = coalesce(nullif(job.feedback, ''), '이전 초안이 반려되었습니다. 요청과 참고 자료를 다시 검토한 뒤 새 초안을 작성하세요.'),
      decision_by = NULL, draft = NULL, review = NULL, attempts = 0, automatic_revisions = 0,
      run_after = now(), updated_at = now(), last_error = NULL, execution_ref = NULL
    WHERE id = target RETURNING * INTO job;
  END IF;

  RETURN jsonb_build_object('statusCode', 200, 'job', orbit_n8n.view_job(job));
END;
$$;

CREATE OR REPLACE FUNCTION orbit_n8n.claim(run_id text) RETURNS SETOF orbit_n8n.jobs
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE orbit_n8n.jobs SET
    state = CASE WHEN state = 'executing' THEN 'execution_uncertain'
      WHEN attempts >= 3 THEN 'generation_failed' ELSE 'queued' END,
    last_error = CASE WHEN state = 'executing' THEN 'external_execution_timed_out' ELSE 'generation_timed_out' END,
    run_after = now(), updated_at = now()
  WHERE state IN ('executing', 'generating') AND updated_at < now() - interval '30 minutes';

  RETURN QUERY
  WITH next_job AS (
    SELECT id FROM orbit_n8n.jobs
    WHERE state IN ('approved', 'queued') AND run_after <= now()
    ORDER BY run_after, created_at, id
    LIMIT 1 FOR UPDATE SKIP LOCKED
  )
  UPDATE orbit_n8n.jobs job SET
    state = CASE WHEN job.state = 'approved' THEN 'executing' ELSE 'generating' END,
    attempts = job.attempts + CASE WHEN job.state = 'queued' THEN 1 ELSE 0 END,
    execution_attempts = job.execution_attempts + CASE WHEN job.state = 'approved' THEN 1 ELSE 0 END,
    execution_ref = run_id, updated_at = now()
  FROM next_job WHERE job.id = next_job.id RETURNING job.*;
END;
$$;

CREATE OR REPLACE FUNCTION orbit_n8n.finish(p jsonb) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  outcome text := p->>'outcome';
  job orbit_n8n.jobs;
BEGIN
  IF outcome = 'pending_approval' AND (
    jsonb_typeof(p->'draft'->'title') IS DISTINCT FROM 'string' OR
    jsonb_typeof(p->'draft'->'body') IS DISTINCT FROM 'string' OR
    NOT coalesce(p->'review' @> '{"passed":true}'::jsonb, false)
  ) THEN
    RETURN false;
  END IF;

  UPDATE orbit_n8n.jobs SET
    state = CASE outcome
      WHEN 'generation_error' THEN CASE WHEN attempts < 3 THEN 'queued' ELSE 'generation_failed' END
      WHEN 'execution_retry' THEN CASE WHEN execution_attempts < 3 THEN 'approved' ELSE 'execution_failed' END
      ELSE outcome END,
    draft = coalesce(p->'draft', draft), review = coalesce(p->'review', review),
    result = coalesce(p->'result', result), last_error = p->>'error', updated_at = now(),
    run_after = CASE
      WHEN outcome = 'generation_error' THEN now() + (attempts * interval '2 minutes')
      WHEN outcome = 'execution_retry' THEN now() + (execution_attempts * interval '2 minutes')
      ELSE run_after END
  WHERE id = (p->>'id')::uuid AND execution_ref = p->>'runId'
    AND ((state = 'generating' AND outcome IN ('pending_approval', 'needs_revision', 'generation_error'))
      OR (state = 'executing' AND outcome IN ('completed', 'execution_uncertain', 'execution_retry', 'execution_failed')))
  RETURNING * INTO job;
  IF NOT FOUND THEN RETURN false; END IF;

  IF outcome = 'pending_approval' THEN
    INSERT INTO orbit_n8n.manuscripts (job_id, version, title, content, approved_payload, review)
    VALUES (job.id, job.draft_version, job.draft->>'title', job.draft->>'body', job.draft, job.review);
  END IF;

  IF outcome = 'needs_revision' AND job.automatic_revisions = 0 AND coalesce((p->>'autoRevise')::boolean, false) THEN
    UPDATE orbit_n8n.jobs SET state = 'queued', draft_version = draft_version + 1,
      attempts = 0, automatic_revisions = 1, decision_by = NULL,
      feedback = concat_ws(E'\n', nullif(feedback, ''), left((p->'review'->'issues')::text, 2500)),
      draft = NULL, review = NULL, run_after = now(), execution_ref = NULL, updated_at = now()
    WHERE id = job.id;
  END IF;
  RETURN true;
END;
$$;

COMMIT;
