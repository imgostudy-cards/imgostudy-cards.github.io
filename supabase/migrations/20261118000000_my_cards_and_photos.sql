-- 배포판 8단계 — 「내 카드」(사용자가 만든 카드) 표 + 사진 보관함(Storage 비공개 버킷)
-- 적용 = 대시보드 SQL Editor에 이 파일 전체를 붙여 넣고 Run(운영자). 앞 SQL 넷(init · compact · compact_cron · quota) 뒤에.
-- 🔴 차례: 이 SQL을 먼저 붙이고 앱(8단계 판)을 올린다. 앱은 이 SQL이 없으면 내 카드 연동만 끄고(기기에만 저장) 나머지는 그대로 돈다.
-- 🔴 덧붙이기만 한다 — 기존 표(log_chunks · marks · profile)와 함수(pull · push_chunk · put_marks · save_doc · landed · my_sizes · delete_me)는 안 건드린다.
--    옛 판 앱은 이 표·버킷을 부르지 않으므로 영향 없음. 탈퇴(delete_me)는 auth.users를 지우면 아래 표가 on delete cascade로 같이 지워진다(함수 무변).
-- 무엇을 만드나:
--   ① user_cards 표 — 카드 한 장 = 한 행(본문 jsonb · 지운 카드 = 본문 null 「툼스톤」 · 고친 시각 u) · 자기 행만(RLS)
--   ② put_ucards / pull_ucards 함수 — 고친 시각이 더 새것만 들어감 · 지운 카드는 다시 안 살아남(「지우기가 이김」)
--   ③ 상한 — 사용자당 살아 있는 카드 3,000 · 행 10,000(툼스톤 포함) · 한 장 16KB · 카드 id 꼴
--   ④ 사진 버킷 ucard(비공개 · 장당 300KB · JPEG만) + 접근 규칙: 자기 폴더(<사용자 id>/)만 읽기·올리기·지우기 · 덮어쓰기 없음 · 사용자당 120개
--      (앱은 카드가 가리키는 사진 100장에서 막는다 · 120 = 바꾼 사진을 이틀 뒤 치우기 전까지의 여유)
-- 되돌리기: 맨 끝 주석.

-- ① 표
create sequence if not exists public.user_cards_seq;
create table if not exists public.user_cards (
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  card_id     text not null check (card_id ~ '^u[0-9a-f]{15}$'),
  body        jsonb check (body is null or (jsonb_typeof(body) = 'object' and pg_column_size(body) <= 16000)),
  u           text not null check (u ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,6})?Z$'),
  seq         bigint not null default 0,
  updated_at  timestamptz not null default clock_timestamp(),
  primary key (user_id, card_id)
);
create index if not exists user_cards_user_seq_idx on public.user_cards (user_id, seq);

-- 쓸 때마다 seq·updated_at을 서버가 매긴다(marks_stamp와 같은 뜻)
create or replace function public.user_cards_stamp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.seq := nextval('public.user_cards_seq');
  new.updated_at := clock_timestamp();
  return new;
end $$;
drop trigger if exists user_cards_stamp on public.user_cards;
create trigger user_cards_stamp before insert or update on public.user_cards
  for each row execute function public.user_cards_stamp();

-- ③ 사용자당 상한 — 문장 하나에 한 번(marks_cap과 같은 꼴) · 넘으면 54000(앱 띠 「서버 저장 한도 초과」)
create or replace function public.user_cards_cap() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if exists (select 1 from (select distinct n.user_id from nt n) u
             where (select count(*) from public.user_cards c where c.user_id = u.user_id) > 10000
                or (select count(*) from public.user_cards c where c.user_id = u.user_id and c.body is not null) > 3000) then
    raise exception 'user_cards cap' using errcode = '54000';
  end if;
  return null;
end $$;
drop trigger if exists user_cards_cap_ins on public.user_cards;
drop trigger if exists user_cards_cap_upd on public.user_cards;
create trigger user_cards_cap_ins after insert on public.user_cards referencing new table as nt for each statement execute function public.user_cards_cap();
create trigger user_cards_cap_upd after update on public.user_cards referencing new table as nt for each statement execute function public.user_cards_cap();

-- 접근 규칙: 자기 행만 · 지우기 없음(지우기 = 툼스톤)
alter table public.user_cards enable row level security;
drop policy if exists user_cards_select on public.user_cards;
drop policy if exists user_cards_insert on public.user_cards;
drop policy if exists user_cards_update on public.user_cards;
create policy user_cards_select on public.user_cards for select to authenticated using (user_id = (select auth.uid()));
create policy user_cards_insert on public.user_cards for insert to authenticated with check (user_id = (select auth.uid()));
create policy user_cards_update on public.user_cards for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.user_cards from anon, authenticated;
grant select, insert, update on public.user_cards to authenticated;
revoke all on sequence public.user_cards_seq from anon, authenticated;

-- ② put_ucards: [{c:카드, b:본문|null(지움), u:고친 시각}, …]
--   · 서버 행이 살아 있고 (보낸 것이 툼스톤이거나 u가 더 새것)일 때만 바뀐다 → 툼스톤은 늘 들어가고, 툼스톤 행은 다시 안 바뀐다
--   · 기기 시계가 앞서 있어도 내일 이후 시각은 지금+1일로 깎는다(한 기기의 앞선 시계가 영영 이기지 않게)
--   · 돌려줌 = 그 카드들의 지금 서버 값(앱이 진 것을 서버 값으로 맞춘다)
create or replace function public.put_ucards(p_rows jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare uid uuid := auth.uid();
        cap text := to_char((now() at time zone 'utc') + interval '1 day', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 500 then raise exception 'bad rows' using errcode = '22023'; end if;
  insert into public.user_cards (user_id, card_id, body, u)
    select uid, r->>'c', case when jsonb_typeof(r->'b') = 'object' then r->'b' else null end, least(r->>'u', cap)
    from jsonb_array_elements(p_rows) r
  on conflict (user_id, card_id) do update set body = excluded.body, u = excluded.u
    where public.user_cards.body is not null and (excluded.body is null or public.user_cards.u < excluded.u);
  return coalesce((select jsonb_agg(jsonb_build_object('c', c.card_id, 'b', c.body, 'u', c.u, 's', c.seq, 't', c.updated_at) order by c.seq)
    from public.user_cards c where c.user_id = uid and c.card_id in (select r->>'c' from jsonb_array_elements(p_rows) r)), '[]'::jsonb);
end $$;

-- pull_ucards: 커서(seq) 뒤 행 — 한 번에 p_limit(최대 1000)행 · 넘으면 more
create or replace function public.pull_ucards(p_after bigint, p_limit int default 500)
returns jsonb language sql security invoker set search_path = '' as $$
  with r as (
    select c.card_id, c.body, c.u, c.seq, c.updated_at from public.user_cards c
    where c.user_id = auth.uid() and c.seq > coalesce(p_after, 0)
    order by c.seq limit greatest(1, least(coalesce(p_limit, 500), 1000)) + 1)
  select jsonb_build_object(
    'now', clock_timestamp(),
    'more', (select count(*) from r) > greatest(1, least(coalesce(p_limit, 500), 1000)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('c', x.card_id, 'b', x.body, 'u', x.u, 's', x.seq, 't', x.updated_at) order by x.seq)
                      from (select * from r order by seq limit greatest(1, least(coalesce(p_limit, 500), 1000))) x), '[]'::jsonb));
$$;

-- 운영·실측용(자기 것만): 카드 수·본문 바이트·사진 수·사진 바이트
create or replace function public.ucard_sizes()
returns jsonb language sql security definer set search_path = '' as $$
  select jsonb_build_object(
    'cards', (select count(*) from public.user_cards where user_id = auth.uid() and body is not null),
    'tombstones', (select count(*) from public.user_cards where user_id = auth.uid() and body is null),
    'row_bytes', (select coalesce(sum(pg_column_size(c.*)), 0) from public.user_cards c where user_id = auth.uid()),
    'photos', (select count(*) from storage.objects where bucket_id = 'ucard' and (storage.foldername(name))[1] = auth.uid()::text),
    'photo_bytes', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'ucard' and (storage.foldername(name))[1] = auth.uid()::text));
$$;

revoke execute on function public.put_ucards(jsonb), public.pull_ucards(bigint, int), public.ucard_sizes(), public.user_cards_stamp(), public.user_cards_cap() from public, anon;
grant execute on function public.put_ucards(jsonb), public.pull_ucards(bigint, int), public.ucard_sizes() to authenticated;

-- ④ 사진 버킷 — 비공개 · 장당 300KB · JPEG만(앱이 늘 기기에서 JPEG로 다시 만들어 올린다)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ucard', 'ucard', false, 307200, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 307200, allowed_mime_types = array['image/jpeg'];

-- 올릴 자리가 있나(사용자당 120개 · 계정이 아직 있나 — 다른 기기에서 탈퇴한 뒤 남은 출입증으로 올리지 못하게)
-- 🔶 security definer = 이 함수를 만든 postgres 권한으로 storage.objects를 센다(사용자는 자기 폴더만 보이지만 그 이상을 볼 일은 없다 · 셈만 돌려줌)
create or replace function public.ucard_photo_room()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from auth.users where id = auth.uid())
     and (select count(*) from storage.objects where bucket_id = 'ucard' and (storage.foldername(name))[1] = auth.uid()::text) < 120;
$$;
revoke execute on function public.ucard_photo_room() from public, anon;
grant execute on function public.ucard_photo_room() to authenticated;

-- 접근 규칙(storage.objects) — 자기 폴더만 · 이름 꼴 <사용자 id>/p<16진 16자>.jpg · 덮어쓰기(update) 없음
drop policy if exists ucard_select on storage.objects;
drop policy if exists ucard_insert on storage.objects;
drop policy if exists ucard_delete on storage.objects;
create policy ucard_select on storage.objects for select to authenticated
  using (bucket_id = 'ucard' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy ucard_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'ucard' and (storage.foldername(name))[1] = (select auth.uid()::text)
              and name ~ ('^' || (select auth.uid()::text) || '/p[0-9a-f]{16}\.jpg$')
              and (select public.ucard_photo_room()));
create policy ucard_delete on storage.objects for delete to authenticated
  using (bucket_id = 'ucard' and (storage.foldername(name))[1] = (select auth.uid()::text));

-- 확인(붙여 넣은 뒤 · 선택):
--   select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'ucard';     → 1줄 · false · 307200 · {image/jpeg}
--   select policyname from pg_policies where tablename in ('user_cards','objects') and policyname like '%u%card%';   → 6줄

-- (지우고 되돌릴 때만 — 내 카드가 전부 사라진다 · 사진 파일은 SQL로 못 지운다: 대시보드 Storage에서 버킷 비우기 → 지우기)
-- drop policy if exists ucard_select on storage.objects; drop policy if exists ucard_insert on storage.objects; drop policy if exists ucard_delete on storage.objects;
-- drop function if exists public.put_ucards(jsonb), public.pull_ucards(bigint, int), public.ucard_sizes(), public.ucard_photo_room(), public.user_cards_cap(), public.user_cards_stamp();
-- drop table if exists public.user_cards; drop sequence if exists public.user_cards_seq;
