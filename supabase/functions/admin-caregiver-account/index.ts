import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.21.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface RequestPayload {
  action: "create_caregiver" | "activate_caregiver_account" | "update_caregiver_account";
  caregiver_id?: string;
  name?: string;
  role?: string;
  category?: string;
  is_active?: boolean;
  email?: string;
  password?: string;
}

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed. Use POST." }, 405);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceKey) {
      return jsonResponse({ error: "Supabase environment variables are missing." }, 500);
    }

    // 1. Verifikasi Authorization Token
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return jsonResponse({ error: "Otorisasi diperlukan. Header Authorization Bearer token tidak ditemukan." }, 401);
    }
    const token = authHeader.replace("Bearer ", "").trim();

    // Klien pemanggil (dengan JWT user)
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    // Klien administrator backend (dengan SERVICE ROLE KEY)
    const adminClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false },
    });

    const { data: userData, error: userError } = await userClient.auth.getUser(token);
    if (userError || !userData?.user?.id) {
      return jsonResponse({ error: "Sesi tidak valid atau telah kedaluwarsa. Silakan masuk kembali." }, 401);
    }
    const callerUid = userData.user.id;

    // 2. Verifikasi Role Admin langsung di public.user_roles (tanpa public.is_role)
    const { data: roleRow, error: roleError } = await adminClient
      .from("user_roles")
      .select("role")
      .eq("user_id", callerUid)
      .eq("role", "admin")
      .maybeSingle();

    if (roleError || !roleRow || String(roleRow.role).toLowerCase() !== "admin") {
      return jsonResponse({ error: "Akses ditolak: Hanya administrator yang berwenang mengelola akun caregiver." }, 403);
    }

    const payload: RequestPayload = await req.json().catch(() => ({ action: "" as const }));
    const { action } = payload;

    // -------------------------------------------------------------------------
    // AKSI 1: create_caregiver (Tambah Caregiver Baru + Akun Auth)
    // -------------------------------------------------------------------------
    if (action === "create_caregiver") {
      const email = String(payload.email || "").trim().toLowerCase();
      const password = String(payload.password || "");
      const name = String(payload.name || "").trim();
      const role = String(payload.role || "").trim();
      const category = String(payload.category || "").trim() || "Sahabat Harian";
      const isActive = payload.is_active !== false;

      // Validasi awal
      if (!email || !isValidEmail(email)) {
        return jsonResponse({ error: "Alamat email login wajib diisi dengan format yang benar." }, 400);
      }
      if (!password || password.length < 6) {
        return jsonResponse({ error: "Password awal wajib diisi minimal 6 karakter." }, 400);
      }
      if (!name) {
        return jsonResponse({ error: "Nama lengkap caregiver wajib diisi." }, 400);
      }
      if (!role) {
        return jsonResponse({ error: "Role/Jabatan caregiver wajib diisi." }, 400);
      }

      // 1. Buat akun di Supabase Auth via Admin API
      const { data: authCreated, error: authError } = await adminClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          full_name: name,
          role: "caregiver",
        },
        app_metadata: {
          provider: "email",
          providers: ["email"],
          temanlansia_provisioned_role: "caregiver",
        },
      });

      if (authError || !authCreated?.user?.id) {
        return jsonResponse({ error: `Gagal membuat akun login: ${authError?.message || "Akun tidak terbentuk."}` }, 400);
      }

      const newUserId = authCreated.user.id;

      // 2. Buat profil di public.profiles
      const { error: profileError } = await adminClient
        .from("profiles")
        .upsert({ id: newUserId, full_name: name }, { onConflict: "id" });

      if (profileError) {
        // Rollback Auth user jika profil gagal
        await adminClient.auth.admin.deleteUser(newUserId);
        return jsonResponse({ error: "Gagal membuat profil pengguna. Operasi dibatalkan secara aman." }, 500);
      }

      // 3. Buat role caregiver di public.user_roles
      const { error: roleInsertError } = await adminClient
        .from("user_roles")
        .upsert({ user_id: newUserId, role: "caregiver" }, { onConflict: "user_id,role" });

      if (roleInsertError) {
        await adminClient.auth.admin.deleteUser(newUserId);
        return jsonResponse({ error: "Gagal menetapkan role caregiver. Operasi dibatalkan secara aman." }, 500);
      }

      // 4. Buat record caregiver di public.caregivers (Tanpa data palsu!)
      // city, area, price_per_shift, gender, coords tetap null (dikelola mandiri oleh caregiver)
      const { data: cgCreated, error: cgError } = await adminClient
        .from("caregivers")
        .insert({
          user_id: newUserId,
          name,
          role,
          category,
          is_active: isActive,
          languages: ["Indonesia"],
          legacy_caregiver_id: null,
          city: null,
          area: null,
          gender: null,
          price_per_shift: null,
        })
        .select("id, name, role, category, is_active, user_id")
        .single();

      if (cgError) {
        // Rollback Auth user jika insert caregivers gagal
        await adminClient.auth.admin.deleteUser(newUserId);
        return jsonResponse({
          error: `Gagal menyimpan data caregiver ke database: ${cgError.message}. Operasi dibatalkan secara aman.`,
        }, 500);
      }

      return jsonResponse({
        success: true,
        action: "caregiver_created",
        caregiver_id: cgCreated.id,
        user_id: newUserId,
        email,
        message: `Caregiver baru "${name}" dan akun login berhasil didaftarkan.`,
      });
    }

    // -------------------------------------------------------------------------
    // AKSI 2: activate_caregiver_account (Hubungkan Akun untuk Caregiver Lama)
    // -------------------------------------------------------------------------
    if (action === "activate_caregiver_account") {
      const caregiverId = String(payload.caregiver_id || "").trim();
      const email = String(payload.email || "").trim().toLowerCase();
      const password = String(payload.password || "");

      if (!caregiverId) {
        return jsonResponse({ error: "caregiver_id wajib disertakan." }, 400);
      }
      if (!email || !isValidEmail(email)) {
        return jsonResponse({ error: "Alamat email login wajib diisi dengan format yang benar." }, 400);
      }
      if (!password || password.length < 6) {
        return jsonResponse({ error: "Password awal wajib diisi minimal 6 karakter." }, 400);
      }

      // Pastikan record caregiver ada dan user_id masih null
      const { data: existingCg, error: cgFindError } = await adminClient
        .from("caregivers")
        .select("id, name, user_id, legacy_caregiver_id")
        .eq("id", caregiverId)
        .maybeSingle();

      if (cgFindError || !existingCg) {
        return jsonResponse({ error: "Data caregiver tidak ditemukan." }, 404);
      }

      if (existingCg.user_id) {
        return jsonResponse({ error: "Caregiver ini sudah memiliki akun login aktif. Operasi dibatalkan." }, 400);
      }

      // 1. Buat akun Auth via Admin API
      const { data: authCreated, error: authError } = await adminClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          full_name: existingCg.name,
          role: "caregiver",
        },
        app_metadata: {
          provider: "email",
          providers: ["email"],
          temanlansia_provisioned_role: "caregiver",
        },
      });

      if (authError || !authCreated?.user?.id) {
        return jsonResponse({ error: `Gagal membuat akun Auth: ${authError?.message || "Akun tidak terbentuk."}` }, 400);
      }

      const newUserId = authCreated.user.id;

      // 2. Buat profil dan periksa error
      const { error: profileErr } = await adminClient
        .from("profiles")
        .upsert({ id: newUserId, full_name: existingCg.name }, { onConflict: "id" });

      if (profileErr) {
        await adminClient.auth.admin.deleteUser(newUserId);
        return jsonResponse({ error: "Gagal membuat profil pengguna untuk caregiver. Operasi dibatalkan." }, 500);
      }

      // 3. Buat user_roles dan periksa error
      const { error: roleErr } = await adminClient
        .from("user_roles")
        .upsert({ user_id: newUserId, role: "caregiver" }, { onConflict: "user_id,role" });

      if (roleErr) {
        await adminClient.auth.admin.deleteUser(newUserId);
        return jsonResponse({ error: "Gagal menetapkan role pengguna untuk caregiver. Operasi dibatalkan." }, 500);
      }

      // 4. Update caregiver dengan kondisi ketat user_id IS NULL (Mencegah Race Condition)
      const { data: updatedRows, error: linkError } = await adminClient
        .from("caregivers")
        .update({ user_id: newUserId, updated_at: new Date().toISOString() })
        .eq("id", caregiverId)
        .is("user_id", null)
        .select("id, user_id");

      if (linkError || !updatedRows || updatedRows.length !== 1) {
        // Rollback Auth user jika tidak ada row yang terupdate (atau sudah terisi bersamaan)
        await adminClient.auth.admin.deleteUser(newUserId);
        return jsonResponse({
          error: "Gagal menautkan akun login ke caregiver (kemungkinan akun sudah diaktifkan oleh request lain). Operasi dibatalkan.",
        }, 409);
      }

      return jsonResponse({
        success: true,
        action: "account_activated",
        caregiver_id: caregiverId,
        user_id: newUserId,
        email,
        message: `Akun login untuk ${existingCg.name} berhasil diaktifkan.`,
      });
    }

    // -------------------------------------------------------------------------
    // AKSI 3: update_caregiver_account (Edit Profil & Kredensial Caregiver)
    // -------------------------------------------------------------------------
    if (action === "update_caregiver_account") {
      const caregiverId = String(payload.caregiver_id || "").trim();
      if (!caregiverId) {
        return jsonResponse({ error: "caregiver_id wajib disertakan." }, 400);
      }

      // 1. Validasi Caregiver Terdaftar
      const { data: cgRow, error: cgFindError } = await adminClient
        .from("caregivers")
        .select("id, name, role, category, is_active, user_id")
        .eq("id", caregiverId)
        .maybeSingle();

      if (cgFindError || !cgRow) {
        return jsonResponse({ error: "Data caregiver tidak ditemukan." }, 404);
      }

      // 2. Proteksi Keamanan: Jangan izinkan modifikasi akun admin melalui fitur caregiver
      if (cgRow.user_id) {
        const { data: targetRole } = await adminClient
          .from("user_roles")
          .select("role")
          .eq("user_id", cgRow.user_id)
          .eq("role", "admin")
          .maybeSingle();

        if (targetRole) {
          return jsonResponse({
            error: "Akses ditolak: Tidak dapat memodifikasi akun dengan hak administrator melalui pengelolaan caregiver.",
          }, 403);
        }
      }

      // 3. Pre-Validasi Kredensial Sebelum Menjalankan Mutasi
      const newEmail = payload.email !== undefined ? String(payload.email).trim().toLowerCase() : "";
      const newPassword = payload.password !== undefined ? String(payload.password) : "";

      if (newEmail && !isValidEmail(newEmail)) {
        return jsonResponse({ error: "Format email baru tidak valid." }, 400);
      }
      if (newPassword && newPassword.length < 6) {
        return jsonResponse({ error: "Password baru minimal 6 karakter." }, 400);
      }

      // 4. Update Kredensial Auth Terlebih Dahulu (Auth-First Pattern)
      let emailUpdated = false;
      let passwordUpdated = false;

      if (cgRow.user_id && (newEmail || newPassword)) {
        const authUpdates: Record<string, unknown> = {};
        if (newEmail) {
          authUpdates.email = newEmail;
          authUpdates.email_confirm = true;
          emailUpdated = true;
        }
        if (newPassword) {
          authUpdates.password = newPassword;
          passwordUpdated = true;
        }

        const { error: authUpdateError } = await adminClient.auth.admin.updateUserById(
          cgRow.user_id,
          authUpdates
        );

        if (authUpdateError) {
          return jsonResponse({
            error: `Pembaruan kredensial Auth gagal: ${authUpdateError.message}. Perubahan profil dibatalkan.`,
          }, 400);
        }
      }

      // 5. Update Profil Operasional di public.caregivers (Tanpa city, area, price_per_shift)
      const cgPatch: Record<string, unknown> = {
        updated_at: new Date().toISOString(),
      };
      if (payload.name !== undefined && String(payload.name).trim()) cgPatch.name = String(payload.name).trim();
      if (payload.role !== undefined && String(payload.role).trim()) cgPatch.role = String(payload.role).trim();
      if (payload.category !== undefined && String(payload.category).trim()) cgPatch.category = String(payload.category).trim();
      if (payload.is_active !== undefined) cgPatch.is_active = Boolean(payload.is_active);

      const { error: cgUpdateError } = await adminClient
        .from("caregivers")
        .update(cgPatch)
        .eq("id", caregiverId);

      if (cgUpdateError) {
        return jsonResponse({
          error: `Kredensial diperbarui, tetapi gagal memperbarui profil database: ${cgUpdateError.message}`,
        }, 500);
      }

      // 6. Sinkronisasi nama ke profiles jika ada user_id
      if (cgRow.user_id && cgPatch.name) {
        await adminClient.from("profiles").update({ full_name: cgPatch.name }).eq("id", cgRow.user_id);
      }

      return jsonResponse({
        success: true,
        action: "caregiver_updated",
        caregiver_id: caregiverId,
        user_id: cgRow.user_id || null,
        email_updated: emailUpdated,
        password_updated: passwordUpdated,
        message: "Profil caregiver dan akun login berhasil diperbarui.",
      });
    }

    return jsonResponse({ error: `Aksi "${action}" tidak dikenal.` }, 400);
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : "Terjadi kesalahan internal server.";
    return jsonResponse({ error: `Kesalahan server: ${errorMsg}` }, 500);
  }
});
