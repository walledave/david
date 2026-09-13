-- ============================================================
-- Davids Wunschliste – Erweiterung 3
--   Wünsche aktiv/inaktiv schalten.
--   Inaktive Wünsche bleiben in der Liste, sind für Gäste aber
--   nicht mehr sichtbar – auch nicht über die API.
-- Komplett in den SQL Editor einfügen und ausführen.
-- ============================================================

-- ---------- 1. Neue Spalte ----------------------------------
-- Bestehende Wünsche sind alle aktiv.

alter table public.wishes add column if not exists active boolean not null default true;

-- ---------- 2. Gäste sehen nur noch aktive Wünsche ----------
-- Die Lesepolicy filtert schon in der Datenbank. Ein inaktiver
-- Wunsch kommt damit auch dann nicht heraus, wenn jemand die
-- REST-Schnittstelle direkt aufruft.

drop policy if exists "wishes_public_read" on public.wishes;
create policy "wishes_public_read"
  on public.wishes for select
  to anon, authenticated
  using (active);

-- ---------- 3. Admin liest die volle Liste ------------------
-- security definer umgeht die Policy, aber nur nach Passwortprüfung.

create or replace function public.admin_list_wishes(pw text)
returns setof public.wishes
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if not public.check_password(pw) then
    raise exception 'Falsches Passwort' using errcode = '28000';
  end if;

  return query
    select * from public.wishes
    order by active desc, reserved asc, created_at desc;
end;
$$;

-- ---------- 4. Umschalten -----------------------------------

create or replace function public.set_active(pw text, p_id uuid, p_value boolean)
returns public.wishes
language plpgsql security definer
set search_path = public, extensions
as $$
declare w public.wishes;
begin
  if not public.check_password(pw) then
    raise exception 'Falsches Passwort' using errcode = '28000';
  end if;

  update public.wishes set active = p_value
  where id = p_id returning * into w;

  if not found then
    raise exception 'Wunsch nicht gefunden' using errcode = '02000';
  end if;
  return w;
end;
$$;

-- ---------- 5. Inaktive Wünsche nicht reservierbar ----------
-- reserve_wish läuft als security definer und sieht daher auch
-- inaktive Zeilen. Deshalb hier die Prüfung ergänzen.

create or replace function public.reserve_wish(p_id uuid, pw text)
returns public.wishes
language plpgsql security definer
set search_path = public, extensions
as $$
declare w public.wishes;
begin
  if length(coalesce(trim(pw), '')) < 3 then
    raise exception 'Passwort zu kurz' using errcode = '22023';
  end if;

  select * into w from public.wishes where id = p_id for update;
  if not found then
    raise exception 'Wunsch nicht gefunden' using errcode = '02000';
  end if;
  if not w.active then
    raise exception 'Wunsch nicht gefunden' using errcode = '02000';
  end if;
  if w.reserved then
    raise exception 'Schon reserviert' using errcode = '55006';
  end if;

  insert into public.wish_locks (wish_id, password_hash)
  values (p_id, extensions.crypt(trim(pw), extensions.gen_salt('bf')))
  on conflict (wish_id) do update
    set password_hash = excluded.password_hash, created_at = now();

  update public.wishes set reserved = true, reserved_at = now()
  where id = p_id returning * into w;
  return w;
end;
$$;

-- ---------- 6. Rechte ---------------------------------------

grant execute on function public.admin_list_wishes(text)              to anon, authenticated;
grant execute on function public.set_active(text, uuid, boolean)      to anon, authenticated;
grant execute on function public.reserve_wish(uuid, text)             to anon, authenticated;
