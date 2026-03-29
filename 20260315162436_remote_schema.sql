

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "citext" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."forum_scope" AS ENUM (
    'generic',
    'speciality',
    'ocio',
    'clinic_cases',
    'investigation',
    'deporte',
    'padel',
    'tenis',
    'futbol',
    'deporte_otros'
);


ALTER TYPE "public"."forum_scope" OWNER TO "postgres";


CREATE TYPE "public"."housing_ad_kind" AS ENUM (
    'offer',
    'seek'
);


ALTER TYPE "public"."housing_ad_kind" OWNER TO "postgres";


CREATE TYPE "public"."job_audience" AS ENUM (
    'resident',
    'doctor',
    'both'
);


ALTER TYPE "public"."job_audience" OWNER TO "postgres";


CREATE TYPE "public"."job_contract_type" AS ENUM (
    'permanent',
    'temporary',
    'locum',
    'fellowship',
    'training',
    'other'
);


ALTER TYPE "public"."job_contract_type" OWNER TO "postgres";


CREATE TYPE "public"."job_status" AS ENUM (
    'draft',
    'published',
    'closed',
    'archived'
);


ALTER TYPE "public"."job_status" OWNER TO "postgres";


CREATE TYPE "public"."libro_entry_kind" AS ENUM (
    'counter',
    'event'
);


ALTER TYPE "public"."libro_entry_kind" OWNER TO "postgres";


CREATE TYPE "public"."libro_section_code" AS ENUM (
    'clinical_practice',
    'clinical_sessions',
    'research_work',
    'congress_attendance',
    'workshop_attendance'
);


ALTER TYPE "public"."libro_section_code" OWNER TO "postgres";


CREATE TYPE "public"."ownership_type" AS ENUM (
    'public',
    'private',
    'concertado',
    'mixed',
    'unknown'
);


ALTER TYPE "public"."ownership_type" OWNER TO "postgres";


CREATE TYPE "public"."review_question_type" AS ENUM (
    'rating',
    'text'
);


ALTER TYPE "public"."review_question_type" OWNER TO "postgres";


CREATE TYPE "public"."user_email_review_status" AS ENUM (
    'PENDING',
    'APPROVED',
    'REJECTED'
);


ALTER TYPE "public"."user_email_review_status" OWNER TO "postgres";


CREATE TYPE "public"."work_mode" AS ENUM (
    'onsite',
    'hybrid',
    'remote'
);


ALTER TYPE "public"."work_mode" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_top_specialities"("session_uuid" "uuid") RETURNS TABLE("speciality_key" "text", "speciality_name" "text", "score" numeric, "rank" integer)
    LANGUAGE "plpgsql" STABLE
    AS $$
begin
  return query
  with answer_scores as (
    select
      a.question_id,
      q.dimension,
      a.value as user_value,
      dw.weight as dimension_weight
    from speciality_quiz_answer a
    join speciality_quiz_question q on a.question_id = q.id
    join dimension_weights dw on q.dimension = dw.dimension
    where a.session_id = session_uuid
  ),
  speciality_scores as (
    select
      sp.speciality_key,
      sp.name,
      sum(
        -- Diferencia invertida entre respuesta del usuario y valor ideal (máx: 5)
        (5 - abs(ans.user_value - sds.ideal_value)) *
        -- Peso de la dimensión global
        ans.dimension_weight *
        -- Peso específico de la especialidad en esa dimensión
        sds.speciality_weight
      ) as total_score
    from speciality_profile sp
    cross join answer_scores ans
    join speciality_dimension_score sds
      on sp.speciality_key = sds.speciality_key
     and ans.dimension = sds.dimension
    group by sp.speciality_key, sp.name
  )
  select
    ss.speciality_key,
    ss.name as speciality_name,
    ss.total_score as score,
    row_number() over (order by ss.total_score desc)::int as rank
  from speciality_scores ss
  order by ss.total_score desc
  limit 3;
end;
$$;


ALTER FUNCTION "public"."calculate_top_specialities"("session_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_update_node_counter"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -----------------------------------------------------------------
  -- INSERT  ➜  sumar
  if tg_op = 'INSERT' then
     update public.libro_nodes
        set total_count = total_count + new.count,
            updated_at  = now()
      where id = new.node_id;
     return new;

  -----------------------------------------------------------------
  -- DELETE  ➜  restar
  elsif tg_op = 'DELETE' then
     update public.libro_nodes
        set total_count = greatest(total_count - old.count,0),
            updated_at  = now()
      where id = old.node_id;
     return old;

  -----------------------------------------------------------------
  -- UPDATE  ➜  ajustar
  elsif tg_op = 'UPDATE' then
     -- nodo cambiado
     if new.node_id <> old.node_id then
        update public.libro_nodes
           set total_count = greatest(total_count - old.count,0),
               updated_at  = now()
         where id = old.node_id;

        update public.libro_nodes
           set total_count = total_count + new.count,
               updated_at  = now()
         where id = new.node_id;

     -- mismo nodo, cambia sólo count
     elsif new.count <> old.count then
        update public.libro_nodes
           set total_count = greatest(total_count - old.count + new.count,0),
               updated_at  = now()
         where id = new.node_id;
     end if;
     return new;
  end if;
end;
$$;


ALTER FUNCTION "public"."fn_update_node_counter"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_referral_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  candidate text;
begin
  loop
    candidate :=
      chr(65 + (get_byte(extensions.gen_random_bytes(1), 0) % 26)) ||
      chr(65 + (get_byte(extensions.gen_random_bytes(1), 0) % 26)) ||
      chr(65 + (get_byte(extensions.gen_random_bytes(1), 0) % 26)) ||
      chr(65 + (get_byte(extensions.gen_random_bytes(1), 0) % 26)) ||
      chr(65 + (get_byte(extensions.gen_random_bytes(1), 0) % 26));

    if not exists (
      select 1 from public.users u where u.referral_code = candidate
    ) then
      return candidate;
    end if;
  end loop;
end;
$$;


ALTER FUNCTION "public"."generate_referral_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$BEGIN
  INSERT INTO public.users (
    id,
    name,
    surname,
    phone,
    is_doctor,
    is_student,
    hospital_id,
    city,
    work_email,
    speciality_id,
    resident_year,
    is_resident
  )
  VALUES (
    NEW.id,
    '',         -- name
    '',         -- surname
    '',         -- phone
    false,      -- is_doctor
    false,      -- is_student
    NULL,       -- hospital_id
    '',         -- city
    '',         -- work_email
    NULL,       -- speciality_id
    NULL,       -- resident_year
    false       -- is_resident
  );
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_user_deleted_delete_auth"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  perform net.http_post(
    url     := 'https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-user-deleted',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU'
    ),
    body    := jsonb_build_object('user_id', old.id)
  );

  return old;
end;
$$;


ALTER FUNCTION "public"."handle_user_deleted_delete_auth"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."libro_node_total_count"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE libro_node
      SET total_count = total_count + NEW.count
      WHERE id = NEW.node_id;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE libro_node
      SET total_count = total_count + NEW.count - OLD.count
      WHERE id = NEW.node_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE libro_node
      SET total_count = total_count - OLD.count
      WHERE id = OLD.node_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."libro_node_total_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_new_review"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin

  insert into notifications (
    user_id,
    type,
    actor_user_id,
    title,
    body,
    entity_type,
    entity_id,
    data
  )
  select
    r.user_id,
    'new_review',
    NEW.user_id,
    'Nueva reseña publicada',
    'Un residente ha publicado una nueva reseña',
    'review',
    NEW.id,
    jsonb_build_object(
      'entity_type','review',
      'entity_id',NEW.id,
      'hospital_id',NEW.hospital_id,
      'speciality_id',NEW.speciality_id
    )
  from review r
  where
    r.hospital_id = NEW.hospital_id
    and r.speciality_id = NEW.speciality_id
    and r.user_id != NEW.user_id
    and r.is_approved = true;

  return NEW;

end;
$$;


ALTER FUNCTION "public"."notify_new_review"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_referral_code_on_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.referral_code is null then
    new.referral_code := public.generate_referral_code();
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."set_referral_code_on_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_app_versions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_app_versions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_group_member_count"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE groups SET member_count = member_count + 1 WHERE id = NEW.group_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE groups SET member_count = member_count - 1 WHERE id = OLD.group_id;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_group_member_count"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."app_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "platform" character varying(10) NOT NULL,
    "min_required_version" character varying(20) NOT NULL,
    "is_active" boolean DEFAULT true,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "update_url" "text",
    CONSTRAINT "app_versions_platform_check" CHECK ((("platform")::"text" = ANY ((ARRAY['ios'::character varying, 'android'::character varying, 'all'::character varying])::"text"[])))
);


ALTER TABLE "public"."app_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."article" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "summary" "text",
    "body" "jsonb" NOT NULL,
    "cover_image_url" "text",
    "is_published" boolean DEFAULT false NOT NULL,
    "published_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."article" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."article_like" (
    "article_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."article_like" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."courses" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "title" "text" NOT NULL,
    "event_dates" "date"[] NOT NULL,
    "teaching_hours" "text",
    "price_text" "text",
    "course_directors" "text",
    "organization" "text",
    "venue_name" "text",
    "venue_address" "text",
    "seats_available" integer,
    "course_code" "text",
    "more_info" "text",
    "objectives" "text",
    "registration_url" "text",
    "hospital_id" "uuid",
    "speciality_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by_id" "uuid",
    CONSTRAINT "courses_seats_nonneg" CHECK ((("seats_available" IS NULL) OR ("seats_available" >= 0)))
);


ALTER TABLE "public"."courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dimension_weights" (
    "dimension" "text" NOT NULL,
    "weight" numeric(3,2) NOT NULL,
    "category" "text" NOT NULL
);


ALTER TABLE "public"."dimension_weights" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employer_account" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'owner'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "display_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "employer_account_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'editor'::"text"])))
);


ALTER TABLE "public"."employer_account" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employer_org" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "legal_name" "text",
    "tax_id" "text",
    "website" "text",
    "contact_email" "public"."citext",
    "contact_phone" "text",
    "is_verified" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employer_org" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_rotation" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "latitude" double precision NOT NULL,
    "longitude" double precision NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "country" "text",
    "city" "text",
    CONSTRAINT "external_rotation_dates_ck" CHECK ((("end_date" IS NULL) OR ("end_date" >= "start_date"))),
    CONSTRAINT "external_rotation_lat_ck" CHECK ((("latitude" >= ('-90'::integer)::double precision) AND ("latitude" <= (90)::double precision))),
    CONSTRAINT "external_rotation_lon_ck" CHECK ((("longitude" >= ('-180'::integer)::double precision) AND ("longitude" <= (180)::double precision)))
);


ALTER TABLE "public"."external_rotation" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_rotation_question" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "position" smallint NOT NULL,
    "text" "text" NOT NULL,
    "type" "public"."review_question_type" DEFAULT 'rating'::"public"."review_question_type" NOT NULL,
    "is_optional" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."external_rotation_question" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_rotation_review" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "rotation_id" "uuid" NOT NULL,
    "country" "text" NOT NULL,
    "city" "text" NOT NULL,
    "external_hospital_name" "text" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "free_comment" "text",
    "is_approved" boolean DEFAULT false NOT NULL,
    "approved_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_anonymous" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."external_rotation_review" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_rotation_review_answer" (
    "review_id" "uuid" NOT NULL,
    "question_id" "uuid" NOT NULL,
    "rating_value" smallint,
    "text_value" "text"
);


ALTER TABLE "public"."external_rotation_review_answer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_rotation_review_image" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "review_id" "uuid" NOT NULL,
    "path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."external_rotation_review_image" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_rotation_review_thread" (
    "review_id" "uuid" NOT NULL,
    "thread_id" "uuid" NOT NULL
);


ALTER TABLE "public"."external_rotation_review_thread" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."forum" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "scope" "public"."forum_scope" NOT NULL,
    "role_scope" "text" NOT NULL,
    "speciality_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "city" "text",
    CONSTRAINT "forum_role_scope_check" CHECK (("role_scope" = ANY (ARRAY['student'::"text", 'resident'::"text", 'doctor'::"text"])))
);


ALTER TABLE "public"."forum" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."group_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."group_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."group_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "edited_at" timestamp with time zone
);


ALTER TABLE "public"."group_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_type" character varying(10) NOT NULL,
    "speciality_id" "uuid" NOT NULL,
    "city" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "member_count" integer DEFAULT 0,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "groups_user_type_check" CHECK ((("user_type")::"text" = ANY ((ARRAY['student'::character varying, 'resident'::character varying])::"text"[])))
);


ALTER TABLE "public"."groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hospital_specialities" (
    "hospital_id" "uuid" NOT NULL,
    "speciality_id" "uuid" NOT NULL,
    "grade_2024" integer,
    "grade_2023" integer,
    "grade_2022" integer,
    "grade_2021" integer,
    "grade_2025" integer,
    "slots" integer,
    "grade_2019" integer,
    "grade_2020" integer,
    "info_note" "text"
);


ALTER TABLE "public"."hospital_specialities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hospital_speciality_grades" (
    "hospital_id" "uuid" NOT NULL,
    "speciality_id" "uuid" NOT NULL,
    "year" smallint NOT NULL,
    "slots" smallint DEFAULT 0 NOT NULL,
    "grades" integer[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hospital_speciality_grades" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hospitals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "city" "text" NOT NULL,
    "region" "text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "salary_r1_fixed_eur" numeric(10,2),
    "salary_r2_fixed_eur" numeric(10,2),
    "salary_r3_fixed_eur" numeric(10,2),
    "salary_r4_fixed_eur" numeric(10,2),
    "email_domain" "text",
    "ownership" "public"."ownership_type" DEFAULT 'public'::"public"."ownership_type" NOT NULL
);


ALTER TABLE "public"."hospitals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."housing_ad" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "public"."housing_ad_kind" NOT NULL,
    "city" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "price_eur" integer,
    "available_from" "date",
    "contact_email" "public"."citext",
    "contact_phone" "text",
    "preferred_contact" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "available_to" "date",
    "hospital_id" "uuid",
    CONSTRAINT "housing_ad_contact_ck" CHECK ((("contact_email" IS NOT NULL) OR ("contact_phone" IS NOT NULL))),
    CONSTRAINT "housing_ad_preferred_contact_check" CHECK ((("preferred_contact" = ANY (ARRAY['email'::"text", 'phone'::"text"])) OR ("preferred_contact" IS NULL))),
    CONSTRAINT "housing_ad_price_ck" CHECK ((("price_eur" IS NULL) OR ("price_eur" >= 0)))
);


ALTER TABLE "public"."housing_ad" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."housing_ad_image" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "ad_id" "uuid" NOT NULL,
    "object_path" "text" NOT NULL,
    "position" smallint DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "housing_ad_image_path_ck" CHECK (("length"("object_path") > 0))
);


ALTER TABLE "public"."housing_ad_image" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "created_by_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "audience" "public"."job_audience" DEFAULT 'resident'::"public"."job_audience" NOT NULL,
    "speciality_id" "uuid",
    "contract_type" "public"."job_contract_type",
    "work_mode" "public"."work_mode",
    "salary_min_eur" integer,
    "salary_max_eur" integer,
    "salary_text" "text",
    "region" "text",
    "city" "text" NOT NULL,
    "country" "text" DEFAULT 'ES'::"text" NOT NULL,
    "facility_name" "text",
    "facility_ownership" "public"."ownership_type",
    "application_url" "text",
    "application_email" "public"."citext",
    "application_phone" "text",
    "status" "public"."job_status" DEFAULT 'draft'::"public"."job_status" NOT NULL,
    "published_at" timestamp with time zone,
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "job_facility_present_ck" CHECK (("facility_name" IS NOT NULL)),
    CONSTRAINT "job_salary_nonneg" CHECK (((("salary_min_eur" IS NULL) OR ("salary_min_eur" >= 0)) AND (("salary_max_eur" IS NULL) OR ("salary_max_eur" >= 0)) AND (("salary_min_eur" IS NULL) OR ("salary_max_eur" IS NULL) OR ("salary_max_eur" >= "salary_min_eur"))))
);


ALTER TABLE "public"."job" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."libro_entry" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "node_id" "uuid" NOT NULL,
    "count" integer NOT NULL,
    "residency_year" integer,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "kind" "public"."libro_entry_kind" DEFAULT 'counter'::"public"."libro_entry_kind" NOT NULL,
    "section" "public"."libro_section_code" NOT NULL
);


ALTER TABLE "public"."libro_entry" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."libro_event" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "entry_id" "uuid" NOT NULL,
    "node_id" "uuid",
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "event_date" "date" NOT NULL,
    "hours" numeric(4,1),
    "location" "text",
    "notes" "text",
    "residency_year" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."libro_event" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."libro_node" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "parent_node_id" "uuid",
    "name" "text" NOT NULL,
    "total_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "section" "public"."libro_section_code",
    "goal" integer,
    "position" integer
);


ALTER TABLE "public"."libro_node" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."libro_section" (
    "code" "public"."libro_section_code" NOT NULL,
    "display_name" "text" NOT NULL
);


ALTER TABLE "public"."libro_section" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mir_simulator_searches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "grade" numeric NOT NULL,
    "speciality_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mir_simulator_searches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "notification_id" "uuid" NOT NULL,
    "push_token_id" "uuid",
    "status" "text" NOT NULL,
    "provider_response" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_at" timestamp with time zone,
    CONSTRAINT "notification_deliveries_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'sent'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."notification_deliveries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_types" (
    "code" "text" NOT NULL,
    "description" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notification_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "actor_user_id" "uuid",
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "uuid",
    "data" "jsonb",
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp with time zone
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."post" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "thread_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "parent_post_id" "uuid",
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."post" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "provider" "text" DEFAULT 'expo'::"text" NOT NULL,
    "platform" "text" NOT NULL,
    "device_name" "text",
    "app_version" "text",
    "is_valid" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "push_tokens_platform_check" CHECK (("platform" = ANY (ARRAY['ios'::"text", 'android'::"text"])))
);


ALTER TABLE "public"."push_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."question" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "position" smallint NOT NULL,
    "text" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "type" "public"."review_question_type" DEFAULT 'rating'::"public"."review_question_type" NOT NULL,
    "is_optional" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."question" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."raffle" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "draw_at" timestamp with time zone,
    "min_invites" integer DEFAULT 2 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "raffle_dates_chk" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."raffle" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."referral" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "raffle_id" "uuid" NOT NULL,
    "referrer_user_id" "uuid" NOT NULL,
    "referred_user_id" "uuid" NOT NULL,
    "referral_code_used" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "referral_code_used_format_chk" CHECK (("referral_code_used" ~ '^[A-Z]{5}$'::"text")),
    CONSTRAINT "referral_not_self_chk" CHECK (("referrer_user_id" <> "referred_user_id"))
);


ALTER TABLE "public"."referral" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."review" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "hospital_id" "uuid" NOT NULL,
    "speciality_id" "uuid" NOT NULL,
    "free_comment" "text",
    "is_approved" boolean DEFAULT false NOT NULL,
    "approved_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_anonymous" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."review" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."review_answer" (
    "review_id" "uuid" NOT NULL,
    "question_id" "uuid" NOT NULL,
    "rating_value" smallint,
    "text_value" "text",
    CONSTRAINT "review_answer_rating_value_check" CHECK ((("rating_value" >= 1) AND ("rating_value" <= 10)))
);


ALTER TABLE "public"."review_answer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."review_image" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "review_id" "uuid" NOT NULL,
    "path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."review_image" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."review_question" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "hospital_id" "uuid" NOT NULL,
    "speciality_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "question_text" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."review_question" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."review_question_answer" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "question_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "answer_text" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."review_question_answer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shift_purchase_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shift_id" "uuid" NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "offered_price_eur" numeric(10,2),
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "shift_purchase_requests_offered_price_eur_check" CHECK (("offered_price_eur" >= (0)::numeric)),
    CONSTRAINT "shift_purchase_requests_status_check" CHECK (("status" = ANY (ARRAY['PENDING'::"text", 'ACCEPTED'::"text", 'REJECTED'::"text"])))
);


ALTER TABLE "public"."shift_purchase_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shift_swap_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "requester_shift_id" "uuid" NOT NULL,
    "target_shift_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "shift_swap_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."shift_swap_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shifts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "type" "text" NOT NULL,
    "notes" "text",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "price_eur" numeric(10,2),
    CONSTRAINT "shifts_price_eur_check" CHECK (("price_eur" >= (0)::numeric)),
    CONSTRAINT "shifts_type_check" CHECK (("type" = ANY (ARRAY['regular'::"text", 'saturday'::"text", 'sunday'::"text"])))
);


ALTER TABLE "public"."shifts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."specialities" (
    "id" "uuid" NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."specialities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."speciality_dimension_score" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "speciality_key" "text" NOT NULL,
    "dimension" "text" NOT NULL,
    "ideal_value" numeric(3,2) NOT NULL,
    "speciality_weight" numeric(3,2) DEFAULT 1.0
);


ALTER TABLE "public"."speciality_dimension_score" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."speciality_profile" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "speciality_key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "description" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "speciality_profile_category_check" CHECK (("category" = ANY (ARRAY['atencion_primaria'::"text", 'quirurgica'::"text", 'medica'::"text", 'urgencias_criticos'::"text", 'diagnostica'::"text", 'salud_publica'::"text"])))
);


ALTER TABLE "public"."speciality_profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."speciality_quiz_answer" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "question_id" "uuid" NOT NULL,
    "value" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."speciality_quiz_answer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."speciality_quiz_option" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "question_id" "uuid" NOT NULL,
    "label" "text" NOT NULL,
    "value" integer NOT NULL,
    "order_index" integer NOT NULL
);


ALTER TABLE "public"."speciality_quiz_option" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."speciality_quiz_question" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_index" integer NOT NULL,
    "text" "text" NOT NULL,
    "dimension" "text" NOT NULL,
    "question_type" "text" DEFAULT 'likert'::"text" NOT NULL
);


ALTER TABLE "public"."speciality_quiz_question" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."speciality_quiz_session" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "top_results" "jsonb",
    "raw_scores" "jsonb",
    "meta" "jsonb"
);


ALTER TABLE "public"."speciality_quiz_session" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."thread" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "forum_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."thread" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_email_review_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "work_email" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "public"."user_email_review_status" DEFAULT 'PENDING'::"public"."user_email_review_status" NOT NULL
);


ALTER TABLE "public"."user_email_review_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_hospital_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "hospital_id" "uuid" NOT NULL,
    "speciality_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "position" integer NOT NULL
);


ALTER TABLE "public"."user_hospital_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_notification_preferences" (
    "user_id" "uuid" NOT NULL,
    "notification_type" "text" NOT NULL,
    "push_enabled" boolean DEFAULT true NOT NULL,
    "in_app_enabled" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."user_notification_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "is_resident" boolean DEFAULT false,
    "name" "text",
    "surname" "text",
    "phone" "text",
    "is_doctor" boolean DEFAULT false,
    "is_student" boolean DEFAULT false,
    "hospital_id" "uuid",
    "city" "text",
    "work_email" "text",
    "speciality_id" "uuid",
    "resident_year" integer,
    "is_super_admin" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "referral_code" "text",
    CONSTRAINT "users_referral_code_format_chk" CHECK ((("referral_code" IS NULL) OR ("referral_code" ~ '^[A-Z]{5}$'::"text"))),
    CONSTRAINT "users_resident_year_check" CHECK ((("resident_year" >= 1) AND ("resident_year" <= 5)))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


ALTER TABLE ONLY "public"."app_versions"
    ADD CONSTRAINT "app_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."article_like"
    ADD CONSTRAINT "article_like_pkey" PRIMARY KEY ("article_id", "user_id");



ALTER TABLE ONLY "public"."article"
    ADD CONSTRAINT "article_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."article"
    ADD CONSTRAINT "article_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dimension_weights"
    ADD CONSTRAINT "dimension_weights_pkey" PRIMARY KEY ("dimension");



ALTER TABLE ONLY "public"."employer_account"
    ADD CONSTRAINT "employer_account_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employer_account"
    ADD CONSTRAINT "employer_account_user_id_org_id_key" UNIQUE ("user_id", "org_id");



ALTER TABLE ONLY "public"."employer_org"
    ADD CONSTRAINT "employer_org_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_rotation"
    ADD CONSTRAINT "external_rotation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_rotation_question"
    ADD CONSTRAINT "external_rotation_question_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_rotation_review_answer"
    ADD CONSTRAINT "external_rotation_review_answer_pkey" PRIMARY KEY ("review_id", "question_id");



ALTER TABLE ONLY "public"."external_rotation_review_image"
    ADD CONSTRAINT "external_rotation_review_image_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_rotation_review"
    ADD CONSTRAINT "external_rotation_review_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_rotation_review_thread"
    ADD CONSTRAINT "external_rotation_review_thread_pkey" PRIMARY KEY ("review_id");



ALTER TABLE ONLY "public"."forum"
    ADD CONSTRAINT "forum_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."forum"
    ADD CONSTRAINT "forum_scope_role_scope_speciality_id_key" UNIQUE ("scope", "role_scope", "speciality_id");



ALTER TABLE ONLY "public"."group_members"
    ADD CONSTRAINT "group_members_group_id_user_id_key" UNIQUE ("group_id", "user_id");



ALTER TABLE ONLY "public"."group_members"
    ADD CONSTRAINT "group_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."group_messages"
    ADD CONSTRAINT "group_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_user_type_speciality_id_city_key" UNIQUE ("user_type", "speciality_id", "city");



ALTER TABLE ONLY "public"."hospital_specialities"
    ADD CONSTRAINT "hospital_specialities_pkey" PRIMARY KEY ("hospital_id", "speciality_id");



ALTER TABLE ONLY "public"."hospital_speciality_grades"
    ADD CONSTRAINT "hospital_speciality_grades_pkey" PRIMARY KEY ("hospital_id", "speciality_id", "year");



ALTER TABLE ONLY "public"."hospitals"
    ADD CONSTRAINT "hospitals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."housing_ad_image"
    ADD CONSTRAINT "housing_ad_image_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."housing_ad_image"
    ADD CONSTRAINT "housing_ad_image_pos_uq" UNIQUE ("ad_id", "position");



ALTER TABLE ONLY "public"."housing_ad"
    ADD CONSTRAINT "housing_ad_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job"
    ADD CONSTRAINT "job_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."libro_entry"
    ADD CONSTRAINT "libro_entry_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."libro_event"
    ADD CONSTRAINT "libro_event_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."libro_node"
    ADD CONSTRAINT "libro_node_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."libro_section"
    ADD CONSTRAINT "libro_section_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "public"."mir_simulator_searches"
    ADD CONSTRAINT "mir_simulator_searches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_deliveries"
    ADD CONSTRAINT "notification_deliveries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_types"
    ADD CONSTRAINT "notification_types_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."post"
    ADD CONSTRAINT "post_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."raffle"
    ADD CONSTRAINT "raffle_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."referral"
    ADD CONSTRAINT "referral_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."review_answer"
    ADD CONSTRAINT "review_answer_pkey" PRIMARY KEY ("review_id", "question_id");



ALTER TABLE ONLY "public"."review_image"
    ADD CONSTRAINT "review_image_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."review"
    ADD CONSTRAINT "review_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."review_question_answer"
    ADD CONSTRAINT "review_question_answer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."review_question_answer"
    ADD CONSTRAINT "review_question_answer_question_id_user_id_key" UNIQUE ("question_id", "user_id");



ALTER TABLE ONLY "public"."question"
    ADD CONSTRAINT "review_question_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."review_question"
    ADD CONSTRAINT "review_question_pkey1" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."review"
    ADD CONSTRAINT "review_user_id_hospital_id_speciality_id_key" UNIQUE ("user_id", "hospital_id", "speciality_id");



ALTER TABLE ONLY "public"."shift_purchase_requests"
    ADD CONSTRAINT "shift_purchase_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shift_swap_requests"
    ADD CONSTRAINT "shift_swap_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shift_swap_requests"
    ADD CONSTRAINT "shift_swap_requests_requester_shift_id_target_shift_id_key" UNIQUE ("requester_shift_id", "target_shift_id");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_user_id_date_key" UNIQUE ("user_id", "date");



ALTER TABLE ONLY "public"."specialities"
    ADD CONSTRAINT "specialities_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."specialities"
    ADD CONSTRAINT "specialities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."speciality_dimension_score"
    ADD CONSTRAINT "speciality_dimension_score_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."speciality_dimension_score"
    ADD CONSTRAINT "speciality_dimension_score_speciality_key_dimension_key" UNIQUE ("speciality_key", "dimension");



ALTER TABLE ONLY "public"."speciality_profile"
    ADD CONSTRAINT "speciality_profile_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."speciality_profile"
    ADD CONSTRAINT "speciality_profile_speciality_key_key" UNIQUE ("speciality_key");



ALTER TABLE ONLY "public"."speciality_quiz_answer"
    ADD CONSTRAINT "speciality_quiz_answer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."speciality_quiz_answer"
    ADD CONSTRAINT "speciality_quiz_answer_session_id_question_id_key" UNIQUE ("session_id", "question_id");



ALTER TABLE ONLY "public"."speciality_quiz_option"
    ADD CONSTRAINT "speciality_quiz_option_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."speciality_quiz_question"
    ADD CONSTRAINT "speciality_quiz_question_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."speciality_quiz_session"
    ADD CONSTRAINT "speciality_quiz_session_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."thread"
    ADD CONSTRAINT "thread_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_email_review_requests"
    ADD CONSTRAINT "user_email_review_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_hospital_preferences"
    ADD CONSTRAINT "user_hospital_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_hospital_preferences"
    ADD CONSTRAINT "user_hospital_preferences_user_id_hospital_id_speciality_id_key" UNIQUE ("user_id", "hospital_id", "speciality_id");



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_pkey" PRIMARY KEY ("user_id", "notification_type");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



CREATE INDEX "courses_search_idx" ON "public"."courses" USING "gin" ("to_tsvector"('"spanish"'::"regconfig", ((((((COALESCE("title", ''::"text") || ' '::"text") || COALESCE("organization", ''::"text")) || ' '::"text") || COALESCE("venue_name", ''::"text")) || ' '::"text") || COALESCE("course_code", ''::"text"))));



CREATE INDEX "hospitals_textsearch_idx" ON "public"."hospitals" USING "gin" ("to_tsvector"('"english"'::"regconfig", (((("name" || ' '::"text") || "city") || ' '::"text") || "region")));



CREATE INDEX "housing_ad_active_idx" ON "public"."housing_ad" USING "btree" ("is_active");



CREATE INDEX "housing_ad_city_idx" ON "public"."housing_ad" USING "btree" ("lower"("city"));



CREATE INDEX "housing_ad_image_ad_idx" ON "public"."housing_ad_image" USING "btree" ("ad_id");



CREATE INDEX "housing_ad_kind_idx" ON "public"."housing_ad" USING "btree" ("kind");



CREATE INDEX "housing_ad_search_idx" ON "public"."housing_ad" USING "gin" ("to_tsvector"('"spanish"'::"regconfig", ((((COALESCE("title", ''::"text") || ' '::"text") || COALESCE("description", ''::"text")) || ' '::"text") || COALESCE("city", ''::"text"))));



CREATE INDEX "idx_app_versions_created_at" ON "public"."app_versions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_app_versions_platform_active" ON "public"."app_versions" USING "btree" ("platform", "is_active") WHERE ("is_active" = true);



CREATE UNIQUE INDEX "idx_app_versions_unique_active_platform" ON "public"."app_versions" USING "btree" ("platform") WHERE ("is_active" = true);



CREATE INDEX "idx_courses_created_by_id" ON "public"."courses" USING "btree" ("created_by_id");



CREATE INDEX "idx_group_messages_group_id_created_at" ON "public"."group_messages" USING "btree" ("group_id", "created_at" DESC);



CREATE INDEX "idx_notification_deliveries_notification" ON "public"."notification_deliveries" USING "btree" ("notification_id");



CREATE INDEX "idx_notifications_unread" ON "public"."notifications" USING "btree" ("user_id", "is_read") WHERE ("is_read" = false);



CREATE INDEX "idx_notifications_user_created" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_post_parent" ON "public"."post" USING "btree" ("parent_post_id");



CREATE INDEX "idx_post_thread" ON "public"."post" USING "btree" ("thread_id");



CREATE INDEX "idx_push_tokens_user" ON "public"."push_tokens" USING "btree" ("user_id");



CREATE INDEX "idx_push_tokens_valid" ON "public"."push_tokens" USING "btree" ("is_valid");



CREATE INDEX "idx_speciality_quiz_session_user_started" ON "public"."speciality_quiz_session" USING "btree" ("user_id", "started_at" DESC);



CREATE INDEX "idx_thread_forum" ON "public"."thread" USING "btree" ("forum_id");



CREATE INDEX "job_city_idx" ON "public"."job" USING "btree" ("lower"("city"));



CREATE INDEX "job_org_idx" ON "public"."job" USING "btree" ("org_id");



CREATE INDEX "job_search_idx" ON "public"."job" USING "gin" ("to_tsvector"('"spanish"'::"regconfig", ((((((COALESCE("title", ''::"text") || ' '::"text") || COALESCE("description", ''::"text")) || ' '::"text") || COALESCE("city", ''::"text")) || ' '::"text") || COALESCE("facility_name", ''::"text"))));



CREATE INDEX "job_speciality_idx" ON "public"."job" USING "btree" ("speciality_id");



CREATE INDEX "job_status_idx" ON "public"."job" USING "btree" ("status", "expires_at");



CREATE INDEX "libro_event_user_year_idx" ON "public"."libro_event" USING "btree" ("user_id", "residency_year");



CREATE UNIQUE INDEX "referral_unique_edge" ON "public"."referral" USING "btree" ("raffle_id", "referrer_user_id", "referred_user_id");



CREATE UNIQUE INDEX "referral_unique_referred_per_raffle" ON "public"."referral" USING "btree" ("raffle_id", "referred_user_id");



CREATE INDEX "review_answer_question_idx" ON "public"."review_answer" USING "btree" ("question_id");



CREATE INDEX "review_hosp_spec_idx" ON "public"."review" USING "btree" ("hospital_id", "speciality_id");



CREATE INDEX "review_image_review_id_idx" ON "public"."review_image" USING "btree" ("review_id");



CREATE UNIQUE INDEX "shift_purchase_requests_unique_idx" ON "public"."shift_purchase_requests" USING "btree" ("shift_id", "buyer_id");



CREATE UNIQUE INDEX "users_referral_code_uq" ON "public"."users" USING "btree" ("referral_code") WHERE ("referral_code" IS NOT NULL);



CREATE OR REPLACE TRIGGER "on-review-created" AFTER INSERT ON "public"."review" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-review-created', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_review_question_created" AFTER INSERT ON "public"."review_question" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/notify-review-question-ts', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_review_rejected_updated" AFTER UPDATE ON "public"."review" FOR EACH ROW WHEN (("new"."is_approved" = false)) EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/notify-review-rejected', 'POST', '{
      "Content-type":"application/json",
      "Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"
    }', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_shift_paid_request_created" AFTER INSERT ON "public"."shift_purchase_requests" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/notify-shift-paid-request', 'POST', '{"Content-Type":"application/json"}');



CREATE OR REPLACE TRIGGER "on_shift_paid_request_status_updated" AFTER UPDATE ON "public"."shift_purchase_requests" FOR EACH ROW WHEN (("new"."status" = ANY (ARRAY['ACCEPTED'::"text", 'REJECTED'::"text"]))) EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-shift-purchased-updated', 'POST', '{
      "Content-type":"application/json",
      "Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"
    }', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_shift_paid_request_updated" AFTER UPDATE ON "public"."shift_purchase_requests" FOR EACH ROW WHEN (("new"."status" = ANY (ARRAY['ACCEPTED'::"text", 'REJECTED'::"text"]))) EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/notify-shift-paid-request-status', 'POST', '{"Content-type":"application/json"}');



CREATE OR REPLACE TRIGGER "on_shift_purchase_requests" AFTER INSERT ON "public"."shift_purchase_requests" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-shift-paid-swap-requested', 'POST', '{
      "Content-type":"application/json",
      "Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"
    }', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_shift_swap_updated" AFTER UPDATE ON "public"."shift_swap_requests" FOR EACH ROW WHEN (("new"."status" = ANY (ARRAY['accepted'::"text", 'rejected'::"text"]))) EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-shift-swap-updated', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_user_deleted_delete_auth" AFTER DELETE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."handle_user_deleted_delete_auth"();



CREATE OR REPLACE TRIGGER "on_user_email_review_updated" AFTER UPDATE ON "public"."user_email_review_requests" FOR EACH ROW WHEN (("new"."status" = 'APPROVED'::"public"."user_email_review_status")) EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-user-email-review-updated', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_user_email_to_review" AFTER INSERT ON "public"."user_email_review_requests" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxywvaaruwovbb.supabase.co/functions/v1/on-email-to-verify', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNoZ3JldHd4eXd2YWFydXdvdmJiIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDc0Nzk0MSwiZXhwIjoyMDY2MzIzOTQxfQ.wCnS-qmCE_v2DZKQiDmL5e_4Y6LCNgOopp_7hkqgyxU"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "send_push_notifications" AFTER INSERT ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://chgretwxyvwaaruwovbb.supabase.co/functions/v1/send-push-notifications', 'POST', '{"Content-type":"application/json"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "trg_group_member_count" AFTER INSERT OR DELETE ON "public"."group_members" FOR EACH ROW EXECUTE FUNCTION "public"."update_group_member_count"();



CREATE OR REPLACE TRIGGER "trg_libro_node_total_count" AFTER INSERT OR DELETE OR UPDATE ON "public"."libro_entry" FOR EACH ROW EXECUTE FUNCTION "public"."libro_node_total_count"();



CREATE OR REPLACE TRIGGER "trg_users_set_referral_code" BEFORE INSERT ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."set_referral_code_on_insert"();



CREATE OR REPLACE TRIGGER "trigger_notify_new_review" AFTER INSERT ON "public"."review" FOR EACH ROW WHEN (("new"."is_approved" = true)) EXECUTE FUNCTION "public"."notify_new_review"();



CREATE OR REPLACE TRIGGER "trigger_update_app_versions_updated_at" BEFORE UPDATE ON "public"."app_versions" FOR EACH ROW EXECUTE FUNCTION "public"."update_app_versions_updated_at"();



ALTER TABLE ONLY "public"."article_like"
    ADD CONSTRAINT "article_like_article_id_fkey" FOREIGN KEY ("article_id") REFERENCES "public"."article"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."article_like"
    ADD CONSTRAINT "article_like_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."article"
    ADD CONSTRAINT "article_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_created_by_id_fkey" FOREIGN KEY ("created_by_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."employer_account"
    ADD CONSTRAINT "employer_account_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."employer_org"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employer_account"
    ADD CONSTRAINT "employer_account_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_rotation_review_answer"
    ADD CONSTRAINT "external_rotation_review_answer_question_id_fkey" FOREIGN KEY ("question_id") REFERENCES "public"."external_rotation_question"("id");



ALTER TABLE ONLY "public"."external_rotation_review_answer"
    ADD CONSTRAINT "external_rotation_review_answer_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."external_rotation_review"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_rotation_review_image"
    ADD CONSTRAINT "external_rotation_review_image_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."external_rotation_review"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_rotation_review"
    ADD CONSTRAINT "external_rotation_review_rotation_id_fkey" FOREIGN KEY ("rotation_id") REFERENCES "public"."external_rotation"("id");



ALTER TABLE ONLY "public"."external_rotation_review_thread"
    ADD CONSTRAINT "external_rotation_review_thread_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."external_rotation_review"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_rotation_review_thread"
    ADD CONSTRAINT "external_rotation_review_thread_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread"("id");



ALTER TABLE ONLY "public"."external_rotation_review"
    ADD CONSTRAINT "external_rotation_review_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_rotation"
    ADD CONSTRAINT "external_rotation_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."group_members"
    ADD CONSTRAINT "group_members_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."group_members"
    ADD CONSTRAINT "group_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."group_messages"
    ADD CONSTRAINT "group_messages_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."group_messages"
    ADD CONSTRAINT "group_messages_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id");



ALTER TABLE ONLY "public"."hospital_specialities"
    ADD CONSTRAINT "hospital_specialities_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hospital_specialities"
    ADD CONSTRAINT "hospital_specialities_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hospital_speciality_grades"
    ADD CONSTRAINT "hospital_speciality_grades_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hospital_speciality_grades"
    ADD CONSTRAINT "hospital_speciality_grades_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hospitals"
    ADD CONSTRAINT "hospitals_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."housing_ad"
    ADD CONSTRAINT "housing_ad_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."housing_ad_image"
    ADD CONSTRAINT "housing_ad_image_ad_id_fkey" FOREIGN KEY ("ad_id") REFERENCES "public"."housing_ad"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."housing_ad"
    ADD CONSTRAINT "housing_ad_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job"
    ADD CONSTRAINT "job_created_by_id_fkey" FOREIGN KEY ("created_by_id") REFERENCES "public"."employer_account"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."job"
    ADD CONSTRAINT "job_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."employer_org"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job"
    ADD CONSTRAINT "job_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."libro_entry"
    ADD CONSTRAINT "libro_entry_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."libro_node"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."libro_event"
    ADD CONSTRAINT "libro_event_entry_id_fkey" FOREIGN KEY ("entry_id") REFERENCES "public"."libro_entry"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."libro_event"
    ADD CONSTRAINT "libro_event_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."libro_node"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."libro_event"
    ADD CONSTRAINT "libro_event_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."libro_node"
    ADD CONSTRAINT "libro_node_parent_node_id_fkey" FOREIGN KEY ("parent_node_id") REFERENCES "public"."libro_node"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."libro_node"
    ADD CONSTRAINT "libro_node_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mir_simulator_searches"
    ADD CONSTRAINT "mir_simulator_searches_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mir_simulator_searches"
    ADD CONSTRAINT "mir_simulator_searches_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_deliveries"
    ADD CONSTRAINT "notification_deliveries_notification_id_fkey" FOREIGN KEY ("notification_id") REFERENCES "public"."notifications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_deliveries"
    ADD CONSTRAINT "notification_deliveries_push_token_id_fkey" FOREIGN KEY ("push_token_id") REFERENCES "public"."push_tokens"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_actor_user_id_fkey" FOREIGN KEY ("actor_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_type_fkey" FOREIGN KEY ("type") REFERENCES "public"."notification_types"("code");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post"
    ADD CONSTRAINT "post_parent_post_id_fkey" FOREIGN KEY ("parent_post_id") REFERENCES "public"."post"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post"
    ADD CONSTRAINT "post_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post"
    ADD CONSTRAINT "post_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."referral"
    ADD CONSTRAINT "referral_raffle_id_fkey" FOREIGN KEY ("raffle_id") REFERENCES "public"."raffle"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."referral"
    ADD CONSTRAINT "referral_referred_user_id_fkey" FOREIGN KEY ("referred_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."referral"
    ADD CONSTRAINT "referral_referrer_user_id_fkey" FOREIGN KEY ("referrer_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_answer"
    ADD CONSTRAINT "review_answer_question_id_fkey" FOREIGN KEY ("question_id") REFERENCES "public"."question"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_answer"
    ADD CONSTRAINT "review_answer_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."review"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review"
    ADD CONSTRAINT "review_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_image"
    ADD CONSTRAINT "review_image_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."review"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_question_answer"
    ADD CONSTRAINT "review_question_answer_question_id_fkey" FOREIGN KEY ("question_id") REFERENCES "public"."review_question"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_question_answer"
    ADD CONSTRAINT "review_question_answer_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_question"
    ADD CONSTRAINT "review_question_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_question"
    ADD CONSTRAINT "review_question_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_question"
    ADD CONSTRAINT "review_question_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review"
    ADD CONSTRAINT "review_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review"
    ADD CONSTRAINT "review_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shift_purchase_requests"
    ADD CONSTRAINT "shift_purchase_requests_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shift_purchase_requests"
    ADD CONSTRAINT "shift_purchase_requests_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shift_purchase_requests"
    ADD CONSTRAINT "shift_purchase_requests_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shift_swap_requests"
    ADD CONSTRAINT "shift_swap_requests_requester_shift_id_fkey" FOREIGN KEY ("requester_shift_id") REFERENCES "public"."shifts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shift_swap_requests"
    ADD CONSTRAINT "shift_swap_requests_target_shift_id_fkey" FOREIGN KEY ("target_shift_id") REFERENCES "public"."shifts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."speciality_dimension_score"
    ADD CONSTRAINT "speciality_dimension_score_dimension_fkey" FOREIGN KEY ("dimension") REFERENCES "public"."dimension_weights"("dimension");



ALTER TABLE ONLY "public"."speciality_dimension_score"
    ADD CONSTRAINT "speciality_dimension_score_speciality_key_fkey" FOREIGN KEY ("speciality_key") REFERENCES "public"."speciality_profile"("speciality_key");



ALTER TABLE ONLY "public"."speciality_quiz_answer"
    ADD CONSTRAINT "speciality_quiz_answer_question_id_fkey" FOREIGN KEY ("question_id") REFERENCES "public"."speciality_quiz_question"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."speciality_quiz_answer"
    ADD CONSTRAINT "speciality_quiz_answer_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."speciality_quiz_session"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."speciality_quiz_option"
    ADD CONSTRAINT "speciality_quiz_option_question_id_fkey" FOREIGN KEY ("question_id") REFERENCES "public"."speciality_quiz_question"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."speciality_quiz_session"
    ADD CONSTRAINT "speciality_quiz_session_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."thread"
    ADD CONSTRAINT "thread_forum_id_fkey" FOREIGN KEY ("forum_id") REFERENCES "public"."forum"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."thread"
    ADD CONSTRAINT "thread_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_email_review_requests"
    ADD CONSTRAINT "user_email_review_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_hospital_preferences"
    ADD CONSTRAINT "user_hospital_preferences_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_hospital_preferences"
    ADD CONSTRAINT "user_hospital_preferences_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_hospital_preferences"
    ADD CONSTRAINT "user_hospital_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_notification_type_fkey" FOREIGN KEY ("notification_type") REFERENCES "public"."notification_types"("code");



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_hospital_id_fkey" FOREIGN KEY ("hospital_id") REFERENCES "public"."hospitals"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_speciality_id_fkey" FOREIGN KEY ("speciality_id") REFERENCES "public"."specialities"("id") ON DELETE SET NULL;



CREATE POLICY "Allow public read access to app_versions" ON "public"."app_versions" FOR SELECT USING (true);



CREATE POLICY "Dev: Allow image insert for existing ads" ON "public"."housing_ad_image" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."housing_ad"
  WHERE ("housing_ad"."id" = "housing_ad_image"."ad_id"))));



CREATE POLICY "Public can read hospitals" ON "public"."hospitals" FOR SELECT USING (true);



CREATE POLICY "Users can see their notifications" ON "public"."notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update read status" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage their tokens" ON "public"."push_tokens" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "allow_all_article" ON "public"."article" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_article_like" ON "public"."article_like" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_courses" ON "public"."courses" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_employer_account" ON "public"."employer_account" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_employer_org" ON "public"."employer_org" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_external_rotation" ON "public"."external_rotation" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_external_rotation_question" ON "public"."external_rotation_question" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_external_rotation_review" ON "public"."external_rotation_review" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_external_rotation_review_answer" ON "public"."external_rotation_review_answer" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_external_rotation_review_image" ON "public"."external_rotation_review_image" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_external_rotation_review_thread" ON "public"."external_rotation_review_thread" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_forum" ON "public"."forum" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_hospital_specialities" ON "public"."hospital_specialities" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_hospital_speciality_grades" ON "public"."hospital_speciality_grades" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_housing_ad" ON "public"."housing_ad" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_housing_ad_image" ON "public"."housing_ad_image" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_job" ON "public"."job" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_libro_entry" ON "public"."libro_entry" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_libro_event" ON "public"."libro_event" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_libro_node" ON "public"."libro_node" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_libro_section" ON "public"."libro_section" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_mir_simulator_searches" ON "public"."mir_simulator_searches" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_post" ON "public"."post" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_question" ON "public"."question" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_raffle" ON "public"."raffle" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_referral" ON "public"."referral" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_review" ON "public"."review" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_review_answer" ON "public"."review_answer" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_review_image" ON "public"."review_image" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_review_question" ON "public"."review_question" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_review_question_answer" ON "public"."review_question_answer" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_shift_purchase_requests" ON "public"."shift_purchase_requests" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_shift_swap_requests" ON "public"."shift_swap_requests" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_shifts" ON "public"."shifts" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_specialities" ON "public"."specialities" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_thread" ON "public"."thread" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_user_email_review_requests" ON "public"."user_email_review_requests" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_user_hospital_preferences" ON "public"."user_hospital_preferences" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_users" ON "public"."users" USING (true) WITH CHECK (true);



ALTER TABLE "public"."app_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."article" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."article_like" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."courses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employer_account" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employer_org" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_rotation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_rotation_question" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_rotation_review" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_rotation_review_answer" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_rotation_review_image" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_rotation_review_thread" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."forum" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."group_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."group_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "groups_admin_insert" ON "public"."groups" FOR INSERT WITH CHECK ((("auth"."jwt"() ->> 'is_super_admin'::"text") = 'true'::"text"));



CREATE POLICY "groups_select" ON "public"."groups" FOR SELECT USING (("is_active" = true));



ALTER TABLE "public"."hospital_specialities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hospital_speciality_grades" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hospitals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."housing_ad" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."housing_ad_image" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."libro_entry" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."libro_event" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."libro_node" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."libro_section" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "members_delete" ON "public"."group_members" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "members_insert" ON "public"."group_members" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "members_select" ON "public"."group_members" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "messages_insert" ON "public"."group_messages" FOR INSERT WITH CHECK ((("auth"."uid"() = "user_id") AND (EXISTS ( SELECT 1
   FROM "public"."group_members"
  WHERE (("group_members"."group_id" = "group_messages"."group_id") AND ("group_members"."user_id" = "auth"."uid"()))))));



CREATE POLICY "messages_select" ON "public"."group_messages" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."group_members"
  WHERE (("group_members"."group_id" = "group_messages"."group_id") AND ("group_members"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."mir_simulator_searches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."post" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."push_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."question" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."raffle" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."referral" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."review" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."review_answer" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."review_image" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."review_question" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."review_question_answer" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shift_purchase_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shift_swap_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shifts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."specialities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."thread" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_email_review_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_hospital_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(character) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"("inet") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "anon";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."calculate_top_specialities"("session_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_top_specialities"("session_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_top_specialities"("session_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_update_node_counter"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_update_node_counter"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_update_node_counter"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_user_deleted_delete_auth"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_user_deleted_delete_auth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_user_deleted_delete_auth"() TO "service_role";



GRANT ALL ON FUNCTION "public"."libro_node_total_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."libro_node_total_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."libro_node_total_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_new_review"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_new_review"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_new_review"() TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_referral_code_on_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_referral_code_on_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_referral_code_on_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_app_versions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_app_versions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_app_versions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_group_member_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_group_member_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_group_member_count"() TO "service_role";












GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "service_role";









GRANT ALL ON TABLE "public"."app_versions" TO "anon";
GRANT ALL ON TABLE "public"."app_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."app_versions" TO "service_role";



GRANT ALL ON TABLE "public"."article" TO "anon";
GRANT ALL ON TABLE "public"."article" TO "authenticated";
GRANT ALL ON TABLE "public"."article" TO "service_role";



GRANT ALL ON TABLE "public"."article_like" TO "anon";
GRANT ALL ON TABLE "public"."article_like" TO "authenticated";
GRANT ALL ON TABLE "public"."article_like" TO "service_role";



GRANT ALL ON TABLE "public"."courses" TO "anon";
GRANT ALL ON TABLE "public"."courses" TO "authenticated";
GRANT ALL ON TABLE "public"."courses" TO "service_role";



GRANT ALL ON TABLE "public"."dimension_weights" TO "anon";
GRANT ALL ON TABLE "public"."dimension_weights" TO "authenticated";
GRANT ALL ON TABLE "public"."dimension_weights" TO "service_role";



GRANT ALL ON TABLE "public"."employer_account" TO "anon";
GRANT ALL ON TABLE "public"."employer_account" TO "authenticated";
GRANT ALL ON TABLE "public"."employer_account" TO "service_role";



GRANT ALL ON TABLE "public"."employer_org" TO "anon";
GRANT ALL ON TABLE "public"."employer_org" TO "authenticated";
GRANT ALL ON TABLE "public"."employer_org" TO "service_role";



GRANT ALL ON TABLE "public"."external_rotation" TO "anon";
GRANT ALL ON TABLE "public"."external_rotation" TO "authenticated";
GRANT ALL ON TABLE "public"."external_rotation" TO "service_role";



GRANT ALL ON TABLE "public"."external_rotation_question" TO "anon";
GRANT ALL ON TABLE "public"."external_rotation_question" TO "authenticated";
GRANT ALL ON TABLE "public"."external_rotation_question" TO "service_role";



GRANT ALL ON TABLE "public"."external_rotation_review" TO "anon";
GRANT ALL ON TABLE "public"."external_rotation_review" TO "authenticated";
GRANT ALL ON TABLE "public"."external_rotation_review" TO "service_role";



GRANT ALL ON TABLE "public"."external_rotation_review_answer" TO "anon";
GRANT ALL ON TABLE "public"."external_rotation_review_answer" TO "authenticated";
GRANT ALL ON TABLE "public"."external_rotation_review_answer" TO "service_role";



GRANT ALL ON TABLE "public"."external_rotation_review_image" TO "anon";
GRANT ALL ON TABLE "public"."external_rotation_review_image" TO "authenticated";
GRANT ALL ON TABLE "public"."external_rotation_review_image" TO "service_role";



GRANT ALL ON TABLE "public"."external_rotation_review_thread" TO "anon";
GRANT ALL ON TABLE "public"."external_rotation_review_thread" TO "authenticated";
GRANT ALL ON TABLE "public"."external_rotation_review_thread" TO "service_role";



GRANT ALL ON TABLE "public"."forum" TO "anon";
GRANT ALL ON TABLE "public"."forum" TO "authenticated";
GRANT ALL ON TABLE "public"."forum" TO "service_role";



GRANT ALL ON TABLE "public"."group_members" TO "anon";
GRANT ALL ON TABLE "public"."group_members" TO "authenticated";
GRANT ALL ON TABLE "public"."group_members" TO "service_role";



GRANT ALL ON TABLE "public"."group_messages" TO "anon";
GRANT ALL ON TABLE "public"."group_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."group_messages" TO "service_role";



GRANT ALL ON TABLE "public"."groups" TO "anon";
GRANT ALL ON TABLE "public"."groups" TO "authenticated";
GRANT ALL ON TABLE "public"."groups" TO "service_role";



GRANT ALL ON TABLE "public"."hospital_specialities" TO "anon";
GRANT ALL ON TABLE "public"."hospital_specialities" TO "authenticated";
GRANT ALL ON TABLE "public"."hospital_specialities" TO "service_role";



GRANT ALL ON TABLE "public"."hospital_speciality_grades" TO "anon";
GRANT ALL ON TABLE "public"."hospital_speciality_grades" TO "authenticated";
GRANT ALL ON TABLE "public"."hospital_speciality_grades" TO "service_role";



GRANT ALL ON TABLE "public"."hospitals" TO "anon";
GRANT ALL ON TABLE "public"."hospitals" TO "authenticated";
GRANT ALL ON TABLE "public"."hospitals" TO "service_role";



GRANT ALL ON TABLE "public"."housing_ad" TO "anon";
GRANT ALL ON TABLE "public"."housing_ad" TO "authenticated";
GRANT ALL ON TABLE "public"."housing_ad" TO "service_role";



GRANT ALL ON TABLE "public"."housing_ad_image" TO "anon";
GRANT ALL ON TABLE "public"."housing_ad_image" TO "authenticated";
GRANT ALL ON TABLE "public"."housing_ad_image" TO "service_role";



GRANT ALL ON TABLE "public"."job" TO "anon";
GRANT ALL ON TABLE "public"."job" TO "authenticated";
GRANT ALL ON TABLE "public"."job" TO "service_role";



GRANT ALL ON TABLE "public"."libro_entry" TO "anon";
GRANT ALL ON TABLE "public"."libro_entry" TO "authenticated";
GRANT ALL ON TABLE "public"."libro_entry" TO "service_role";



GRANT ALL ON TABLE "public"."libro_event" TO "anon";
GRANT ALL ON TABLE "public"."libro_event" TO "authenticated";
GRANT ALL ON TABLE "public"."libro_event" TO "service_role";



GRANT ALL ON TABLE "public"."libro_node" TO "anon";
GRANT ALL ON TABLE "public"."libro_node" TO "authenticated";
GRANT ALL ON TABLE "public"."libro_node" TO "service_role";



GRANT ALL ON TABLE "public"."libro_section" TO "anon";
GRANT ALL ON TABLE "public"."libro_section" TO "authenticated";
GRANT ALL ON TABLE "public"."libro_section" TO "service_role";



GRANT ALL ON TABLE "public"."mir_simulator_searches" TO "anon";
GRANT ALL ON TABLE "public"."mir_simulator_searches" TO "authenticated";
GRANT ALL ON TABLE "public"."mir_simulator_searches" TO "service_role";



GRANT ALL ON TABLE "public"."notification_deliveries" TO "anon";
GRANT ALL ON TABLE "public"."notification_deliveries" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_deliveries" TO "service_role";



GRANT ALL ON TABLE "public"."notification_types" TO "anon";
GRANT ALL ON TABLE "public"."notification_types" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_types" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."post" TO "anon";
GRANT ALL ON TABLE "public"."post" TO "authenticated";
GRANT ALL ON TABLE "public"."post" TO "service_role";



GRANT ALL ON TABLE "public"."push_tokens" TO "anon";
GRANT ALL ON TABLE "public"."push_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."push_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."question" TO "anon";
GRANT ALL ON TABLE "public"."question" TO "authenticated";
GRANT ALL ON TABLE "public"."question" TO "service_role";



GRANT ALL ON TABLE "public"."raffle" TO "anon";
GRANT ALL ON TABLE "public"."raffle" TO "authenticated";
GRANT ALL ON TABLE "public"."raffle" TO "service_role";



GRANT ALL ON TABLE "public"."referral" TO "anon";
GRANT ALL ON TABLE "public"."referral" TO "authenticated";
GRANT ALL ON TABLE "public"."referral" TO "service_role";



GRANT ALL ON TABLE "public"."review" TO "anon";
GRANT ALL ON TABLE "public"."review" TO "authenticated";
GRANT ALL ON TABLE "public"."review" TO "service_role";



GRANT ALL ON TABLE "public"."review_answer" TO "anon";
GRANT ALL ON TABLE "public"."review_answer" TO "authenticated";
GRANT ALL ON TABLE "public"."review_answer" TO "service_role";



GRANT ALL ON TABLE "public"."review_image" TO "anon";
GRANT ALL ON TABLE "public"."review_image" TO "authenticated";
GRANT ALL ON TABLE "public"."review_image" TO "service_role";



GRANT ALL ON TABLE "public"."review_question" TO "anon";
GRANT ALL ON TABLE "public"."review_question" TO "authenticated";
GRANT ALL ON TABLE "public"."review_question" TO "service_role";



GRANT ALL ON TABLE "public"."review_question_answer" TO "anon";
GRANT ALL ON TABLE "public"."review_question_answer" TO "authenticated";
GRANT ALL ON TABLE "public"."review_question_answer" TO "service_role";



GRANT ALL ON TABLE "public"."shift_purchase_requests" TO "anon";
GRANT ALL ON TABLE "public"."shift_purchase_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."shift_purchase_requests" TO "service_role";



GRANT ALL ON TABLE "public"."shift_swap_requests" TO "anon";
GRANT ALL ON TABLE "public"."shift_swap_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."shift_swap_requests" TO "service_role";



GRANT ALL ON TABLE "public"."shifts" TO "anon";
GRANT ALL ON TABLE "public"."shifts" TO "authenticated";
GRANT ALL ON TABLE "public"."shifts" TO "service_role";



GRANT ALL ON TABLE "public"."specialities" TO "anon";
GRANT ALL ON TABLE "public"."specialities" TO "authenticated";
GRANT ALL ON TABLE "public"."specialities" TO "service_role";



GRANT ALL ON TABLE "public"."speciality_dimension_score" TO "anon";
GRANT ALL ON TABLE "public"."speciality_dimension_score" TO "authenticated";
GRANT ALL ON TABLE "public"."speciality_dimension_score" TO "service_role";



GRANT ALL ON TABLE "public"."speciality_profile" TO "anon";
GRANT ALL ON TABLE "public"."speciality_profile" TO "authenticated";
GRANT ALL ON TABLE "public"."speciality_profile" TO "service_role";



GRANT ALL ON TABLE "public"."speciality_quiz_answer" TO "anon";
GRANT ALL ON TABLE "public"."speciality_quiz_answer" TO "authenticated";
GRANT ALL ON TABLE "public"."speciality_quiz_answer" TO "service_role";



GRANT ALL ON TABLE "public"."speciality_quiz_option" TO "anon";
GRANT ALL ON TABLE "public"."speciality_quiz_option" TO "authenticated";
GRANT ALL ON TABLE "public"."speciality_quiz_option" TO "service_role";



GRANT ALL ON TABLE "public"."speciality_quiz_question" TO "anon";
GRANT ALL ON TABLE "public"."speciality_quiz_question" TO "authenticated";
GRANT ALL ON TABLE "public"."speciality_quiz_question" TO "service_role";



GRANT ALL ON TABLE "public"."speciality_quiz_session" TO "anon";
GRANT ALL ON TABLE "public"."speciality_quiz_session" TO "authenticated";
GRANT ALL ON TABLE "public"."speciality_quiz_session" TO "service_role";



GRANT ALL ON TABLE "public"."thread" TO "anon";
GRANT ALL ON TABLE "public"."thread" TO "authenticated";
GRANT ALL ON TABLE "public"."thread" TO "service_role";



GRANT ALL ON TABLE "public"."user_email_review_requests" TO "anon";
GRANT ALL ON TABLE "public"."user_email_review_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."user_email_review_requests" TO "service_role";



GRANT ALL ON TABLE "public"."user_hospital_preferences" TO "anon";
GRANT ALL ON TABLE "public"."user_hospital_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."user_hospital_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."user_notification_preferences" TO "anon";
GRANT ALL ON TABLE "public"."user_notification_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."user_notification_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























