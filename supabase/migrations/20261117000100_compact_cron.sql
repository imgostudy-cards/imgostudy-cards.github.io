-- 카드앱 배포판 — 재압축 예약 (5단계 · 2026-11-17)
-- 먼저: 대시보드 → Integrations(또는 Database → Extensions) → pg_cron 켜기. 그다음 이 파일을 SQL Editor에 붙여 넣고 Run.
-- 매주 월요일 04:00 KST(= 일요일 19:00 UTC)에 public.compact_all() — 지난 주들의 작은 묶음을 주 하나로 합친다(20261117000000_compact.sql).
-- 확인: select * from cron.job;  ·  지난 실행: select * from cron.job_run_details order by start_time desc limit 5;
-- 끄기: select cron.unschedule('compact-log-chunks');

create extension if not exists pg_cron;
select cron.schedule('compact-log-chunks', '0 19 * * 0', $$select public.compact_all()$$);
