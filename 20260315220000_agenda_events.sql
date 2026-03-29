CREATE TABLE IF NOT EXISTS "public"."agenda_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "event_date" "date",
    "end_date" "date",
    "start_time" time without time zone,
    "end_time" time without time zone,
    "all_day" boolean DEFAULT true NOT NULL,
    "notes" "text",
    "metadata" "jsonb" DEFAULT '{}'::jsonb NOT NULL,
    "source_shift_id" "uuid",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "agenda_events_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "agenda_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['shift'::"text", 'course'::"text", 'research'::"text", 'study'::"text", 'conference'::"text", 'day_off'::"text"]))),
    CONSTRAINT "agenda_events_date_range_check" CHECK ((("end_date" IS NULL) OR ("event_date" IS NULL) OR ("end_date" >= "event_date")))
);

ALTER TABLE "public"."agenda_events" OWNER TO "postgres";

ALTER TABLE ONLY "public"."agenda_events"
    ADD CONSTRAINT "agenda_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agenda_events"
    ADD CONSTRAINT "agenda_events_source_shift_id_fkey" FOREIGN KEY ("source_shift_id") REFERENCES "public"."shifts"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."agenda_events"
    ADD CONSTRAINT "agenda_events_source_shift_id_key" UNIQUE ("source_shift_id");

CREATE INDEX IF NOT EXISTS "agenda_events_user_date_idx" ON "public"."agenda_events" USING "btree" ("user_id", "event_date");
CREATE INDEX IF NOT EXISTS "agenda_events_user_type_idx" ON "public"."agenda_events" USING "btree" ("user_id", "event_type");

INSERT INTO "public"."agenda_events" (
    "user_id",
    "event_type",
    "title",
    "event_date",
    "all_day",
    "notes",
    "metadata",
    "source_shift_id",
    "created_at",
    "updated_at"
)
SELECT
    s."user_id",
    'shift',
    'Guardia',
    s."date",
    true,
    s."notes",
    jsonb_strip_nulls(
        jsonb_build_object(
            'legacy_shift_type', s."type",
            'price_eur', s."price_eur",
            'duration_label', '24h'
        )
    ),
    s."id",
    COALESCE(s."created_at", NOW()),
    COALESCE(s."created_at", NOW())
FROM "public"."shifts" s
ON CONFLICT ("source_shift_id") DO UPDATE
SET
    "event_date" = EXCLUDED."event_date",
    "notes" = EXCLUDED."notes",
    "metadata" = EXCLUDED."metadata",
    "updated_at" = NOW();

ALTER TABLE "public"."agenda_events" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "allow_all_agenda_events" ON "public"."agenda_events" USING (true) WITH CHECK (true);

GRANT ALL ON TABLE "public"."agenda_events" TO "anon";
GRANT ALL ON TABLE "public"."agenda_events" TO "authenticated";
GRANT ALL ON TABLE "public"."agenda_events" TO "service_role";
