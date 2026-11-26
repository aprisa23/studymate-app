-- ============================================================================
-- StudyMate - Supabase PostgreSQL Database Schema
-- 12 Tables + Indexes + Triggers + Row Level Security (RLS) + Storage Bucket
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- Helper Trigger Function: Auto-update updated_at column
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 1. profiles (1-to-1 with auth.users)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL DEFAULT '',
  nickname text NOT NULL DEFAULT '',
  university text NOT NULL DEFAULT '',
  major text NOT NULL DEFAULT '',
  semester integer NOT NULL DEFAULT 1 CHECK (semester BETWEEN 1 AND 14),
  daily_study_target_minutes integer NOT NULL DEFAULT 120 CHECK (daily_study_target_minutes BETWEEN 15 AND 1440),
  pomodoro_focus_minutes integer NOT NULL DEFAULT 25 CHECK (pomodoro_focus_minutes BETWEEN 5 AND 180),
  pomodoro_break_minutes integer NOT NULL DEFAULT 5 CHECK (pomodoro_break_minutes BETWEEN 1 AND 60),
  avatar_path text,
  onboarding_completed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Auto-create profile row when a new user registers
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta_full_name text;
  meta_nickname text;
BEGIN
  meta_full_name := COALESCE(NEW.raw_user_meta_data->>'full_name', '');
  meta_nickname := COALESCE(
    NEW.raw_user_meta_data->>'nickname',
    NULLIF(split_part(meta_full_name, ' ', 1), ''),
    split_part(COALESCE(NEW.email, ''), '@', 1)
  );

  INSERT INTO public.profiles (id, full_name, nickname)
  VALUES (NEW.id, meta_full_name, COALESCE(meta_nickname, 'Mahasiswa'))
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 2. courses (Master Mata Kuliah)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.courses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  code text,
  lecturer text,
  room text,
  color_hex text NOT NULL DEFAULT '#8B7AE8',
  semester integer CHECK (semester IS NULL OR (semester BETWEEN 1 AND 14)),
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_courses_user_id ON public.courses(user_id);

-- ----------------------------------------------------------------------------
-- 3. class_schedules (Jadwal Kuliah Mingguan)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.class_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  course_id uuid NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  day_of_week smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),
  start_time time NOT NULL,
  end_time time NOT NULL,
  room_override text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_class_schedule_time CHECK (end_time > start_time)
);

CREATE INDEX IF NOT EXISTS idx_class_schedules_user_day
  ON public.class_schedules(user_id, day_of_week, start_time);

-- ----------------------------------------------------------------------------
-- 4. tasks (Manajemen Tugas)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  course_id uuid REFERENCES public.courses(id) ON DELETE SET NULL,
  title text NOT NULL,
  description text,
  due_at timestamptz,
  priority text NOT NULL DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high')),
  status text NOT NULL DEFAULT 'todo' CHECK (status IN ('todo', 'in_progress', 'done')),
  reminder_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tasks_user_status_due
  ON public.tasks(user_id, status, due_at);

-- ----------------------------------------------------------------------------
-- 5. academic_events (Jadwal Ujian, Kuis & Presentasi)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.academic_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  course_id uuid REFERENCES public.courses(id) ON DELETE SET NULL,
  event_type text NOT NULL DEFAULT 'exam' CHECK (event_type IN ('uts', 'uas', 'quiz', 'presentation', 'exam', 'other')),
  title text NOT NULL,
  event_at timestamptz NOT NULL,
  location text,
  notes text,
  reminder_at timestamptz,
  is_completed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_academic_events_user_event_at
  ON public.academic_events(user_id, event_at);

-- ----------------------------------------------------------------------------
-- 6. focus_sessions (Riwayat Sesi Belajar / Pomodoro)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.focus_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  course_id uuid REFERENCES public.courses(id) ON DELETE SET NULL,
  task_id uuid REFERENCES public.tasks(id) ON DELETE SET NULL,
  duration_minutes integer NOT NULL CHECK (duration_minutes BETWEEN 1 AND 600),
  mode text NOT NULL DEFAULT 'pomodoro' CHECK (mode IN ('pomodoro', 'custom')),
  started_at timestamptz NOT NULL,
  ended_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_focus_session_time CHECK (ended_at >= started_at)
);

CREATE INDEX IF NOT EXISTS idx_focus_sessions_user_started
  ON public.focus_sessions(user_id, started_at DESC);

-- ----------------------------------------------------------------------------
-- 7. notes (My Study Notes - Rich Text Delta + Plain Text + Storage Photos)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  course_id uuid REFERENCES public.courses(id) ON DELETE SET NULL,
  title text NOT NULL,
  content_delta jsonb NOT NULL DEFAULT '[]'::jsonb,
  content_plain text NOT NULL DEFAULT '',
  image_paths text[] NOT NULL DEFAULT '{}',
  is_pinned boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS trg_notes_updated_at ON public.notes;
CREATE TRIGGER trg_notes_updated_at
  BEFORE UPDATE ON public.notes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_notes_user_course_updated
  ON public.notes(user_id, course_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_notes_fts
  ON public.notes
  USING gin(to_tsvector('indonesian', coalesce(title, '') || ' ' || coalesce(content_plain, '')));

-- ----------------------------------------------------------------------------
-- 8. habits (Daftar Kebiasaan Belajar)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.habits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_habits_user_active
  ON public.habits(user_id, is_active);

-- ----------------------------------------------------------------------------
-- 9. habit_logs (Checklist Harian Kebiasaan Belajar)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.habit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  habit_id uuid NOT NULL REFERENCES public.habits(id) ON DELETE CASCADE,
  log_date date NOT NULL,
  is_completed boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_habit_logs_habit_date UNIQUE (habit_id, log_date)
);

CREATE INDEX IF NOT EXISTS idx_habit_logs_user_date
  ON public.habit_logs(user_id, log_date DESC);

-- ----------------------------------------------------------------------------
-- 10. weekly_reflections (Evaluasi & Refleksi Mingguan)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.weekly_reflections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  week_start_date date NOT NULL,
  mood_score smallint NOT NULL DEFAULT 3 CHECK (mood_score BETWEEN 1 AND 5),
  achievements text NOT NULL DEFAULT '',
  challenges text NOT NULL DEFAULT '',
  next_week_plan text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_weekly_reflections_user_week UNIQUE (user_id, week_start_date)
);

DROP TRIGGER IF EXISTS trg_weekly_reflections_updated_at ON public.weekly_reflections;
CREATE TRIGGER trg_weekly_reflections_updated_at
  BEFORE UPDATE ON public.weekly_reflections
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_weekly_reflections_user_week
  ON public.weekly_reflections(user_id, week_start_date DESC);

-- ----------------------------------------------------------------------------
-- 11. ai_conversations (Riwayat Sesi Percakapan AI Study Assistant)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  course_id uuid REFERENCES public.courses(id) ON DELETE SET NULL,
  title text NOT NULL DEFAULT 'Percakapan Baru',
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS trg_ai_conversations_updated_at ON public.ai_conversations;
CREATE TRIGGER trg_ai_conversations_updated_at
  BEFORE UPDATE ON public.ai_conversations
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_ai_conversations_user_updated
  ON public.ai_conversations(user_id, updated_at DESC);

-- ----------------------------------------------------------------------------
-- 12. ai_messages (Pesan Percakapan AI Study Assistant)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.ai_conversations(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user', 'assistant')),
  content text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_conv_created
  ON public.ai_messages(conversation_id, created_at ASC);

-- ============================================================================
-- ROW LEVEL SECURITY (RLS) - Isolasi Data Ketat per Pengguna (12 Tabel)
-- ============================================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.class_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.academic_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.focus_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.habits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.habit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_reflections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_messages ENABLE ROW LEVEL SECURITY;

-- 1. profiles (id = auth.uid())
DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own" ON public.profiles
  FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_insert_own" ON public.profiles;
CREATE POLICY "profiles_insert_own" ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_delete_own" ON public.profiles;
CREATE POLICY "profiles_delete_own" ON public.profiles
  FOR DELETE USING (auth.uid() = id);

-- 2. courses
DROP POLICY IF EXISTS "courses_all_own" ON public.courses;
CREATE POLICY "courses_all_own" ON public.courses
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 3. class_schedules (also verifies course ownership)
DROP POLICY IF EXISTS "class_schedules_select_own" ON public.class_schedules;
CREATE POLICY "class_schedules_select_own" ON public.class_schedules
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "class_schedules_insert_own" ON public.class_schedules;
CREATE POLICY "class_schedules_insert_own" ON public.class_schedules
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.courses c
      WHERE c.id = course_id AND c.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "class_schedules_update_own" ON public.class_schedules;
CREATE POLICY "class_schedules_update_own" ON public.class_schedules
  FOR UPDATE USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.courses c
      WHERE c.id = course_id AND c.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "class_schedules_delete_own" ON public.class_schedules;
CREATE POLICY "class_schedules_delete_own" ON public.class_schedules
  FOR DELETE USING (auth.uid() = user_id);

-- 4. tasks
DROP POLICY IF EXISTS "tasks_all_own" ON public.tasks;
CREATE POLICY "tasks_all_own" ON public.tasks
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 5. academic_events
DROP POLICY IF EXISTS "academic_events_all_own" ON public.academic_events;
CREATE POLICY "academic_events_all_own" ON public.academic_events
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 6. focus_sessions
DROP POLICY IF EXISTS "focus_sessions_all_own" ON public.focus_sessions;
CREATE POLICY "focus_sessions_all_own" ON public.focus_sessions
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 7. notes
DROP POLICY IF EXISTS "notes_all_own" ON public.notes;
CREATE POLICY "notes_all_own" ON public.notes
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 8. habits
DROP POLICY IF EXISTS "habits_all_own" ON public.habits;
CREATE POLICY "habits_all_own" ON public.habits
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 9. habit_logs (verifies habit ownership)
DROP POLICY IF EXISTS "habit_logs_select_own" ON public.habit_logs;
CREATE POLICY "habit_logs_select_own" ON public.habit_logs
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "habit_logs_insert_own" ON public.habit_logs;
CREATE POLICY "habit_logs_insert_own" ON public.habit_logs
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.habits h
      WHERE h.id = habit_id AND h.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "habit_logs_update_own" ON public.habit_logs;
CREATE POLICY "habit_logs_update_own" ON public.habit_logs
  FOR UPDATE USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.habits h
      WHERE h.id = habit_id AND h.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "habit_logs_delete_own" ON public.habit_logs;
CREATE POLICY "habit_logs_delete_own" ON public.habit_logs
  FOR DELETE USING (auth.uid() = user_id);

-- 10. weekly_reflections
DROP POLICY IF EXISTS "weekly_reflections_all_own" ON public.weekly_reflections;
CREATE POLICY "weekly_reflections_all_own" ON public.weekly_reflections
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 11. ai_conversations
DROP POLICY IF EXISTS "ai_conversations_all_own" ON public.ai_conversations;
CREATE POLICY "ai_conversations_all_own" ON public.ai_conversations
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 12. ai_messages (verifies conversation ownership)
DROP POLICY IF EXISTS "ai_messages_select_own" ON public.ai_messages;
CREATE POLICY "ai_messages_select_own" ON public.ai_messages
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "ai_messages_insert_own" ON public.ai_messages;
CREATE POLICY "ai_messages_insert_own" ON public.ai_messages
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.ai_conversations c
      WHERE c.id = conversation_id AND c.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "ai_messages_delete_own" ON public.ai_messages;
CREATE POLICY "ai_messages_delete_own" ON public.ai_messages
  FOR DELETE USING (auth.uid() = user_id);

-- ============================================================================
-- SUPABASE STORAGE - Private Bucket study-assets + Storage RLS Policies
-- ============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('study-assets', 'study-assets', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "study_assets_select_own" ON storage.objects;
CREATE POLICY "study_assets_select_own"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'study-assets'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "study_assets_insert_own" ON storage.objects;
CREATE POLICY "study_assets_insert_own"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'study-assets'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "study_assets_update_own" ON storage.objects;
CREATE POLICY "study_assets_update_own"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'study-assets'
    AND auth.uid()::text = (storage.foldername(name))[1]
  )
  WITH CHECK (
    bucket_id = 'study-assets'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "study_assets_delete_own" ON storage.objects;
CREATE POLICY "study_assets_delete_own"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'study-assets'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );
