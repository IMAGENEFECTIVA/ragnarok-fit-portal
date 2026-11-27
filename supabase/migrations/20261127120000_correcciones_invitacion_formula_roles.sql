-- =====================================================================
-- Correcciones (27-11-2026)
--  1. Invitar clientes por correo (antes siempre decía "no existe").
--  2. Lista de clientes del preparador con invitaciones pendientes.
--  3. El cliente puede ver el nombre del preparador que lo invita.
--  4. % de grasa corporal: fórmula de la Marina de EE. UU. en versión
--     métrica (antes se usaban centímetros en la fórmula de pulgadas,
--     lo que daba unos 6 puntos de más) y recálculo de mediciones.
--  5. Las mediciones no se pueden modificar en ningún campo calculado.
-- =====================================================================

-- ---------- 1. Invitar cliente por correo ----------
CREATE OR REPLACE FUNCTION public.invite_client_by_email(_email text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client uuid;
  v_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'trainer'
  ) THEN
    RAISE EXCEPTION 'Solo un preparador puede invitar clientes.' USING ERRCODE = '42501';
  END IF;

  SELECT id, full_name INTO v_client, v_name
  FROM public.profiles
  WHERE lower(email) = lower(trim(_email))
  LIMIT 1;

  IF v_client IS NULL THEN
    RAISE EXCEPTION 'No existe un usuario con ese correo. Pídele registrarse primero.' USING ERRCODE = 'P0002';
  END IF;
  IF v_client = auth.uid() THEN
    RAISE EXCEPTION 'No puedes invitarte a ti mismo.' USING ERRCODE = '22023';
  END IF;

  -- Si ya existe la relación, el índice único devuelve el error 23505.
  INSERT INTO public.trainer_clients (trainer_id, client_id, requested_by)
  VALUES (auth.uid(), v_client, auth.uid());

  RETURN v_name;
END;
$$;
REVOKE ALL ON FUNCTION public.invite_client_by_email(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.invite_client_by_email(text) TO authenticated;

-- ---------- 2. Clientes del preparador (aceptados y pendientes) ----------
CREATE OR REPLACE FUNCTION public.my_trainer_clients()
RETURNS TABLE (client_id uuid, full_name text, email text, accepted_at timestamptz, created_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT tc.client_id, p.full_name, p.email, tc.accepted_at, tc.created_at
  FROM public.trainer_clients tc
  JOIN public.profiles p ON p.id = tc.client_id
  WHERE tc.trainer_id = auth.uid()
  ORDER BY p.full_name;
$$;
REVOKE ALL ON FUNCTION public.my_trainer_clients() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_trainer_clients() TO authenticated;

-- ---------- 3. El cliente ve el perfil del preparador que lo invitó ----------
DROP POLICY IF EXISTS profiles_client_sees_trainer ON public.profiles;
CREATE POLICY profiles_client_sees_trainer ON public.profiles
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.trainer_clients tc
    WHERE tc.trainer_id = profiles.id AND tc.client_id = auth.uid()
  ));

-- ---------- 4. Fórmula de % de grasa corregida ----------
CREATE OR REPLACE FUNCTION public.navy_body_fat(_sex text, _height_cm numeric, _waist_cm numeric, _neck_cm numeric, _hip_cm numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE bf numeric;
BEGIN
  IF _height_cm IS NULL OR _height_cm <= 0 OR _waist_cm IS NULL OR _neck_cm IS NULL THEN
    RETURN NULL;
  END IF;
  IF _sex = 'male' THEN
    IF _waist_cm - _neck_cm <= 0 THEN RETURN NULL; END IF;
    bf := 495 / (1.0324 - 0.19077 * log(10, _waist_cm - _neck_cm) + 0.15456 * log(10, _height_cm)) - 450;
  ELSIF _sex = 'female' THEN
    IF _hip_cm IS NULL OR _waist_cm + _hip_cm - _neck_cm <= 0 THEN RETURN NULL; END IF;
    bf := 495 / (1.29579 - 0.35004 * log(10, _waist_cm + _hip_cm - _neck_cm) + 0.22100 * log(10, _height_cm)) - 450;
  ELSE
    RETURN NULL;
  END IF;
  IF bf > 2 AND bf < 70 THEN RETURN round(bf, 2); END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.navy_body_fat(text, numeric, numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.navy_body_fat(text, numeric, numeric, numeric, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.calculate_measurement_metrics()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  p RECORD;
  h_m numeric; h_cm numeric; act numeric; bf numeric; lean numeric; fat numeric;
BEGIN
  SELECT age, sex, height_cm INTO p FROM public.physical_profiles WHERE user_id = NEW.user_id;
  IF p IS NULL OR p.height_cm IS NULL OR p.age IS NULL OR p.sex IS NULL THEN
    RETURN NEW;
  END IF;

  h_cm := p.height_cm;
  h_m  := h_cm / 100.0;

  NEW.imc := round(NEW.weight_kg / (h_m * h_m), 2);
  NEW.healthy_weight_kg := round(22 * h_m * h_m, 2);

  -- Tasa metabólica basal (Mifflin-St Jeor)
  IF p.sex = 'male' THEN
    NEW.bmr := round(10 * NEW.weight_kg + 6.25 * h_cm - 5 * p.age + 5, 2);
  ELSE
    NEW.bmr := round(10 * NEW.weight_kg + 6.25 * h_cm - 5 * p.age - 161, 2);
  END IF;

  act := CASE NEW.activity_level
    WHEN 'sedentary' THEN 1.2
    WHEN 'light' THEN 1.375
    WHEN 'moderate' THEN 1.55
    WHEN 'high' THEN 1.725
    WHEN 'very_high' THEN 1.9
  END;
  NEW.daily_calories := round(NEW.bmr * act, 2);

  bf := public.navy_body_fat(p.sex, h_cm, NEW.waist_cm, NEW.neck_cm, NEW.hip_cm);
  NEW.body_fat_pct := bf;
  IF bf IS NOT NULL THEN
    fat := NEW.weight_kg * bf / 100.0;
    lean := NEW.weight_kg - fat;
    NEW.fat_mass_kg := round(fat, 2);
    NEW.lean_mass_kg := round(lean, 2);
    -- Estimaciones aproximadas (se muestran como "estimado" en la app)
    NEW.water_pct := round((lean * 0.732 / NEW.weight_kg) * 100, 2);
    NEW.muscle_mass_kg := round(lean * 0.5, 2);
  ELSE
    NEW.fat_mass_kg := NULL;
    NEW.lean_mass_kg := NULL;
    NEW.water_pct := NULL;
    NEW.muscle_mass_kg := NULL;
  END IF;

  -- Índice aproximado (se muestra como "estimado" en la app)
  NEW.visceral_fat := round(greatest(1, least(30, ((NEW.waist_cm / h_cm) * 20) + (p.age * 0.05) - 8)), 1);

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.calculate_measurement_metrics() FROM PUBLIC, anon, authenticated;

-- ---------- 5. Bloqueo completo de mediciones ----------
-- Solo se permite marcar una medición como eliminada (una vez).
CREATE OR REPLACE FUNCTION public.measurements_lock_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (to_jsonb(NEW) - 'deleted_at' - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'deleted_at' - 'updated_at') THEN
    RAISE EXCEPTION 'Las mediciones registradas no pueden editarse';
  END IF;
  IF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
    RAISE EXCEPTION 'Una medición eliminada no puede restaurarse';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ---------- Recálculo de las mediciones existentes ----------
-- Usa los datos actuales del perfil físico de cada usuario.
ALTER TABLE public.measurements DISABLE TRIGGER measurements_lock_update_trigger;

WITH calc AS (
  SELECT m.id, m.weight_kg,
         public.navy_body_fat(p.sex, p.height_cm, m.waist_cm, m.neck_cm, m.hip_cm) AS bf
  FROM public.measurements m
  JOIN public.physical_profiles p ON p.user_id = m.user_id
  WHERE p.height_cm IS NOT NULL AND p.sex IS NOT NULL AND p.age IS NOT NULL
)
UPDATE public.measurements m
SET body_fat_pct   = calc.bf,
    fat_mass_kg    = CASE WHEN calc.bf IS NULL THEN NULL ELSE round(calc.weight_kg * calc.bf / 100, 2) END,
    lean_mass_kg   = CASE WHEN calc.bf IS NULL THEN NULL ELSE round(calc.weight_kg - calc.weight_kg * calc.bf / 100, 2) END,
    water_pct      = CASE WHEN calc.bf IS NULL THEN NULL ELSE round(((calc.weight_kg - calc.weight_kg * calc.bf / 100) * 0.732 / calc.weight_kg) * 100, 2) END,
    muscle_mass_kg = CASE WHEN calc.bf IS NULL THEN NULL ELSE round((calc.weight_kg - calc.weight_kg * calc.bf / 100) * 0.5, 2) END
FROM calc
WHERE calc.id = m.id;

ALTER TABLE public.measurements ENABLE TRIGGER measurements_lock_update_trigger;
