-- 배포판 6단계 — 사용자당 용량 상한 · pull 한 번 크기 상한 (독립 감사 6단계 1-1 · 2-3)
-- 적용 = 대시보드 SQL Editor에 이 파일 전체를 붙여 넣고 Run(운영자). 20261116000000_init.sql · 20261117000000_compact.sql 뒤에.
-- 🔴 차례: 이 SQL을 먼저 붙이고 앱(6단계 판)을 올린다 — 앱은 p_base를 모르는 옛 pull이면 한 번 없이 다시 부르지만(404·400), 이 SQL이 먼저면 그 갈래가 안 쓰인다.
-- 무엇을 막나: 가입만 하면 2MB 묶음 × 5만 개(이론상 100GB)·마크 무제한·영수증 무제한으로 무료 DB(500MB) 전체를 채워 모든 사용자의 저장을 멈출 수 있었다.
--   pull은 p_limit(최대 2000) × 2MB 본문을 한 jsonb로 모아 응답 하나가 수 GB가 될 수 있었다.
-- 바꾸는 것:
--   ① 묶음 한 행 1MB(앱 실사용 묶음 ≈ 1KB · 한 주 통째 업로드도 실사용 최대 주 ≈ 0.3MB) — 새 행부터(not valid)
--   ② 사용자당 묶음 글 합 30MB(실사용 40주 ≈ 10MB) + 묶음 수 5만(그대로)
--   ③ 마크: card_id 64자(실제 16자) · 본문 2KB(실측 장당 ≈ 160B) · 사용자당 3만 행(덱 1.5만 장 + 바뀐 ID 몫)
--   ④ 영수증(rcpts) 20개·합 2KB
--   ⑤ 재압축이 합친 묶음도 ①을 지키게(1.9MB → 0.95MB 넘으면 그 주는 그대로)
--   ⑥ pull 한 번의 묶음 본문 합 5MB 근처에서 끊고 'more':true — 앱은 'more'면 이어 받는다(옛 앱은 다음 받기에서 이어짐 · safe가 끊은 자리까지만이라 소실 없음)
-- 되돌리기: 맨 끝 주석.

-- ① ③ ④ 크기 check (옛 행은 안 봄)
alter table public.log_chunks drop constraint if exists log_chunks_body_1mb;   -- (다시 붙여 넣어도 되게)
alter table public.marks drop constraint if exists marks_card_id_64;
alter table public.marks drop constraint if exists marks_body_2k;
alter table public.profile drop constraint if exists profile_rcpts_small;
alter table public.log_chunks add constraint log_chunks_body_1mb check (octet_length(body) <= 1000000) not valid;
alter table public.marks add constraint marks_card_id_64 check (length(card_id) <= 64) not valid;
alter table public.marks add constraint marks_body_2k check (body is null or pg_column_size(body) <= 2000) not valid;
alter table public.profile add constraint profile_rcpts_small check (cardinality(rcpts) <= 20 and octet_length(array_to_string(rcpts, '')) <= 2000) not valid;

-- ② 사용자당 묶음 수 + 글 합
create or replace function public.log_chunks_cap() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare k bigint; b bigint;
begin
  if new.src_max is not null then return new; end if;   -- 재압축이 넣는 합친 행은 면제(재검 O5 — 합친 본문이 조금 커져 상한 근처 사용자의 재압축이 매주 실패했다 · 사용자는 src_max를 못 넣는다: 열 단위 insert 권한)
  if exists (select 1 from public.log_chunks where user_id = new.user_id and cid = new.cid) then return new; end if;   -- 같은 cid 다시 보냄(응답 유실) = 이미 센 것(재검 O6 · on conflict가 뒤에서 거른다)
  select count(*), coalesce(sum(octet_length(body)), 0) into k, b from public.log_chunks where user_id = new.user_id;
  if k >= 50000 or b + octet_length(new.body) > 30000000 then
    raise exception 'log_chunks cap' using errcode = '54000';
  end if;
  return new;
end $$;

-- ③ 사용자당 마크 행 수 — 문장 하나에 한 번만 센다(AFTER · 새로 들어간 행 표) — 행마다 세면 한 번에 1.5만 장 올리는 백업 가져오기가 느려지고,
--    BEFORE INSERT는 put_marks의 on conflict(있는 행 고치기)에도 불려 상한에 닿은 사용자가 고치지도 못했다.
create or replace function public.marks_cap() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if exists (select 1 from (select distinct n.user_id from nt n) u
             where (select count(*) from public.marks m where m.user_id = u.user_id) > 30000) then
    raise exception 'marks cap' using errcode = '54000';
  end if;
  return null;
end $$;
drop trigger if exists marks_cap on public.marks;
create trigger marks_cap after insert on public.marks referencing new table as nt for each statement execute function public.marks_cap();

-- ⑤ compact_user — 20261117000000_compact.sql과 같고 상한만 1900000 → 950000
create or replace function public.compact_user(p_uid uuid, p_min_age interval default interval '1 day')
returns int language plpgsql security definer set search_path = '' as $$
declare
  t_cut timestamptz; cur_w text;
  wk text; ids bigint[]; mx bigint; lg jsonb; dl jsonb; txt text; removed int := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended('log_chunks_compact:' || p_uid::text, 0));
  t_cut := clock_timestamp() - p_min_age;
  cur_w := to_char(clock_timestamp() at time zone 'Asia/Seoul', 'IYYY-"W"IW');
  for wk in
    select q.w from (select (c.body::jsonb)->>'w' as w, c.src_max from public.log_chunks c where c.user_id = p_uid and c.created_at < t_cut) q
    where q.w is not null and q.w < cur_w group by q.w
    having count(*) >= 2 and count(*) filter (where q.src_max is null) >= 1 order by q.w
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
    if octet_length(txt) > 950000 then continue; end if;   -- (6단계) 묶음 상한 1MB(①) 밑으로 — 넘으면 그 주는 그대로
    delete from public.log_chunks where user_id = p_uid and id = any(ids);
    insert into public.log_chunks (user_id, cid, n, body, src_max) values (p_uid, gen_random_uuid(), jsonb_array_length(lg), txt, mx);
    removed := removed + cardinality(ids) - 1;
  end loop;
  return removed;
end $$;

-- ⑥ pull — 20261117000000_compact.sql과 같고 ⓐ 로그 고르기에 「본문 누적 5MB」 끊기 · 'more' ⓑ 합친 묶음 거르기를 기기의 확정 커서(p_base)로
--   🔴 (재검 R1) 예전엔 src_max > p_log_after(이어 받는 중의 커서)로 걸러, 한 회차에 합친 묶음 XA·XB(id 이웃 · XB.src_max < XA.id)를 나눠 받으면
--      둘째 받기가 XB를 거르고 safe는 XB를 지나가 그 주가 그 기기에 영영 안 왔다(옛 행 수 끊기에도 있던 구멍 · 5MB 끊기로 거의 반드시).
--      p_base = 받기를 시작할 때의 확정 커서(이 id까지 기기 거울이 서버와 같다) — 그보다 src_max가 크면 그 기기가 원본 일부를 못 가졌으니 보낸다.
--      p_base가 없으면(옛 앱) p_log_after — 옛 동작 그대로.
drop function if exists public.pull(bigint, bigint, int, int, text[], int, bigint[]);
create or replace function public.pull(p_log_after bigint, p_mark_after bigint, p_sess_ver int, p_fb_ver int, p_docs text[], p_limit int default 500, p_skip bigint[] default '{}', p_base bigint default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t0 timestamptz := clock_timestamp();
  out jsonb := jsonb_build_object('now', t0);
  lim int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  ids bigint[];
  chs jsonb;
  cut boolean;
  nsel int;
  more boolean;
  p record;
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if 'log' = any(p_docs) then
    -- 🔴 고를 행과 보낼 본문을 한 문장(한 스냅숏)에서(5단계 재검 ①) · 앞에서부터 본문 누적이 5MB를 넘기 전까지(첫 행은 늘 담음 → 앞으로 나아간다)
    select coalesce(array_agg(q.id order by q.id) filter (where q.keep), '{}'),
           coalesce(jsonb_agg(jsonb_build_object('id', q.id, 't', q.created_at, 'b', q.body::jsonb) order by q.id) filter (where q.keep), '[]'::jsonb),
           coalesce(bool_or(not q.keep), false), count(*)
      into ids, chs, cut, nsel from (
      select r.id, r.created_at, r.body, (p_base is null or (sum(octet_length(r.body)) over (order by r.id) - octet_length(r.body)) < 5000000) as keep   -- 옛 앱(p_base 없음)엔 바이트 끊기를 안 건다(재검 — 옛 앱은 나눠 받기에서 R1 길)
        from (select id, created_at, body from public.log_chunks where user_id = uid and id > p_log_after and not (id = any(coalesce(p_skip, '{}')))
                and (src_max is null or src_max > coalesce(p_base, p_log_after))
              order by id limit lim) r) q;
    more := cut or nsel >= lim;   -- 더 있을 수 있다 = 바이트로 끊었거나 행 수로 끊었다
    out := out || jsonb_build_object('chunks', chs, 'more', more);
    out := out || jsonb_build_object('safe', (
      select max(id) from public.log_chunks where user_id = uid and id > p_log_after
        and (not more or id <= ids[cardinality(ids)])
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

-- 권한(create or replace는 기존 권한을 그대로 둔다 — 재확인만)
revoke execute on function public.compact_user(uuid, interval) from public, anon, authenticated;
revoke execute on function public.pull(bigint, bigint, int, int, text[], int, bigint[], bigint) from public, anon;
grant execute on function public.pull(bigint, bigint, int, int, text[], int, bigint[], bigint) to authenticated;

-- 확인(SQL Editor):
--   select conname from pg_constraint where conname in ('log_chunks_body_1mb','marks_card_id_64','marks_body_2k','profile_rcpts_small');   → 4줄
--   select tgname from pg_trigger where tgname in ('log_chunks_cap','marks_cap');                                                       → 2줄
-- 되돌리기:
--   alter table public.log_chunks drop constraint log_chunks_body_1mb; alter table public.marks drop constraint marks_card_id_64, drop constraint marks_body_2k;
--   alter table public.profile drop constraint profile_rcpts_small; drop trigger marks_cap on public.marks; drop function public.marks_cap();
--   drop function public.pull(bigint, bigint, int, int, text[], int, bigint[], bigint);
--   그리고 20261116000000_init.sql의 log_chunks_cap · 20261117000000_compact.sql의 compact_user·pull(과 그 권한 두 줄)을 다시 붙여 넣는다.
