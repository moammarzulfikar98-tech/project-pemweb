(() => {
  'use strict';

  const config = window.TEMANLANSIA_SUPABASE_CONFIG || {};
  const url = String(config.url || '').replace(/\/rest\/v1\/?$/, '').replace(/\/$/, '');
  const key = String(config.publishableKey || '');
  const configured = /^https:\/\/[^\s]+\.supabase\.co$/.test(url) && key && !/^YOUR_/.test(key);

  let clientInstance;

  function requireClient() {
    if (!configured) throw new Error('Supabase belum dikonfigurasi lokal.');
    if (!window.supabase || typeof window.supabase.createClient !== 'function') {
      throw new Error('Supabase Client gagal dimuat.');
    }
    if (!clientInstance) clientInstance = window.supabase.createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
    return clientInstance;
  }

  const safeUserLog = user => user ? { id: user.id, email: user.email || null, role: user.role || null } : null;

  async function getAuthenticatedUser(client = requireClient()) {
    const { data, error } = await client.auth.getUser();
    if (error) throw new Error(`User gagal dibaca: ${error.message}`);
    if (!data?.user?.id) throw new Error('Sesi login tidak memiliki user ID.');
    console.debug('[TemanLansia Auth] user aktif', safeUserLog(data.user));
    return data.user;
  }

  async function getCaregivers() {
    const client = requireClient();
    const { data, error } = await client.rpc('get_public_caregivers');
    if (error) throw new Error(`Supabase caregivers: ${error.message}`);
    if (!Array.isArray(data) || data.length === 0) {
      throw new Error(`Tidak ada data caregiver aktif dari Supabase.`);
    }

    return data.map(row => ({
      id: row.legacy_caregiver_id,
      uuid: row.id,
      name: row.name,
      role: row.role,
      city: row.city,
      area: row.area,
      category: row.category,
      gender: row.gender,
      age: row.age,
      languages: Array.isArray(row.languages) ? row.languages : [],
      price: (row.price_per_shift != null && Number(row.price_per_shift) > 0)
        ? `Rp ${Number(row.price_per_shift).toLocaleString('id-ID')}/shift`
        : 'Belum diatur',
      price_val: (row.price_per_shift != null && Number(row.price_per_shift) > 0) ? Number(row.price_per_shift) : null,
      pricePerShift: (row.price_per_shift != null && Number(row.price_per_shift) > 0) ? Number(row.price_per_shift) : null,
      rating: Number(row.rating),
      reviews: row.reviews_count,
      reviewsCount: row.reviews_count,
      badge: row.badge || '',
      coords: null,
      image: row.photo_path || '',
      photoUrl: row.photo_path || '',
      desc: row.description || '',
      bio: row.description || '',
      tagline: row.role || '',
      areaDetail: row.area || '',
      location: row.city || '',
      skillType: row.category || '',
      source: 'supabase'
    }));
  }

  function anonymousIdempotencyKey(payload) {
    const fingerprint = JSON.stringify(Object.keys(payload).filter(key => key !== 'p_idempotency_key').sort().map(key => [key, payload[key] ?? null]));
    const storageKey = 'temanlansia-booking-idempotency-key';
    let stored = null;
    try { stored = JSON.parse(sessionStorage.getItem(storageKey) || 'null'); } catch { /* discard legacy malformed state */ }
    console.debug('[TemanLansia Idempotency] key gen', { fingerprint, stored: stored?.fingerprint });
    if (stored?.key && stored.fingerprint === fingerprint) return stored.key;
    const created = crypto.randomUUID();
    sessionStorage.setItem(storageKey, JSON.stringify({ key: created, fingerprint }));
    return created;
  }

  function isAnonymousUser(user) {
    return user?.is_anonymous === true || user?.app_metadata?.provider === 'anonymous';
  }

  async function getCurrentSessionUser(client) {
    const { data, error } = await client.auth.getSession();
    if (error) throw new Error(`Session booking gagal dibaca: ${error.message}`);
    return data?.session?.user || null;
  }

  async function assertCustomerRole(client, user) {
    if (!user?.id || isAnonymousUser(user)) throw new Error('Login customer diperlukan.');
    const { data, error } = await client
      .from('user_roles')
      .select('role')
      .eq('user_id', user.id)
      .eq('role', 'customer')
      .limit(1);
    if (error) throw new Error(`Role customer gagal diverifikasi: ${error.message}`);
    if (!Array.isArray(data) || !data.some(row => row.role === 'customer')) {
      throw new Error('Akun belum memiliki role customer.');
    }
  }

  function buildBookingRpcPayload(params) {
    const allowed = [
      'p_idempotency_key', 'p_caregiver_id', 'p_customer_name',
      'p_emergency_contact_name', 'p_emergency_contact_phone', 'p_elder_name',
      'p_elder_age', 'p_elder_gender', 'p_elder_conditions',
      'p_elder_allergies', 'p_elder_mobility', 'p_elder_medical_notes',
      'p_address_line', 'p_city', 'p_province', 'p_postal_code',
      'p_latitude', 'p_longitude', 'p_access_notes', 'p_start_at', 'p_end_at'
    ];
    const payload = Object.fromEntries(allowed.map(key => [key, params[key]]));
    payload.p_idempotency_key = payload.p_idempotency_key || anonymousIdempotencyKey(payload);
    if (!payload.p_caregiver_id) throw new Error('UUID caregiver belum tersedia dari katalog Supabase. Fallback katalog tidak dapat membuat booking.');
    if (!payload.p_start_at || !payload.p_end_at) throw new Error('Jadwal booking belum lengkap.');
    if (!(new Date(payload.p_start_at) < new Date(payload.p_end_at))) throw new Error('Rentang jadwal booking tidak valid.');
    return payload;
  }

  async function invokeBookingRpc(client, rpcName, params, user) {
    const payload = buildBookingRpcPayload(params);
    const { data, error } = await client.rpc(rpcName, payload);
    if (error) throw new Error(`Booking Supabase gagal: ${error.message}`);
    const result = Array.isArray(data) ? data[0] : data;
    if (!result?.booking_id) throw new Error('RPC tidak mengembalikan booking_id.');
    return { ...result, userId: user.id, idempotencyKey: payload.p_idempotency_key };
  }

  async function createAnonymousBooking(params) {
    const client = requireClient();
    let activeUser = await getCurrentSessionUser(client);
    if (activeUser && !isAnonymousUser(activeUser)) {
      throw new Error('Sesi customer aktif; booking harus memakai create_customer_booking.');
    }
    if (!activeUser) {
      const { data, error } = await client.auth.signInAnonymously();
      if (error) throw new Error(`Anonymous Auth gagal: ${error.message}`);
      activeUser = data?.user || await getAuthenticatedUser(client);
    }
    if (!activeUser?.id || !isAnonymousUser(activeUser)) throw new Error('Anonymous session tidak valid.');
    return invokeBookingRpc(client, 'create_anonymous_booking', params, activeUser);
  }

  async function createCustomerBooking(params) {
    const client = requireClient();
    const activeUser = await getCurrentSessionUser(client);
    if (!activeUser?.id || isAnonymousUser(activeUser)) throw new Error('Login customer diperlukan.');
    await assertCustomerRole(client, activeUser);
    return invokeBookingRpc(client, 'create_customer_booking', params, activeUser);
  }

  async function createBooking(params) {
    const client = requireClient();
    const activeUser = await getCurrentSessionUser(client);
    return activeUser && !isAnonymousUser(activeUser)
      ? createCustomerBooking(params)
      : createAnonymousBooking(params);
  }

  async function getBookingPaymentSummary(bookingId) {
    const client = requireClient();
    const id = String(bookingId || '').trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) throw new Error('booking_id tidak valid untuk query nominal server.');
    const { data: sessionData, error: sessionError } = await client.auth.getSession();
    if (sessionError) throw new Error(`Session booking gagal dibaca: ${sessionError.message}`);
    const userId = sessionData?.session?.user?.id || null;
    if (!userId) throw new Error('Sesi Supabase booking tidak ditemukan pada origin ini. Buka kembali 127.0.0.1:8765 dengan session existing; user baru tidak dibuat.');
    const { data, error } = await client.from('bookings').select('id,total_amount,status').eq('id', id).limit(2);
    if (error) throw new Error(`Nominal booking gagal dibaca: ${error.message}`);
    const rows = Array.isArray(data) ? data : [];
    console.debug('[TemanLansia Booking] payment summary read', { bookingId: id, rowCount: rows.length, userId, sessionPresent: Boolean(userId), queryError: null });
    if (rows.length === 0) throw new Error(`Booking tidak terlihat pada session/RLS saat membaca ID ${id}; ID tidak ditemukan atau akses SELECT ditolak.`);
    if (rows.length > 1) throw new Error(`Anomali booking: query ID ${id} mengembalikan ${rows.length} baris.`);
    const row = rows[0];
    if (String(row.id) !== id) throw new Error('booking_id hasil query berbeda dari ID yang diminta.');
    const amount = Number(row.total_amount);
    if (!Number.isFinite(amount) || amount < 0) throw new Error('Data total_amount server tidak valid.');
    return { id: row.id, total_amount: amount, status: row.status, rowCount: 1, sessionPresent: Boolean(userId) };
  }

  async function confirmMyDemoPayment({ bookingId, method }) {
    const client = requireClient();
    const id = String(bookingId || '').trim();
    const allowed = { qris: 'qris_demo', virtual_account: 'transfer_demo', qris_demo: 'qris_demo', transfer_demo: 'transfer_demo' };
    const paymentMethod = allowed[String(method || '').trim()];
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) throw new Error('ID booking tidak valid.');
    if (!paymentMethod) throw new Error('Metode pembayaran simulasi tidak valid.');
    const { data, error } = await client.rpc('confirm_my_demo_payment', { p_booking_id: id, p_method: paymentMethod });
    if (error) throw new Error(`Konfirmasi pembayaran simulasi gagal: ${error.message}`);
    const result = Array.isArray(data) ? data[0] : data;
    if (!result || String(result.booking_id) !== id || result.payment_status !== 'paid_demo') {
      throw new Error('Server tidak mengembalikan status paid_demo.');
    }
    return result;
  }

  async function confirmMyAssignedBooking(bookingId) {
    const client = requireClient();
    const id = String(bookingId || '').trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
      throw new Error('ID booking tidak valid.');
    }
    const { session } = await getSession();
    if (!session?.user?.id) throw new Error('Login caregiver diperlukan.');
    const { data, error } = await client.rpc('confirm_my_assigned_booking', { p_booking_id: id });
    if (error) {
      if (error.code === '42501') throw new Error('Login caregiver diperlukan.');
      if (error.code === 'P0002') throw new Error('Booking tidak ditemukan atau bukan tugas caregiver ini.');
      if (error.code === 'P0001') throw new Error(error.message.includes('payment')
        ? 'Booking belum memiliki pembayaran terverifikasi.'
        : 'Booking sudah diproses atau tidak menunggu konfirmasi.');
      throw new Error(`Konfirmasi booking gagal: ${error.message}`);
    }
    return Array.isArray(data) ? data[0] : data;
  }

  async function transitionBooking({ bookingId, to }) {
    const client = requireClient();
    const allowed = ['confirmed', 'cancelled', 'in_progress', 'completed'];
    if (!allowed.includes(to)) throw new Error('Transisi booking tidak valid.');
    const { data, error } = await client.rpc('transition_booking', { p_booking: bookingId, p_to: to });
    if (error) throw new Error(`Transisi booking gagal: ${error.message}`);
    return Array.isArray(data) ? data[0] : data;
  }

  async function getAdminPendingBookings() {
    const { client, session } = await getSession();
    if (!session?.user?.id || isAnonymousUser(session.user)) throw new Error('Login admin diperlukan.');
    const { data: roles, error: roleError } = await client.from('user_roles').select('role').eq('user_id', session.user.id).eq('role', 'admin').limit(1);
    if (roleError) throw new Error(`Role admin gagal diverifikasi: ${roleError.message}`);
    if (!Array.isArray(roles) || !roles.some(row => row.role === 'admin')) throw new Error('Akses ditolak. Akun bukan admin.');
    const { data, error } = await client.from('bookings').select('id,start_at,end_at,status,total_amount,created_at,payments(id,status,method,amount)').eq('status', 'pending').order('created_at', { ascending: false });
    if (error) throw new Error(`Daftar booking admin gagal dibaca. RLS membutuhkan RPC read-only bila akses admin belum tersedia: ${error.message}`);
    return (Array.isArray(data) ? data : []).map(row => ({ ...row, payment: Array.isArray(row.payments) ? row.payments[0] || null : row.payments || null }));
  }

  async function confirmDemoPaymentAsAdmin(bookingId, amount) {
    const client = requireClient();
    const id = String(bookingId || '').trim();
    const value = Number(amount);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) throw new Error('ID booking tidak valid.');
    if (!Number.isFinite(value) || value < 0) throw new Error('Nominal pembayaran demo tidak valid.');
    const { data, error } = await client.rpc('confirm_demo_payment_as_admin', { p_booking_id: id, p_amount: value });
    if (error) throw new Error(`Konfirmasi pembayaran demo gagal: ${error.message}`);
    return Array.isArray(data) ? data[0] : data;
  }

  async function createDemoPayment({ bookingId, method, amount, outcome = 'paid_demo' }) {
    const client = requireClient();
    if (!bookingId || !['qris_demo', 'transfer_demo', 'cash_demo'].includes(method)) throw new Error('Data pembayaran demo tidak valid.');
    if (!['paid_demo', 'failed_demo'].includes(outcome)) throw new Error('Hasil pembayaran demo tidak valid.');

    if (outcome !== 'paid_demo') throw new Error('Konfirmasi pembayaran demo hanya dapat dilakukan admin terverifikasi.');
    return confirmDemoPaymentAsAdmin(bookingId, amount);
  }

  async function submitReview({ bookingId, rating, comment = '' }) {
    const client = requireClient();
    const value = Number(rating);
    if (!Number.isInteger(value) || value < 1 || value > 5) throw new Error('Rating harus bilangan bulat 1–5.');
    const { data: booking, error: bookingError } = await client.from('bookings').select('id,status').eq('id', bookingId).single();
    if (bookingError) throw new Error(`Booking tidak ditemukan: ${bookingError.message}`);
    if (booking.status !== 'completed') throw new Error('Review hanya dapat diberikan setelah booking completed.');
    const { data, error } = await client.from('reviews').insert({ booking_id: bookingId, rating: value, comment: String(comment).trim() || null }).select('id,booking_id,rating,comment').single();
    if (error) throw new Error(`Review gagal: ${error.message}`);
    return data;
  }

  async function getSession() {
    const client = requireClient();
    const { data, error } = await client.auth.getSession();
    if (error) throw new Error(`Session gagal dibaca: ${error.message}`);
    if (data.session?.user) console.debug('[TemanLansia Auth] session aktif', safeUserLog(data.session.user));
    return { client, session: data.session };
  }

  async function getCustomerContext() {
    const { client, session } = await getSession();
    if (!session?.user?.id) throw new Error('Login customer diperlukan.');
    await assertCustomerRole(client, session.user);
    const customerId = session.user.id;
    const [{ data: customer, error: customerError }, { data: elders, error: elderError }] = await Promise.all([
      client.from('customers').select('id').eq('id', customerId).single(),
      client.from('elder_profiles').select('id,customer_id,name,mobility,conditions').eq('customer_id', customerId).eq('is_active', true)
    ]);
    if (customerError) throw new Error(`Customer context gagal: ${customerError.message}`);
    if (elderError) throw new Error(`Profil lansia gagal: ${elderError.message}`);
    const elderIds = (elders || []).map(item => item.id);
    const { data: addresses, error: addressError } = elderIds.length
      ? await client.from('elder_addresses').select('id,elder_profile_id,address_line,city,province,postal_code,latitude,longitude,is_default').in('elder_profile_id', elderIds)
      : { data: [], error: null };
    if (addressError) throw new Error(`Alamat lansia gagal: ${addressError.message}`);
    return { customer, elders: elders || [], addresses: addresses || [], session };
  }

  async function findCaregiverForUser(client, user) {
    const userId = String(user?.id || '').trim();
    if (!userId) throw new Error('Sesi login tidak memiliki user ID.');
    console.debug('[TemanLansia Auth] mencari caregiver', { userId });
    const { data, error } = await client
      .from('caregivers')
      .select('id,legacy_caregiver_id,name,role,city,area,category,gender,age,languages,price_per_shift,rating,reviews_count,badge,latitude,longitude,description,photo_path,user_id,is_active')
      .eq('user_id', userId)
      .limit(1);
    const caregiver = Array.isArray(data) ? data[0] || null : null;
    console.debug('[TemanLansia Auth] hasil profil caregiver', {
      found: Boolean(caregiver),
      matchedUserId: caregiver?.user_id || null,
      error: error?.message || null
    });
    if (error) throw new Error(`Profil caregiver gagal dibaca: ${error.message}`);
    return caregiver;
  }

  async function signInCaregiver(email, password) {
    const client = requireClient();
    const cleanEmail = String(email).trim();
    if (!cleanEmail || !String(password)) throw new Error('Email dan password wajib diisi.');
    const { data, error } = await client.auth.signInWithPassword({ email: cleanEmail, password });
    console.debug('[TemanLansia Auth] sign-in response', { ok: !error, error: error?.message || null, userId: data?.user?.id || null });
    if (error) throw new Error(`Login caregiver gagal: ${error.message}`);
    const user = await getAuthenticatedUser(client);
    const caregiver = await findCaregiverForUser(client, user);
    if (!caregiver) { await client.auth.signOut(); throw new Error('Akun tidak terdaftar sebagai caregiver.'); }
    return { session: data.session, user, caregiver };
  }

  async function signOut() {
    const client = requireClient();
    const { error } = await client.auth.signOut();
    if (error) throw new Error(`Logout gagal: ${error.message}`);
  }

  async function getCaregiverDashboard() {
    const { client, session } = await getSession();
    if (!session?.user?.id) throw new Error('Sesi caregiver tidak ditemukan.');
    const user = await getAuthenticatedUser(client);
    const caregiver = await findCaregiverForUser(client, user);
    if (!caregiver) throw new Error('Profil caregiver tidak ditemukan atau akses ditolak.');
    const { data: bookings, error: bookingError } = await client
      .from('bookings')
      .select('id,customer_id,elder_profile_id,caregiver_id,start_at,end_at,status,total_amount,payments(status)')
      .eq('caregiver_id', caregiver.id)
      .order('start_at', { ascending: true });
    if (bookingError) throw new Error(`Booking/payment caregiver gagal dibaca dari Supabase: ${bookingError.message}`);

    // Non-blocking enrichment: RPC hanya memperkaya nama tanpa memfilter/menghilangkan booking utama
    const baseBookings = bookings || [];
    const resolvedBookings = await Promise.all(baseBookings.map(async b => {
      try {
        const { data, error } = await client.rpc('get_assigned_customer_details', { p_booking_id: b.id });
        if (data && !error) {
          return {
            ...b,
            customer_name: data.customer_name || null,
            elder_name: data.elder_name || null
          };
        }
      } catch {
        // Fallback gracefully without throwing
      }
      return b;
    }));

    return { session, caregiver, bookings: resolvedBookings, activities: [] };
  }

  async function signUpCustomer({ email, password, fullName, phone, emergencyName, emergencyPhone }) {
    const client = requireClient();
    const cleanEmail = String(email || '').trim();
    const cleanName = String(fullName || '').trim();
    const cleanPhone = String(phone || '').trim();
    const cleanEmergencyName = String(emergencyName || '').trim();
    const cleanEmergencyPhone = String(emergencyPhone || '').trim();
    if (!cleanEmail || !String(password)) throw new Error('Email dan password wajib diisi.');
    if (!cleanName) throw new Error('Nama lengkap wajib diisi.');
    if (!cleanEmergencyName || !cleanEmergencyPhone) throw new Error('Kontak darurat wajib diisi.');
    const { data, error } = await client.auth.signUp({
      email: cleanEmail,
      password: String(password),
      options: {
        data: {
          full_name: cleanName,
          phone: cleanPhone,
          emergency_contact_name: cleanEmergencyName,
          emergency_contact_phone: cleanEmergencyPhone
        }
      }
    });
    if (error) throw new Error(`Pendaftaran gagal: ${error.message}`);
    return data;
  }

  async function getVerifiedRole() {
    const { client, session } = await getSession();
    const user = session?.user;
    if (!user?.id || isAnonymousUser(user)) throw new Error('Sesi login tidak valid.');
    const { data: roleRows, error: roleError } = await client.from('user_roles').select('role').eq('user_id', user.id);
    if (roleError) throw new Error(`Role akun gagal diverifikasi: ${roleError.message}`);
    const roles = [...new Set((roleRows || []).map(row => row.role).filter(role => ['customer', 'caregiver', 'admin'].includes(role)))];
    const role = ['admin', 'caregiver', 'customer'].find(candidate => roles.includes(candidate));
    if (!role) throw new Error('Role akun tidak ditemukan atau tidak valid.');
    if (role === 'caregiver') {
      const caregiver = await findCaregiverForUser(client, user);
      if (!caregiver?.is_active && caregiver?.is_active !== undefined) throw new Error('Akun caregiver tidak aktif.');
      if (!caregiver) throw new Error('Relasi akun caregiver tidak ditemukan.');
    }
    if (role === 'customer') {
      const { data: customer, error: customerError } = await client.from('customers').select('id').eq('id', user.id).limit(1);
      if (customerError) throw new Error(`Relasi akun customer gagal diverifikasi: ${customerError.message}`);
      if (!customer?.length) throw new Error('Relasi akun customer tidak ditemukan.');
    }
    return { user, roles, role };
  }

  async function signInCustomer(email, password) {
    const client = requireClient();
    if (!String(email).trim() || !String(password)) throw new Error('Email dan password wajib diisi.');
    const { data, error } = await client.auth.signInWithPassword({ email: String(email).trim(), password });
    if (error) throw new Error(`Login gagal: ${error.message}`);
    return data;
  }

  async function signInUniversal(email, password) {
    const client = requireClient();
    const cleanEmail = String(email || '').trim();
    if (!cleanEmail || !String(password || '')) throw new Error('Email dan password wajib diisi.');
    const { data, error } = await client.auth.signInWithPassword({ email: cleanEmail, password: String(password) });
    if (error) throw new Error(`Login gagal: ${error.message}`);
    try { return { ...data, ...(await getVerifiedRole()) }; }
    catch (roleError) { await client.auth.signOut(); throw roleError; }
  }

  function safeInternalReturnUrl(value) {
    const fallback = 'index.html';
    const raw = String(value || '').trim();
    if (!raw || raw.startsWith('//') || /^[a-z][a-z\d+.-]*:/i.test(raw) || !raw.startsWith('/')) return fallback;
    return raw;
  }

  async function getCustomerBookings() {
    const { client, session } = await getSession();
    const customerId = session?.user?.id;
    if (!customerId) throw new Error('Login customer diperlukan.');
    await assertCustomerRole(client, session.user);
    const { data: bookings, error: bookingError } = await client
      .from('bookings')
      .select('id,customer_id,caregiver_id,elder_profile_id,elder_address_id,start_at,end_at,status,total_amount,created_at,updated_at')
      .eq('customer_id', customerId)
      .order('created_at', { ascending: false });
    if (bookingError) {
      console.warn('[TemanLansia History] booking query failed', { code: bookingError.code || null, status: bookingError.status || null, message: bookingError.message });
      throw new Error(`History booking gagal dibaca: ${bookingError.message}`);
    }
    const rows = Array.isArray(bookings) ? bookings : [];
    if (rows.length === 0) {
      console.debug('[TemanLansia History] no bookings; payment query skipped');
      return [];
    }

    const bookingIds = rows.map(row => row.id).filter(Boolean);
    const caregiverIds = [...new Set(rows.map(row => row.caregiver_id).filter(Boolean))];
    const { data: caregivers, error: caregiverError } = caregiverIds.length
      ? await client.rpc('get_public_caregiver_profiles', { p_caregiver_ids: caregiverIds })
      : { data: [], error: null };
    if (caregiverError) {
      console.warn('[TemanLansia History] caregiver RPC failed', { code: caregiverError.code || null, status: caregiverError.status || null, message: caregiverError.message });
      throw new Error(`Profil caregiver history gagal dibaca melalui RPC: ${caregiverError.message}`);
    }
    const caregiverRows = Array.isArray(caregivers) ? caregivers : [];
    const caregiverById = new Map(caregiverRows.map(caregiver => [String(caregiver.id), caregiver]));
    const missingCaregiverIds = caregiverIds.filter(id => !caregiverById.has(String(id)));
    if (missingCaregiverIds.length) console.warn('[TemanLansia History] caregiver profiles missing', { count: missingCaregiverIds.length });
    console.debug('[TemanLansia History] booking/caregiver query succeeded', { count: rows.length, idCount: bookingIds.length, caregiverCount: caregiverById.size });
    const { data: payments, error: paymentError } = await client
      .from('payments')
      .select('id,booking_id,status,method,amount,paid_at,created_at')
      .in('booking_id', bookingIds);
    if (paymentError) {
      console.warn('[TemanLansia History] payment query failed', { code: paymentError.code || null, status: paymentError.status || null, message: paymentError.message });
      throw new Error(`Status pembayaran history gagal dibaca: ${paymentError.message}`);
    }

    const paymentRows = Array.isArray(payments) ? payments : [];
    const paymentByBookingId = new Map(paymentRows.map(payment => [payment.booking_id, payment]));
    const joined = rows.map(row => ({ ...row, caregivers: caregiverById.get(row.caregiver_id) || null, payments: paymentByBookingId.get(row.id) || null }));
    console.debug('[TemanLansia History] payment join completed', {
      paymentCount: paymentRows.length,
      joinedCount: joined.filter(row => row.payments).length,
      missingPaymentCount: joined.filter(row => !row.payments).length,
      statuses: paymentRows.reduce((counts, payment) => { counts[payment.status || 'NULL'] = (counts[payment.status || 'NULL'] || 0) + 1; return counts; }, {})
    });
    return joined;
  }

  async function updateMyCaregiverProfile(patch) {
    const client = requireClient();
    if (!patch || typeof patch !== 'object' || Array.isArray(patch) || Object.keys(patch).length === 0) {
      throw new Error('Data perubahan profil tidak boleh kosong.');
    }
    const { session } = await getSession();
    if (!session?.user?.id) throw new Error('Login caregiver diperlukan.');

    const { data, error } = await client.rpc('update_my_caregiver_profile', { p_patch: patch });
    if (error) {
      if (error.code === '42501') {
        throw new Error('Akses ditolak: Anda tidak memiliki hak akses untuk mengubah profil ini.');
      }
      if (error.code === 'P0003') {
        throw new Error(`Data profil tidak valid: ${error.message}`);
      }
      throw new Error(`Update profil gagal: ${error.message}`);
    }
    return data;
  }

  async function getAssignedCustomerDetails(bookingId) {
    const client = requireClient();
    const id = String(bookingId || '').trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
      throw new Error('ID booking tidak valid.');
    }
    const { session } = await getSession();
    if (!session?.user?.id) throw new Error('Login caregiver diperlukan.');

    const { data, error } = await client.rpc('get_assigned_customer_details', { p_booking_id: id });
    if (error) {
      if (error.code === 'P0002') {
        throw new Error('Booking tidak ditemukan atau tidak ditugaskan ke caregiver ini.');
      }
      if (error.code === '42501') {
        throw new Error('Akses ditolak: Anda tidak memiliki hak akses untuk booking ini.');
      }
      throw new Error(`Detail customer gagal dibaca: ${error.message}`);
    }
    return data;
  }

  async function uploadCaregiverPhoto(caregiverUuid, file) {
    const client = requireClient();
    const { session } = await getSession();
    if (!session?.user?.id) throw new Error('Login caregiver diperlukan.');
    const uuidStr = String(caregiverUuid || '').trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(uuidStr)) {
      throw new Error('UUID caregiver tidak valid.');
    }
    if (!file) throw new Error('File foto belum dipilih.');

    const fileExt = (file.name ? file.name.split('.').pop() : 'jpg').toLowerCase();
    const safeExt = ['jpg', 'jpeg', 'png', 'webp'].includes(fileExt) ? fileExt : 'jpg';
    const fileName = `${Date.now()}_${Math.random().toString(36).substring(2, 9)}.${safeExt}`;
    const objectPath = `${uuidStr}/${fileName}`;
    const canonicalPath = `caregiver-media/${objectPath}`;

    const { error: uploadError } = await client.storage
      .from('caregiver-media')
      .upload(objectPath, file, {
        cacheControl: '3600',
        upsert: false
      });

    if (uploadError) throw new Error(`Upload foto gagal: ${uploadError.message}`);
    return { canonicalPath, objectPath, fileName };
  }

  async function getCaregiverPhotoUrl(photoPath, expiresIn = 3600) {
    if (!photoPath) return null;
    const pathStr = String(photoPath).trim();
    if (!pathStr) return null;
    if (pathStr.startsWith('images/') || pathStr.startsWith('/') || pathStr.startsWith('http') || pathStr.startsWith('data:') || pathStr.startsWith('blob:')) {
      return pathStr;
    }
    const client = requireClient();
    const cleanPath = pathStr.startsWith('caregiver-media/')
      ? pathStr.slice('caregiver-media/'.length)
      : pathStr;

    const { data, error } = await client.storage
      .from('caregiver-media')
      .createSignedUrl(cleanPath, expiresIn);

    if (error) {
      console.warn('[TemanLansia] Gagal membuat signed URL foto:', error.message);
      return null;
    }
    return data?.signedUrl || null;
  }

  /* legacy caregiver read remains remote-first and exact-100 validated */
  async function getCaregiversLegacy() {
    if (!configured) throw new Error('Supabase belum dikonfigurasi lokal.');
    if (!window.supabase || typeof window.supabase.createClient !== 'function') {
      throw new Error('Supabase Client gagal dimuat.');
    }

    const client = requireClient();
    const { data, error } = await client
      .from('caregivers')
      .select('id,legacy_caregiver_id,name,role,city,area,category,gender,age,languages,price_per_shift,rating,reviews_count,badge,latitude,longitude,description,photo_path')
      .eq('is_active', true)
      .order('legacy_caregiver_id', { ascending: true });

    if (error) throw new Error(`Supabase caregivers: ${error.message}`);
    if (!Array.isArray(data) || data.length !== 100) {
      throw new Error(`Expected 100 caregivers, got ${Array.isArray(data) ? data.length : 0}`);
    }

    return data.map(row => ({
      id: row.legacy_caregiver_id,
      uuid: row.id,
      name: row.name,
      role: row.role,
      city: row.city,
      area: row.area,
      category: row.category,
      gender: row.gender,
      age: row.age,
      languages: Array.isArray(row.languages) ? row.languages : [],
      price: `Rp ${Number(row.price_per_shift).toLocaleString('id-ID')}/shift`,
      price_val: Number(row.price_per_shift),
      rating: Number(row.rating),
      reviews: row.reviews_count,
      badge: row.badge || '',
      coords: { lat: Number(row.latitude), lng: Number(row.longitude) },
      image: row.photo_path || '',
      desc: row.description || '',
      source: 'supabase'
    }));
  }

  window.TemanLansiaSupabase = Object.freeze({
    getCaregivers,
    createAnonymousBooking,
    createCustomerBooking,
    confirmMyAssignedBooking,
    confirmMyDemoPayment,
    getAdminPendingBookings,
    confirmDemoPaymentAsAdmin,
    getBookingPaymentSummary,
    createBooking,
    createDemoPayment,
    submitReview,
    getSession,
    getVerifiedRole,
    signInUniversal,
    safeInternalReturnUrl,
    getCustomerContext,
    getCustomerBookings,
    signUpCustomer,
    signInCustomer,
    signInCaregiver,
    signOut,
    getCaregiverDashboard,
    updateMyCaregiverProfile,
    getAssignedCustomerDetails,
    uploadCaregiverPhoto,
    getCaregiverPhotoUrl,
    transitionBooking
  });
})();
