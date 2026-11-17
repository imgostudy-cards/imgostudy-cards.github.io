-- 카드앱 배포판 — 채점 묶음 재압축 (5단계 · 2026-11-17 · 서버가 매주 자동)
-- 적용: 대시보드 → SQL Editor → 이 파일 전체를 붙여 넣고 Run (한 번 · 20261116000000_init.sql 다음).
--       예약(매주 자동)은 다음 파일 20261117000100_compact_cron.sql — pg_cron 확장을 먼저 켠다.
--
-- 왜: 앱은 20장·5분마다 한 주 분량 차분을 「작은 묶음」 한 행으로 올린다(≈1KB). Postgres는 2KB 미만 값을 압축하지 않아
--     실사용 저장이 채점 건당 ≈50B다. 한 주를 한 행으로 모으면 압축이 걸려 ≈26B(3단계 실측 my_sizes). → 무료 500MB에 두 배.
-- 무엇을: 한 사용자 · 한 주(body.w)의 「1일 넘게 지난」 묶음이 둘 이상이면 → 한 트랜잭션에서 그 행들을 지우고
--         내용(log·del 각각 똑같은 원소만 한 번 · 차례 = 원래 id 순 → 원소 순)을 담은 묶음 한 행을 **새 id**로 넣는다.
--         새 행의 src_max = 지운 행 중 가장 큰 id.
-- 왜 안전한가(기기 쪽 규칙 · 앱 코드 무변):
--   ① 기기는 받은 묶음을 주별 (카드|시각) 합집합으로 거울에 넣는다 → 합친 묶음을 다시 받아도 무해(중복 안 생김).
--   ② 지우기와 넣기가 한 트랜잭션 → 어느 순간에 받아도 「옛 행들」이나 「합친 행」 둘 중 하나가 보인다(둘 다 없는 때 없음).
--   ③ 새 id라 기기가 p_skip(방금 올린 내 묶음 id)로 거르는 일이 없다 — 옛 id를 다시 쓰면 그 기기가 남이 올린 몫까지 놓친다.
--   ④ 기기 커서(p_log_after) ≥ src_max면 그 기기는 지운 행을 전부 이미 가졌다(커서 = 「거울이 여기까지 서버와 같다」) →
--      pull이 그 합친 행을 안 보낸다(전송 0). 커서 < src_max면 보낸다(합집합). safe 계산은 그대로(건너뛴 행도 「줬다」로 친다).
--   ⑤ 커서보다 작은 id가 사라져도 무해 — 그 내용은 기기에 이미 있다. 커서보다 큰 id가 사라지면 합친 행(id 더 큼 · src_max > 커서)이 대신 간다.
--   ⑥ 대상은 1일 넘은 행뿐 — 10초 안전 커서 틈(늦게 커밋되는 insert)과 겹치지 않는다. 늦게 들어온 지난 주 묶음은 다음 회차에 또 합친다.
-- 규칙 바뀜: log_chunks는 「쌓기만」이었다 → 사용자는 여전히 select·insert만. 지우기는 이 함수(security definer · 사용자는 못 부름)만.

alter table public.log_chunks add column if not exists src_max bigint;   -- 합친 묶음만: 지운 옛 행 중 가장 큰 id(보통 행은 null)
-- (독립 재검 ②) 사용자가 표에 직접 POST해 src_max·created_at을 쓰거나 깨진 JSON을 넣지 못하게 — 앱(push_chunk)이 쓰는 열만 · 본문은 JSON이어야
revoke insert on public.log_chunks from authenticated;
grant insert (user_id, cid, n, body) on public.log_chunks to authenticated;
alter table public.log_chunks add constraint log_chunks_body_json check ((body::jsonb) is not null) not valid;   -- 새 행부터(옛 행은 재압축이 사용자별로 걸러 넘김)

-- compact_user: 한 사용자 재압축 · 돌려줌 = 줄어든 행 수
create or replace function public.compact_user(p_uid uuid, p_min_age interval default interval '1 day')
returns int language plpgsql security definer set search_path = '' as $$
declare
  t_cut timestamptz; cur_w text;
  wk text; ids bigint[]; mx bigint; lg jsonb; dl jsonb; txt text; removed int := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended('log_chunks_compact:' || p_uid::text, 0));   -- 같은 사용자 둘이 겹쳐 돌지 않게
  t_cut := clock_timestamp() - p_min_age;                                                     -- 잠금을 잡은 뒤에 잰다(독립 재검 ⑤)
  cur_w := to_char(clock_timestamp() at time zone 'Asia/Seoul', 'IYYY-"W"IW');                -- 이번 주(KST)는 안 건드린다
  for wk in
    select q.w from (select (c.body::jsonb)->>'w' as w, c.src_max from public.log_chunks c where c.user_id = p_uid and c.created_at < t_cut) q
    where q.w is not null and q.w < cur_w group by q.w
    having count(*) >= 2 and count(*) filter (where q.src_max is null) >= 1 order by q.w   -- 이미 합친 주(합친 행 하나뿐)는 다시 안 건드린다(독립 재검 ③)
  loop
    select array_agg(c.id order by c.id), max(c.id) into ids, mx
      from public.log_chunks c where c.user_id = p_uid and c.created_at < t_cut and (c.body::jsonb)->>'w' = wk;
    select coalesce(jsonb_agg(d.e order by d.ci, d.ord), '[]'::jsonb) into lg from (
      select distinct on (s.e) s.e, s.ci, s.ord from (
        select x.e, c.id as ci, x.ord from public.log_chunks c
          cross join lateral jsonb_array_elements(case when jsonb_typeof((c.body::jsonb)->'log') = 'array' then (c.body::jsonb)->'log' else '[]'::jsonb end) with ordinality as x(e, ord)
          where c.id = any(ids)) s
      order by s.e, s.ci, s.ord) d;
    select coalesce(jsonb_agg(d.e order by d.ci, d.ord), '[]'::jsonb) into dl from (
      select distinct on (s.e) s.e, s.ci, s.ord from (
        select x.e, c.id as ci, x.ord from public.log_chunks c
          cross join lateral jsonb_array_elements(case when jsonb_typeof((c.body::jsonb)->'del') = 'array' then (c.body::jsonb)->'del' else '[]'::jsonb end) with ordinality as x(e, ord)
          where c.id = any(ids)) s
      order by s.e, s.ci, s.ord) d;
    txt := (jsonb_build_object('w', wk, 'log', lg) || case when jsonb_array_length(dl) > 0 then jsonb_build_object('del', dl) else '{}'::jsonb end)::text;
    if octet_length(txt) > 1900000 then continue; end if;   -- 묶음 상한(2MB) 근처면 그 주는 그대로 둔다
    delete from public.log_chunks where user_id = p_uid and id = any(ids);
    insert into public.log_chunks (user_id, cid, n, body, src_max) values (p_uid, gen_random_uuid(), jsonb_array_length(lg), txt, mx);
    removed := removed + cardinality(ids) - 1;
  end loop;
  return removed;
end $$;

-- compact_all: 전 사용자(예약 작업·운영자 손이 부른다) · 돌려줌 = {users, removed_rows}
create or replace function public.compact_all(p_min_age interval default interval '1 day')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u uuid; n int; users int := 0; removed int := 0; failed int := 0;
begin
  for u in select c.user_id from public.log_chunks c where c.created_at < clock_timestamp() - p_min_age
           group by c.user_id having count(*) >= 2 and count(*) filter (where c.src_max is null) >= 1 order by c.user_id loop   -- 순서 고정 = 두 회차가 겹쳐도 교착 없음(독립 재검 ④)
    begin                                       -- 사용자마다 따로(하위 트랜잭션) — 한 사람의 깨진 행이 전원 몫을 되돌리지 않게(독립 재검 ②)
      n := public.compact_user(u, p_min_age);
      if n > 0 then users := users + 1; removed := removed + n; end if;
    exception when others then
      failed := failed + 1; raise warning 'compact_user % 실패: %', u, sqlerrm;
    end;
  end loop;
  return jsonb_build_object('users', users, 'removed_rows', removed, 'failed', failed);
end $$;

-- pull: 20261116000000_init.sql과 같고 둘이 다르다 — 합친 묶음은 src_max > p_log_after일 때만 보낸다(위 ④) · 고르기와 본문을 한 문장에서(아래 🔴)
create or replace function public.pull(p_log_after bigint, p_mark_after bigint, p_sess_ver int, p_fb_ver int, p_docs text[], p_limit int default 500, p_skip bigint[] default '{}')
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t0 timestamptz := clock_timestamp();
  out jsonb := jsonb_build_object('now', t0);
  lim int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  ids bigint[];
  chs jsonb;
  p record;
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if 'log' = any(p_docs) then
    -- 🔴 (독립 재검 ①) 고를 행과 보낼 본문을 **한 문장**(한 스냅숏)에서 — 따로 두면 그 사이에 재압축이 커밋될 때
    --    「고른 원본은 지워져 안 가고 · 합친 행은 다음부터 src_max로 걸러져」 그 기기가 남의 기록을 영영 못 받는다.
    select coalesce(array_agg(q.id order by q.id), '{}'),
           coalesce(jsonb_agg(jsonb_build_object('id', q.id, 't', q.created_at, 'b', q.body::jsonb) order by q.id), '[]'::jsonb)
      into ids, chs from (
      select id, created_at, body from public.log_chunks where user_id = uid and id > p_log_after and not (id = any(coalesce(p_skip, '{}')))
        and (src_max is null or src_max > p_log_after)
      order by id limit lim) q;
    out := out || jsonb_build_object('chunks', chs);
    out := out || jsonb_build_object('safe', (
      select max(id) from public.log_chunks where user_id = uid and id > p_log_after
        and (cardinality(ids) < lim or id <= ids[cardinality(ids)])
        and created_at <= t0 - interval '10 seconds'));
  end if;
  if 'marks' = any(p_docs) then
    out := out || jsonb_build_object('marks', coalesce((
      select jsonb_agg(jsonb_build_object('c', m.card_id, 'b', m.body, 'u', m.u, 's', m.seq, 't', m.updated_at) order by m.seq)
      from public.marks m where m.user_id = uid and m.seq > p_mark_after), '[]'::jsonb));
  end if;
  if 'sess' = any(p_docs) or 'fb' = any(p_docs) then
    select sess, sess_ver, fb, fb_ver into p from public.profile where user_id = uid;
    if found then
      if 'sess' = any(p_docs) then
        out := out || jsonb_build_object('sess', case when p.sess_ver <> p_sess_ver then jsonb_build_object('ver', p.sess_ver, 'body', p.sess) else jsonb_build_object('ver', p.sess_ver) end);
      end if;
      if 'fb' = any(p_docs) then
        out := out || jsonb_build_object('fb', case when p.fb_ver <> p_fb_ver then jsonb_build_object('ver', p.fb_ver, 'body', p.fb) else jsonb_build_object('ver', p.fb_ver) end);
      end if;
    else
      out := out || jsonb_build_object('sess', jsonb_build_object('ver', 0), 'fb', jsonb_build_object('ver', 0));
    end if;
  end if;
  return out;
end $$;

-- my_sizes: 합친 묶음 수를 더함(재압축 전·후 실측용)
create or replace function public.my_sizes()
returns jsonb language sql security invoker set search_path = '' as $$
  select jsonb_build_object(
    'chunks', (select count(*) from public.log_chunks where user_id = auth.uid()),
    'compacted', (select count(*) from public.log_chunks where user_id = auth.uid() and src_max is not null),
    'entries', (select coalesce(sum(n), 0) from public.log_chunks where user_id = auth.uid()),
    'chunk_text_bytes', (select coalesce(sum(octet_length(body)), 0) from public.log_chunks where user_id = auth.uid()),
    'chunk_stored_bytes', (select coalesce(sum(pg_column_size(body)), 0) from public.log_chunks where user_id = auth.uid()),
    'chunk_row_bytes', (select coalesce(sum(pg_column_size(c.*)), 0) from public.log_chunks c where user_id = auth.uid()),
    'marks', (select count(*) from public.marks where user_id = auth.uid()),
    'marks_row_bytes', (select coalesce(sum(pg_column_size(m.*)), 0) from public.marks m where user_id = auth.uid()),
    'profile_row_bytes', (select coalesce(sum(pg_column_size(p.*)), 0) from public.profile p where user_id = auth.uid()));
$$;

-- 권한: 재압축 함수는 아무도 못 부른다(예약 작업·SQL 편집기 = 소유자 권한으로만). pull·my_sizes는 그대로 로그인한 사용자만.
revoke execute on function public.compact_user(uuid, interval), public.compact_all(interval) from public, anon, authenticated;
revoke execute on function public.pull(bigint, bigint, int, int, text[], int, bigint[]), public.my_sizes() from public, anon;
grant execute on function public.pull(bigint, bigint, int, int, text[], int, bigint[]), public.my_sizes() to authenticated;

-- 손으로 돌리기(운영자 · SQL 편집기): select public.compact_all();          → {"users": n, "removed_rows": m, "failed": 0}
-- 되돌리기(이 파일 걷기): 합친 행은 보통 행과 같은 꼴이라 그대로 두어도 된다 — 함수만 걷으려면
--   drop function if exists public.compact_all(interval), public.compact_user(uuid, interval);
--   그리고 20261116000000_init.sql의 pull을 다시 붙여 넣는다(src_max 열·열 단위 insert 권한·JSON 검사는 남겨도 무해).
