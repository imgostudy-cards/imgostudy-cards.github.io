-- 카드앱 배포판 — 서버 표 · 접근 규칙 · 함수 (3단계 · 2026-11-16)
-- 적용: Supabase 대시보드 → SQL Editor → New query → 이 파일 전체를 붙여 넣고 Run (한 번).
-- 다시 만들기: 새 프로젝트에 같은 방법으로 붙여 넣는다. 이미 적용된 프로젝트에 두 번 돌리면 「already exists」로 멈춘다(지우고 다시 하려면 맨 끝 주석의 DROP 묶음).
--
-- 표 셋
--   log_chunks  채점 묶음 — 쌓기만 한다(사용자는 select·insert만). 한 행 = 한 기기가 한 번 올린 한 주 분량의 차분
--               body = {"w":"2026-W47","log":[[카드,초,등급,{…}],…],"del":[[카드,초,되돌린때],…]} (text — 큰 값은 Postgres가 압축해 둔다)
--               cid  = 기기가 만든 묶음 id(영수증) — 같은 묶음을 두 번 보내도 한 행만 남는다
--   marks       카드별 마크(은퇴·미룸·태그·일정 조정) — body null = 툼스톤(해제). u(기기 시각 ISO 문자열)가 더 새것일 때만 바뀐다
--               seq = 바뀔 때마다 올라가는 번호 — 기기는 seq 커서 뒤만 받는다
--   profile     사용자당 한 행 — sess(세션·설정 문서 통째) · fb(플래그·주석 문서 통째) · 문서마다 ver(낙관적 잠금)
--               rcpts = 최근 저장 영수증(앱을 닫으며 보낸 저장이 들어갔는지 다음 부팅이 묻는다)
-- 접근 규칙: 세 표 모두 RLS · 자기 행(user_id = auth.uid())만 · 비로그인(anon)은 아무것도 못 한다.

-- ───────────────────────── 표 ─────────────────────────
create table public.log_chunks (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  cid         uuid not null,
  created_at  timestamptz not null default clock_timestamp(),
  n           int not null default 0 check (n >= 0),
  body        text not null check (octet_length(body) <= 2000000),
  unique (user_id, cid)
);
create index log_chunks_user_id_idx on public.log_chunks (user_id, id);

create sequence public.marks_seq;
create table public.marks (
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  card_id     text not null check (length(card_id) <= 200),
  body        jsonb check (body is null or pg_column_size(body) <= 8000),
  u           text not null check (length(u) <= 40),
  seq         bigint not null default 0,
  updated_at  timestamptz not null default clock_timestamp(),
  primary key (user_id, card_id)
);
create index marks_user_seq_idx on public.marks (user_id, seq);

create table public.profile (
  user_id     uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  sess        jsonb check (sess is null or pg_column_size(sess) <= 4000000),
  sess_ver    int not null default 0,
  fb          jsonb check (fb is null or pg_column_size(fb) <= 2000000),
  fb_ver      int not null default 0,
  rcpts       text[] not null default '{}',
  updated_at  timestamptz not null default clock_timestamp()
);

-- marks: 쓸 때마다 seq·updated_at을 서버가 매긴다(기기가 보낸 값은 무시)
create or replace function public.marks_stamp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.seq := nextval('public.marks_seq');
  new.updated_at := clock_timestamp();
  return new;
end $$;
create trigger marks_stamp before insert or update on public.marks
  for each row execute function public.marks_stamp();

-- log_chunks: 사용자당 묶음 수 상한(누구나 가입해 2MB 묶음을 끝없이 넣어 프로젝트 용량을 채우는 것을 막는다)
--   실사용 12주 ≈ 묶음 3천~5천 개(20장·5분마다 한 주 하나) → 5만이면 10년치. 넘으면 insert가 실패한다(기록은 기기에 남는다).
create or replace function public.log_chunks_cap() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if (select count(*) from public.log_chunks where user_id = new.user_id) >= 50000 then
    raise exception 'log_chunks cap' using errcode = '54000';
  end if;
  return new;
end $$;
create trigger log_chunks_cap before insert on public.log_chunks
  for each row execute function public.log_chunks_cap();

-- ───────────────────────── 접근 규칙(RLS) ─────────────────────────
alter table public.log_chunks enable row level security;
alter table public.marks      enable row level security;
alter table public.profile    enable row level security;

create policy log_chunks_select on public.log_chunks for select to authenticated using (user_id = (select auth.uid()));
create policy log_chunks_insert on public.log_chunks for insert to authenticated with check (user_id = (select auth.uid()));
-- log_chunks: update·delete 규칙 없음 = 아무도 못 고치고 못 지운다(탈퇴는 아래 delete_me가 소유자 권한으로)

create policy marks_select on public.marks for select to authenticated using (user_id = (select auth.uid()));
create policy marks_insert on public.marks for insert to authenticated with check (user_id = (select auth.uid()));
create policy marks_update on public.marks for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- marks: delete 규칙 없음 — 해제는 툼스톤(body null)으로 남긴다(다른 기기가 「지워졌다」를 알아야 하므로)

create policy profile_select on public.profile for select to authenticated using (user_id = (select auth.uid()));
create policy profile_insert on public.profile for insert to authenticated with check (user_id = (select auth.uid()));
create policy profile_update on public.profile for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- 권한도 한 겹 더 좁힌다(규칙이 실수로 풀려도 anon은 표에 손을 못 대게) — Supabase 기본값은 anon·authenticated에 전부 열려 있다
revoke all on public.log_chunks, public.marks, public.profile from anon, authenticated;
grant select, insert on public.log_chunks to authenticated;
grant select, insert, update on public.marks, public.profile to authenticated;
revoke all on sequence public.marks_seq from anon, authenticated;

-- ───────────────────────── 함수 (앱이 부르는 것) ─────────────────────────
-- 모두 security invoker(부르는 사람 권한) = 위 RLS가 그대로 걸린다. 예외 = delete_me(탈퇴 · 아래 설명).

-- pull: 커서 뒤만 한 번에 받는다 — 부팅마다 전량 받지 않는다(설계 §4 🔴)
--   p_log_after  마지막으로 받은 log_chunks.id · p_mark_after 마지막으로 받은 marks.seq
--   p_sess_ver/p_fb_ver  기기가 든 문서 판 — 같으면 본문을 안 보낸다(판 번호만)
--   p_docs  받을 것 ('log','marks','sess','fb' 중) · p_limit 묶음 최대 개수(넘으면 기기가 이어서 다시 부른다)
--   p_skip  기기가 이미 가진 내 묶음 id(방금 올린 것) — 다시 보내지 않는다
--   now     서버 시각 · safe = 「이 id까지는 빠짐없이 줬다(받은 것 + p_skip)」 — 10초 넘게 지난 행까지만(동시에 들어온 insert가 늦게 보이는 틈 대비) · 기기는 커서를 safe로 올린다
create or replace function public.pull(p_log_after bigint, p_mark_after bigint, p_sess_ver int, p_fb_ver int, p_docs text[], p_limit int default 500, p_skip bigint[] default '{}')
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t0 timestamptz := clock_timestamp();
  out jsonb := jsonb_build_object('now', t0);
  lim int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  ids bigint[];
  p record;
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if 'log' = any(p_docs) then
    select coalesce(array_agg(id order by id), '{}') into ids from (
      select id from public.log_chunks where user_id = uid and id > p_log_after and not (id = any(coalesce(p_skip, '{}')))
      order by id limit lim) q;
    out := out || jsonb_build_object('chunks', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 't', c.created_at, 'b', c.body::jsonb) order by c.id)
      from public.log_chunks c where c.user_id = uid and c.id = any(ids)), '[]'::jsonb));
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

-- push_chunk: 묶음 한 행 insert. 같은 cid를 또 보내면(응답을 못 받고 다시 보냄) 아무것도 안 하고 기존 id를 준다
create or replace function public.push_chunk(p_cid uuid, p_n int, p_body text)
returns bigint language plpgsql security invoker set search_path = '' as $$
declare v bigint;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  perform p_body::jsonb;   -- 깨진 JSON은 받지 않는다(pull이 본문을 jsonb로 풀어 보낸다)
  insert into public.log_chunks (user_id, cid, n, body) values (auth.uid(), p_cid, p_n, p_body)
    on conflict (user_id, cid) do nothing returning id into v;
  if v is null then select id into v from public.log_chunks where user_id = auth.uid() and cid = p_cid; end if;
  return v;
end $$;

-- put_marks: [{c:카드, b:본문|null, u:시각}, …] — u가 더 새것일 때만 바꾼다. 돌려주는 것 = 그 카드들의 지금 서버 값
create or replace function public.put_marks(p_rows jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  insert into public.marks (user_id, card_id, body, u)
    select uid, r->>'c', case when jsonb_typeof(r->'b') = 'object' then r->'b' else null end, r->>'u'
    from jsonb_array_elements(p_rows) r
  on conflict (user_id, card_id) do update set body = excluded.body, u = excluded.u
    where public.marks.u < excluded.u;
  return coalesce((select jsonb_agg(jsonb_build_object('c', m.card_id, 'b', m.body, 'u', m.u, 's', m.seq, 't', m.updated_at) order by m.seq)
    from public.marks m where m.user_id = uid and m.card_id in (select r->>'c' from jsonb_array_elements(p_rows) r)), '[]'::jsonb);
end $$;

-- save_doc: 'sess' 또는 'fb' 문서 통째 저장 · p_ver = 기기가 든 판. 서버 판과 같을 때만 쓰고 새 판을 준다 · 어긋나면 -1(기기는 받아 합친 뒤 다시)
create or replace function public.save_doc(p_doc text, p_body jsonb, p_ver int, p_rcpt text default null)
returns int language plpgsql security invoker set search_path = '' as $$
declare uid uuid := auth.uid(); v int;
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if p_doc not in ('sess', 'fb') then raise exception 'bad doc %', p_doc; end if;
  insert into public.profile (user_id) values (uid) on conflict (user_id) do nothing;
  if p_doc = 'sess' then
    update public.profile set sess = p_body, sess_ver = sess_ver + 1, updated_at = clock_timestamp(),
      rcpts = case when p_rcpt is null then rcpts else (array_append(rcpts, p_rcpt))[greatest(1, cardinality(rcpts) - 17):] end
      where user_id = uid and sess_ver = p_ver returning sess_ver into v;
  else
    update public.profile set fb = p_body, fb_ver = fb_ver + 1, updated_at = clock_timestamp(),
      rcpts = case when p_rcpt is null then rcpts else (array_append(rcpts, p_rcpt))[greatest(1, cardinality(rcpts) - 17):] end
      where user_id = uid and fb_ver = p_ver returning fb_ver into v;
  end if;
  return coalesce(v, -1);
end $$;

-- landed: 그 영수증의 저장이 들어갔나(최근 19건 안에서)
create or replace function public.landed(p_rcpt text)
returns boolean language sql security invoker set search_path = '' as $$
  select coalesce((select p_rcpt = any(rcpts) from public.profile where user_id = auth.uid()), false);
$$;

-- my_sizes: 내 행 크기(운영·실측용 — 자기 것만 본다)
create or replace function public.my_sizes()
returns jsonb language sql security invoker set search_path = '' as $$
  select jsonb_build_object(
    'chunks', (select count(*) from public.log_chunks where user_id = auth.uid()),
    'entries', (select coalesce(sum(n), 0) from public.log_chunks where user_id = auth.uid()),
    'chunk_text_bytes', (select coalesce(sum(octet_length(body)), 0) from public.log_chunks where user_id = auth.uid()),
    'chunk_stored_bytes', (select coalesce(sum(pg_column_size(body)), 0) from public.log_chunks where user_id = auth.uid()),
    'chunk_row_bytes', (select coalesce(sum(pg_column_size(c.*)), 0) from public.log_chunks c where user_id = auth.uid()),
    'marks', (select count(*) from public.marks where user_id = auth.uid()),
    'marks_row_bytes', (select coalesce(sum(pg_column_size(m.*)), 0) from public.marks m where user_id = auth.uid()),
    'profile_row_bytes', (select coalesce(sum(pg_column_size(p.*)), 0) from public.profile p where user_id = auth.uid()));
$$;

-- delete_me: 탈퇴 — 세 표의 내 행 + 내 계정(auth.users)을 지운다.
-- security definer(이 함수를 만든 postgres 권한으로 돈다): 사용자는 auth.users를 못 지우므로. 지우는 대상은 auth.uid() 하나로 묶여 있다.
-- 🔶 공식 문서는 「계정 삭제 = auth.admin.deleteUser(service_role)」만 적는다 — DB 함수로 auth.users를 지우는 것은 널리 쓰는 방법이지만
--    공식 안내는 아니다. 실제 프로젝트에서 시험해 안 되면 Edge Function으로 바꾼다.
create or replace function public.delete_me()
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  delete from public.log_chunks where user_id = uid;
  delete from public.marks where user_id = uid;
  delete from public.profile where user_id = uid;
  delete from auth.users where id = uid;
end $$;

-- 함수 실행 권한: 로그인한 사용자만(Supabase 기본값은 public 전체에 실행 권한)
revoke execute on function public.pull(bigint, bigint, int, int, text[], int, bigint[]), public.push_chunk(uuid, int, text), public.put_marks(jsonb),
  public.save_doc(text, jsonb, int, text), public.landed(text), public.my_sizes(), public.delete_me(), public.marks_stamp(), public.log_chunks_cap() from public, anon;
grant execute on function public.pull(bigint, bigint, int, int, text[], int, bigint[]), public.push_chunk(uuid, int, text), public.put_marks(jsonb),
  public.save_doc(text, jsonb, int, text), public.landed(text), public.my_sizes(), public.delete_me() to authenticated;

-- (지우고 다시 만들 때만 — 데이터가 전부 사라진다)
-- drop function if exists public.pull(bigint, bigint, int, int, text[], int, bigint[]), public.push_chunk(uuid, int, text), public.put_marks(jsonb),
--   public.save_doc(text, jsonb, int, text), public.landed(text), public.my_sizes(), public.delete_me();
-- drop table if exists public.log_chunks, public.marks, public.profile; drop function if exists public.marks_stamp(), public.log_chunks_cap(); drop sequence if exists public.marks_seq;
