/* Caregiver dashboard: authenticated Supabase RPC + Storage with local demo fallback. */
(() => {
  'use strict';
  let session = null;
  const state = { caregivers: [], bookings: [], activities: [], reports: [] };
  const $ = id => document.getElementById(id);
  const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const paymentStatusOf = booking => {
    const payment = Array.isArray(booking.payments) ? booking.payments[0] : booking.payments;
    return payment && Object.prototype.hasOwnProperty.call(payment, 'status') ? payment.status ?? null : null;
  };
  const sameId = (left, right) => String(left ?? '').trim().toLowerCase() === String(right ?? '').trim().toLowerCase();
  const currentCaregiverId = () => session?.caregiverUuid || session?.caregiverId || null;
  const canAccess = (role, caregiverId, customerCaregiverId) => role === 'caregiver' && sameId(caregiverId, customerCaregiverId);
  window.caregiverAccess = { canAccess };

  const showError = message => {
    const el = $('accessError');
    if (!el) return;
    el.textContent = message;
    el.classList.add('show');
  };

  const formatDateTimeWib = isoString => {
    if (!isoString) return 'Belum tersedia';
    try {
      const d = new Date(isoString);
      if (isNaN(d.getTime())) return isoString;
      return d.toLocaleString('id-ID', {
        timeZone: 'Asia/Jakarta',
        day: 'numeric',
        month: 'short',
        year: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      }) + ' WIB';
    } catch {
      return isoString;
    }
  };

  const assignedBookings = () => state.bookings.filter(b => canAccess(session.role, currentCaregiverId(), b.caregiverId));
  const customers = () => assignedBookings();
  const reportsFor = (customer = 'all', date = '') => state.reports.filter(r => canAccess(session.role, currentCaregiverId(), r.caregiverId) && (customer === 'all' || r.customer === customer) && (!date || r.date === date));
  const persistReports = () => localStorage.setItem('temanlansia-caregiver-reports', JSON.stringify(state.reports));
  const customerOptions = select => {
    if (!select) return;
    const uniqueCustomers = [...new Map(assignedBookings().map(b => [b.customerName || b.patientName || b.id, b])).values()];
    select.innerHTML = '<option value="all">Semua customer</option>' + uniqueCustomers.map(c => {
      const name = c.customerName || c.patientName || c.id;
      return `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`;
    }).join('');
  };

  function renderSidebarProfile() {
    const c = state.caregivers.find(x => Number(x.id) === session.caregiverId) || state.caregivers[0];
    const rawName = (c && c.name) ? String(c.name).trim() : 'Caregiver';
    const words = rawName.split(/\s+/).filter(Boolean);
    let initials = 'CG';
    if (words.length === 1) {
      initials = words[0].slice(0, 2).toUpperCase();
    } else if (words.length > 1) {
      initials = (words[0].charAt(0) + words[1].charAt(0)).toUpperCase();
    }

    const avatarEl = $('sidebarAvatar');
    const nameEl = $('sidebarCaregiverName');
    if (avatarEl) avatarEl.textContent = initials;
    if (nameEl) nameEl.textContent = rawName;
  }

  function renderDashboard() {
    const mine = assignedBookings();
    const activeCustomerCount = new Set(mine.map(b => b.customerId || b.customerName || b.id)).size;
    $('today').textContent = new Date().toLocaleDateString('id-ID', { dateStyle: 'full' });
    $('metrics').innerHTML = `<div class="card metric"><span>Customer aktif</span><strong>${activeCustomerCount}</strong></div><div class="card metric"><span>Booking ditugaskan</span><strong>${mine.length}</strong></div><div class="card metric"><span>Laporan tersimpan</span><strong>${reportsFor().length}</strong></div>`;
    $('agenda').innerHTML = mine.length
      ? mine.map(b => {
          const elderDisplay = b.elderName || (session.demo ? b.patientName : null);
          const elderHtml = elderDisplay
            ? `<strong>${escapeHtml(elderDisplay)}</strong>`
            : '<strong class="muted" style="font-style:italic">Nama lansia belum tersedia</strong>';
          const schedule = b.shift && b.shift.includes('WIB') && (b.shift.includes('–') || b.shift.includes('-')) && b.shift.includes('202')
            ? b.shift
            : `${b.date} · ${b.shift}`;
          return `<div class="report">${elderHtml}<br><span class="muted">${escapeHtml(schedule)} · ${escapeHtml(b.status)}</span></div>`;
        }).join('')
      : '<div class="empty">Belum ada agenda.</div>';
  }

  const profileFields = [
    ['name', 'Nama lengkap', 'text'],
    ['role', 'Gelar / profesi', 'text'],
    ['category', 'Kategori caregiver', 'text'],
    ['gender', 'Jenis kelamin', 'text'],
    ['age', 'Usia', 'number'],
    ['price_per_shift', 'Tarif per Shift (Rp)', 'number'],
    ['city', 'Kota domisili', 'text'],
    ['area', 'Area pelayanan', 'text'],
    ['languages', 'Bahasa (pisahkan dengan koma)', 'text'],
    ['description', 'Biografi', 'textarea']
  ];

  const valueOrUnknown = value => value === null || value === undefined || value === '' ? 'Belum tersedia' : value;

  async function renderProfile() {
    const c = state.caregivers.find(x => Number(x.id) === session.caregiverId);
    if (!c) { $('myProfile').innerHTML = '<div class="empty">Profil tidak ditemukan.</div>'; return; }
    const languages = Array.isArray(c.languages) ? c.languages.join(', ') : valueOrUnknown(c.languages);
    const initialLetter = escapeHtml(String(c.name || '?').trim().charAt(0));

    let photoUrl = null;
    if (c.photo_path) {
      try {
        if (window.TemanLansiaSupabase?.getCaregiverPhotoUrl) {
          photoUrl = await window.TemanLansiaSupabase.getCaregiverPhotoUrl(c.photo_path);
        } else {
          photoUrl = c.photo_path;
        }
      } catch {
        photoUrl = null;
      }
    } else if (c.photoUrl) {
      photoUrl = c.photoUrl;
    }

    const avatarHtml = photoUrl
      ? `<img src="${escapeHtml(photoUrl)}" alt="${escapeHtml(c.name || 'Caregiver')}" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`
      : initialLetter;

    const priceVal = (c.price_per_shift != null && c.price_per_shift !== '') 
      ? `Rp ${Number(c.price_per_shift).toLocaleString('id-ID')}/shift` 
      : 'Belum diatur';

    $('myProfile').innerHTML = `
      <div class="profile-avatar" id="profileAvatarDisplay" aria-hidden="true">${avatarHtml}</div>
      <p class="eyebrow">CAREGIVER TERDAFTAR</p>
      <h2>${escapeHtml(valueOrUnknown(c.name))}</h2>
      <p class="profile-role">${escapeHtml(valueOrUnknown(c.role))}</p>
      <div class="profile-tags">
        <span class="badge">${escapeHtml(valueOrUnknown(c.category))}</span>
        <span class="badge ok">${escapeHtml(valueOrUnknown(c.city))}</span>
        ${c.area ? `<span class="badge">${escapeHtml(c.area)}</span>` : ''}
        <span class="badge" style="background:#fef3c7;color:#92400e;font-weight:700">💰 ${escapeHtml(priceVal)}</span>
      </div>
      <p class="profile-bio">${escapeHtml(valueOrUnknown(c.desc || c.description))}</p>
      <div class="profile-stats">
        <div><strong>${escapeHtml(valueOrUnknown(c.rating))}</strong><span>Rating</span></div>
        <div><strong>${escapeHtml(valueOrUnknown(c.reviews || c.reviews_count))}</strong><span>Ulasan</span></div>
        <div><strong>${escapeHtml(valueOrUnknown(languages))}</strong><span>Bahasa</span></div>
      </div>
    `;

    $('profileFields').innerHTML = profileFields.map(([key, label, type]) => {
      let val = '';
      if (key === 'description') val = c.desc || c.description || '';
      else if (key === 'languages') val = languages === 'Belum tersedia' ? '' : languages;
      else val = c[key] ?? '';

      if (type === 'textarea') {
        return `<label class="field">${label}<textarea class="textarea" name="${key}" rows="4">${escapeHtml(val)}</textarea></label>`;
      }
      
      let numAttrs = '';
      if (key === 'age') {
        numAttrs = 'min="18" max="100" step="1"';
      } else if (key === 'price_per_shift') {
        numAttrs = 'min="1" max="1000000000" step="1" placeholder="Contoh: 280000"';
      }

      return `<label class="field">${label}<input class="input" name="${key}" type="${type}" value="${escapeHtml(val)}" ${numAttrs}></label>`;
    }).join('');
  }

  function renderCustomers() {
    const list = customers();
    $('customerRows').innerHTML = list.map(b => {
      const elderDisplay = b.elderName || b.patientName;
      const elderHtml = elderDisplay
        ? `<strong style="font-weight:700;color:var(--ink)">${escapeHtml(elderDisplay)}</strong>`
        : '<span class="muted" style="font-style:italic">Nama lansia belum tersedia</span>';
      return `<tr>
        <td>${elderHtml}</td>
        <td><span class="muted">${escapeHtml(valueOrUnknown(b.id))}</span></td>
        <td>${escapeHtml(valueOrUnknown(b.date))}<br>${escapeHtml(valueOrUnknown(b.shift))}</td>
        <td><span class="badge ${b.status === 'confirmed' || b.status === 'completed' ? 'ok' : ''}">${escapeHtml(valueOrUnknown(b.status))}</span></td>
        <td><button class="btn" data-booking-id="${escapeHtml(b.id)}" type="button">Detail</button></td>
      </tr>`;
    }).join('') || '<tr><td colspan="5"><div class="empty">Belum ada booking terotorisasi.</div></td></tr>';

    document.querySelectorAll('[data-booking-id]').forEach(btn =>
      btn.addEventListener('click', () => openCustomer(btn.dataset.bookingId))
    );
  }

  function renderBookings() {
    const visible = assignedBookings();
    console.debug('[TemanLansia Caregiver] bookings rendered', { receivedCount: state.bookings.length, renderedCount: visible.length });
    $('bookingRows').innerHTML = visible.map(b => {
      const paid = b.paymentStatus === 'paid_demo';
      let action;
      if (b.status === 'pending' && !paid) {
        action = '<button class="btn" type="button" disabled>Menunggu Pembayaran</button>';
      } else if (b.status === 'pending' && paid) {
        action = `<button class="btn primary" type="button" data-booking-action="confirm" data-booking-id="${escapeHtml(b.id)}">Konfirmasi Booking</button>`;
      } else if (b.status === 'confirmed') {
        action = `<button class="btn primary" type="button" data-booking-action="start" data-booking-id="${escapeHtml(b.id)}">Mulai Layanan</button>`;
      } else if (b.status === 'in_progress') {
        action = `<button class="btn primary" type="button" data-booking-action="complete" data-booking-id="${escapeHtml(b.id)}">Selesaikan Layanan</button>`;
      } else if (b.status === 'completed') {
        action = '<span class="badge ok">Selesai</span>';
      } else {
        action = '<span class="muted">Tidak tersedia</span>';
      }
      const elderDisplay = b.elderName || b.patientName;
      const elderHtml = elderDisplay
        ? `<strong style="font-weight:700;color:var(--ink)">${escapeHtml(elderDisplay)}</strong>`
        : '<span class="muted" style="font-style:italic">Nama lansia belum tersedia</span>';
      return `<tr>
        <td>${escapeHtml(b.id)}</td>
        <td>${elderHtml}</td>
        <td>${escapeHtml(b.date)}</td>
        <td>${escapeHtml(b.shift)}</td>
        <td><span class="badge ${b.status === 'confirmed' || b.status === 'completed' ? 'ok' : ''}">${escapeHtml(b.status)}</span></td>
        <td>${action}</td>
      </tr>`;
    }).join('') || '<tr><td colspan="6"><div class="empty">Belum ada booking.</div></td></tr>';

    document.querySelectorAll('[data-booking-action]').forEach(button => {
      button.addEventListener('click', () => handleBookingAction(button.dataset.bookingId, button.dataset.bookingAction, button));
    });
  }

  async function handleBookingAction(bookingId, action, button) {
    if (button.disabled) return;
    const booking = assignedBookings().find(item => String(item.id) === String(bookingId));
    const expected = { confirm: ['pending', 'paid_demo'], start: ['confirmed'], complete: ['in_progress'] }[action];
    if (!booking || !expected || booking.status !== expected[0] || (expected[1] && booking.paymentStatus !== expected[1])) {
      return showError('Status booking sudah berubah atau belum memenuhi syarat.');
    }
    const labels = { confirm: 'Konfirmasi Booking', start: 'Mulai Layanan', complete: 'Selesaikan Layanan' };
    const targets = { confirm: 'confirmed', start: 'in_progress', complete: 'completed' };
    if (!window.confirm(`${labels[action]} untuk booking ini?`)) return;
    button.disabled = true;
    button.textContent = 'Memproses...';
    try {
      if (session.demo) throw new Error('Perubahan status memerlukan Supabase production.');
      const result = action === 'confirm'
        ? await window.TemanLansiaSupabase.confirmMyAssignedBooking(bookingId)
        : await window.TemanLansiaSupabase.transitionBooking({ bookingId, to: targets[action] });
      if (!result || result.status !== targets[action]) throw new Error(`Server tidak mengembalikan status ${targets[action]}.`);
      const remote = await window.TemanLansiaSupabase.getCaregiverDashboard();
      state.bookings = (remote.bookings || []).map(item => ({
        id: item.id,
        caregiverId: item.caregiver_id || session.caregiverUuid,
        customerId: item.customer_id,
        elderProfileId: item.elder_profile_id,
        customerName: item.customer_name || null,
        elderName: item.elder_name || null,
        patientName: item.elder_name || null,
        date: String(item.start_at || '').slice(0, 10),
        shift: `${item.start_at ? formatDateTimeWib(item.start_at) : ''} – ${item.end_at ? formatDateTimeWib(item.end_at) : ''}`,
        status: item.status,
        paymentStatus: paymentStatusOf(item),
        totalPrice: item.total_amount,
        uuid: item.id
      }));
      renderAll();
    } catch (error) {
      button.disabled = false;
      button.textContent = labels[action];
      showError(error.message);
    }
  }

  function renderCalendar() {
    const date = $('calendarDate').value;
    const items = assignedBookings().filter(b => !date || b.date === date);
    $('calendarList').innerHTML = items.map(b => {
      const elderDisplay = b.elderName || (session.demo ? b.patientName : null);
      const elderText = elderDisplay
        ? escapeHtml(elderDisplay)
        : '<span class="muted" style="font-style:italic">Nama lansia belum tersedia</span>';
      let formattedDate = b.date;
      try {
        if (b.date) {
          const parsed = new Date(b.date + (b.date.includes('T') ? '' : 'T00:00:00'));
          if (!isNaN(parsed.getTime())) {
            formattedDate = parsed.toLocaleDateString('id-ID', { day: 'numeric', month: 'long', year: 'numeric' });
          }
        }
      } catch {}
      return `<div class="card" style="margin-bottom:10px">
        <strong>${escapeHtml(formattedDate)} — ${elderText}</strong>
        <p class="muted">${escapeHtml(b.shift)} · ${escapeHtml(b.status)}</p>
      </div>`;
    }).join('') || '<div class="empty">Tidak ada jadwal pada tanggal ini.</div>';
  }

  function renderReports() {
    const list = reportsFor($('reportCustomer').value, $('reportDate').value);
    $('reportsList').innerHTML = list.length
      ? list.sort((a,b) => b.recordedAt.localeCompare(a.recordedAt)).map(r => `<article class="report">
          <strong>${escapeHtml(r.customer)}</strong> <span class="badge">${escapeHtml(r.status)}</span><br>
          <span class="muted">${escapeHtml(r.date)} · ${escapeHtml(r.recordedAt)}</span>
          <p>${escapeHtml(r.notes)}</p>
        </article>`).join('')
      : '<div class="empty">Tidak ada laporan sesuai filter.</div>';
  }

  function renderHistory() {
    const list = reportsFor($('historyCustomer').value, $('historyDate').value);
    $('historyList').innerHTML = list.length
      ? list.map(r => `<article class="report">
          <strong>${escapeHtml(r.customer)}</strong> · ${escapeHtml(r.date)}
          <p>${escapeHtml(r.notes)}</p>
        </article>`).join('')
      : '<div class="empty">Riwayat laporan kosong.</div>';
  }

  async function openCustomer(bookingIdOrName) {
    const b = assignedBookings().find(x => String(x.id) === String(bookingIdOrName)) ||
              customers().find(x => x.patientName === bookingIdOrName);
    if (!b || !canAccess(session.role, currentCaregiverId(), b.caregiverId)) {
      return showError('Akses customer ditolak.');
    }

    $('drawerTitle').textContent = 'Detail Customer';
    $('drawerBody').innerHTML = '<div class="empty" style="padding:20px">Memuat detail customer...</div>';
    $('drawer').classList.add('open');

    if (session.demo) {
      $('drawerBody').innerHTML = `
        <div class="detail-section">
          <h3>Informasi lansia</h3>
          <p>Nama lansia: <strong>${escapeHtml(valueOrUnknown(b.patientName))}</strong></p>
          <p>Usia: <strong>72 tahun</strong></p>
          <p>Jenis kelamin: <strong>Laki-laki</strong></p>
          <p>Kondisi kesehatan: <strong>Hipertensi, Mobilitas terbatas</strong></p>
          <p>Alergi: <strong>Belum tersedia</strong></p>
          <p>Mobilitas: <strong>Butuh bantuan</strong></p>
          <p>Catatan medis: <strong>Perlu bantuan saat berjalan dan pengawasan konsumsi obat</strong></p>
        </div>
        <div class="detail-section">
          <h3>Kontak Darurat (Identitas keluarga)</h3>
          <p>Nama kontak darurat: <strong>Budi Santoso</strong></p>
          <p>Nomor kontak: <strong>+62 812-3456-7890</strong></p>
          <p>Nama customer: <strong>Budi Santoso (Keluarga)</strong></p>
        </div>
        <div class="detail-section">
          <h3>Alamat pelayanan</h3>
          <p>Alamat lengkap: <strong>Jl. Tebet Barat Dalam No. 12, Tebet</strong></p>
          <p>Kota / Provinsi: <strong>Jakarta Selatan, DKI Jakarta</strong></p>
          <p>Kode pos: <strong>12810</strong></p>
          <p>Catatan akses: <strong>Pagar hitam, bel di sebelah kanan gerbang</strong></p>
        </div>
        <div class="detail-section">
          <h3>Informasi pemesanan</h3>
          <p>ID booking: <strong>${escapeHtml(valueOrUnknown(b.id))}</strong></p>
          <p>Tanggal dan waktu mulai: <strong>${escapeHtml(valueOrUnknown(b.date))} (08:00 WIB)</strong></p>
          <p>Tanggal dan waktu selesai: <strong>${escapeHtml(valueOrUnknown(b.date))} (16:00 WIB)</strong></p>
          <p>Shift: <strong>Pagi</strong></p>
          <p>Durasi: <strong>8 jam</strong></p>
          <p>Status: <span class="badge ${b.status === 'confirmed' ? 'ok' : ''}"><strong>${escapeHtml(valueOrUnknown(b.status))}</strong></span></p>
          <p>Total biaya: <strong>${b.totalPrice == null ? 'Belum tersedia' : `Rp ${Number(b.totalPrice).toLocaleString('id-ID')}`}</strong></p>
        </div>
        <div class="feature-notice success" style="margin-top:14px">Data ditampilkan dari mock session demo lokal.</div>
      `;
      return;
    }

    try {
      const details = await window.TemanLansiaSupabase.getAssignedCustomerDetails(b.id);
      if (!details) throw new Error('Data customer tidak ditemukan.');

      let conditionsStr = 'Belum tersedia';
      if (Array.isArray(details.health_conditions)) {
        conditionsStr = details.health_conditions.join(', ');
      } else if (typeof details.health_conditions === 'string' && details.health_conditions.trim()) {
        conditionsStr = details.health_conditions;
      }

      const startFormatted = formatDateTimeWib(details.start_at);
      const endFormatted = formatDateTimeWib(details.end_at);
      const addr = details.address_line || details.address_snapshot?.address_line;
      const city = details.city || details.address_snapshot?.city;
      const prov = details.province || details.address_snapshot?.province;
      const post = details.postal_code || details.address_snapshot?.postal_code;
      const access = details.access_notes || details.address_snapshot?.access_notes;

      $('drawerBody').innerHTML = `
        <div class="detail-section">
          <h3>Informasi lansia</h3>
          <p>Nama lansia: <strong>${escapeHtml(valueOrUnknown(details.elder_name))}</strong></p>
          <p>Usia: <strong>${details.elder_age != null ? `${escapeHtml(details.elder_age)} tahun` : 'Belum tersedia'}</strong></p>
          <p>Jenis kelamin: <strong>${escapeHtml(valueOrUnknown(details.elder_gender))}</strong></p>
          <p>Kondisi kesehatan: <strong>${escapeHtml(conditionsStr)}</strong></p>
          <p>Alergi: <strong>${escapeHtml(valueOrUnknown(details.allergies))}</strong></p>
          <p>Mobilitas: <strong>${escapeHtml(valueOrUnknown(details.mobility))}</strong></p>
          <p>Catatan medis: <strong>${escapeHtml(valueOrUnknown(details.medical_notes))}</strong></p>
        </div>
        <div class="detail-section">
          <h3>Kontak Darurat (Identitas keluarga)</h3>
          <p>Nama kontak darurat: <strong>${escapeHtml(valueOrUnknown(details.customer_contact_name))}</strong></p>
          <p>Nomor kontak: <strong>${escapeHtml(valueOrUnknown(details.customer_contact_phone))}</strong></p>
          <p>Nama customer: <strong>${escapeHtml(valueOrUnknown(details.customer_name))}</strong></p>
        </div>
        <div class="detail-section">
          <h3>Alamat pelayanan</h3>
          <p>Alamat lengkap: <strong>${escapeHtml(valueOrUnknown(addr))}</strong></p>
          <p>Kota / Provinsi: <strong>${escapeHtml(valueOrUnknown([city, prov].filter(Boolean).join(', ')))}</strong></p>
          <p>Kode pos: <strong>${escapeHtml(valueOrUnknown(post))}</strong></p>
          <p>Catatan akses: <strong>${escapeHtml(valueOrUnknown(access))}</strong></p>
        </div>
        <div class="detail-section">
          <h3>Informasi pemesanan</h3>
          <p>ID booking: <strong>${escapeHtml(valueOrUnknown(details.booking_id))}</strong></p>
          <p>Tanggal dan waktu mulai: <strong>${escapeHtml(startFormatted)}</strong></p>
          <p>Tanggal dan waktu selesai: <strong>${escapeHtml(endFormatted)}</strong></p>
          <p>Shift: <strong>${escapeHtml(valueOrUnknown(details.shift_type))}</strong></p>
          <p>Durasi: <strong>${details.duration_hours != null ? `${escapeHtml(details.duration_hours)} jam` : 'Belum tersedia'}</strong></p>
          <p>Status: <span class="badge ${details.booking_status === 'confirmed' || details.booking_status === 'completed' ? 'ok' : ''}"><strong>${escapeHtml(valueOrUnknown(details.booking_status))}</strong></span></p>
          <p>Total biaya: <strong>${details.total_amount != null ? `Rp ${Number(details.total_amount).toLocaleString('id-ID')}` : 'Belum tersedia'}</strong></p>
        </div>
      `;

      if (details.customer_name && b.customerName !== details.customer_name) {
        b.customerName = details.customer_name;
      }
      if (details.elder_name && b.elderName !== details.elder_name) {
        b.elderName = details.elder_name;
      }
      b.patientName = b.elderName || b.patientName;
      renderCustomers();
      renderBookings();
      renderDashboard();
    } catch (err) {
      $('drawerBody').innerHTML = `
        <div class="error show" style="margin-top:14px">${escapeHtml(err.message)}</div>
        <div class="empty" style="margin-top:10px">Gagal memuat detail customer dari server.</div>
      `;
    }
  }

  function openReportForm() {
    if (session.role !== 'caregiver') return showError('Hanya caregiver dapat membuat laporan.');
    $('formCustomer').innerHTML = customers().map(c => `<option value="${escapeHtml(c.patientName)}">${escapeHtml(c.patientName)}</option>`).join('');
    $('reportModal').classList.add('open');
  }

  function showView(view) {
    document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === `view-${view}`));
    document.querySelectorAll('.nav [data-view]').forEach(b => b.classList.toggle('active', b.dataset.view === view));
    const btn = document.querySelector(`[data-view="${view}"]`);
    if (btn) $('topTitle').textContent = btn.textContent;
    if (view === 'reports') renderReports();
    if (view === 'history') renderHistory();
    if (view === 'calendar') renderCalendar();
  }

  function renderAll() {
    renderSidebarProfile();
    renderDashboard();
    renderProfile();
    renderCustomers();
    renderBookings();
    renderCalendar();
    customerOptions($('reportCustomer'));
    customerOptions($('historyCustomer'));
    renderReports();
    renderHistory();
  }

  async function load() {
    try {
      const localDev = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
      const demo = localDev && sessionStorage.getItem('temanlansia-caregiver-demo') === '1';
      if (demo) {
        session = { role: 'caregiver', caregiverId: 1, caregiverUuid: null, userId: null, demo: true };
        const [c, b, a] = await Promise.all([fetch('data/caregivers.json'), fetch('data/bookings.json'), fetch('data/activities.json')]);
        const caregiverPayload = await c.json();
        state.caregivers = Array.isArray(caregiverPayload) ? caregiverPayload : caregiverPayload.caregivers;
        state.bookings = (await b.json()).bookings.map(item => ({
          ...item,
          elderName: item.elderName || item.patientName || null,
          customerName: item.customerName || null
        }));
        state.activities = (await a.json()).activities;
        if (state.caregivers.length !== 100) throw new Error('Dataset caregiver tidak lengkap');
        state.reports = JSON.parse(localStorage.getItem('temanlansia-caregiver-reports') || '[]').filter(r => canAccess(session.role, session.caregiverId, r.caregiverId));
        $('demoBanner').hidden = false;
        $('dashboardApp').hidden = false;
        renderAll();
        return;
      }

      const { session: authSession } = await window.TemanLansiaSupabase.getSession();
      if (!authSession?.user?.id) return location.replace('login.html');
      session = { role: 'caregiver', caregiverId: null, caregiverUuid: null, userId: authSession.user.id, demo: false };

      try {
        const remote = await window.TemanLansiaSupabase.getCaregiverDashboard();
        if (!remote?.caregiver?.id) throw new Error('UUID caregiver tidak tersedia dari relasi akun.');
        session.caregiverId = Number(remote.caregiver.legacy_caregiver_id);
        session.caregiverUuid = String(remote.caregiver.id);
        console.debug('[TemanLansia Caregiver] identity resolved', { userPresent: Boolean(authSession.user?.id), caregiverUuidPresent: Boolean(session.caregiverUuid), bookingCountFromAdapter: Array.isArray(remote.bookings) ? remote.bookings.length : null });
        state.caregivers = [{
          id: session.caregiverId,
          uuid: remote.caregiver.id,
          name: remote.caregiver.name,
          role: remote.caregiver.role,
          city: remote.caregiver.city,
          area: remote.caregiver.area,
          category: remote.caregiver.category,
          gender: remote.caregiver.gender,
          age: remote.caregiver.age,
          languages: Array.isArray(remote.caregiver.languages) ? remote.caregiver.languages : [],
          price_per_shift: remote.caregiver.price_per_shift,
          rating: remote.caregiver.rating,
          reviews: remote.caregiver.reviews_count,
          reviews_count: remote.caregiver.reviews_count,
          badge: remote.caregiver.badge || '',
          desc: remote.caregiver.description || '',
          description: remote.caregiver.description || '',
          photo_path: remote.caregiver.photo_path || null
        }];
        state.bookings = (remote.bookings || []).map(b => ({
          id: b.id,
          caregiverId: b.caregiver_id || session.caregiverUuid,
          customerId: b.customer_id,
          elderProfileId: b.elder_profile_id,
          customerName: b.customer_name || null,
          elderName: b.elder_name || null,
          patientName: b.elder_name || null,
          date: String(b.start_at || '').slice(0, 10),
          shift: `${b.start_at ? formatDateTimeWib(b.start_at) : ''} – ${b.end_at ? formatDateTimeWib(b.end_at) : ''}`,
          status: b.status,
          paymentStatus: paymentStatusOf(b),
          totalPrice: b.total_amount
        }));
        state.bookings.forEach(b => { b.uuid = b.id; });
        state.activities = remote.activities || [];
      } catch (remoteError) {
        // Never replace current payment state with stale local bookings.
        throw new Error(`Supabase gagal memuat booking/payment caregiver: ${remoteError.message}`);
      }

      state.reports = JSON.parse(localStorage.getItem('temanlansia-caregiver-reports') || '[]').filter(r => canAccess(session.role, currentCaregiverId(), r.caregiverId));
      console.debug('[TemanLansia Caregiver] data loaded', { caregiverUuid: session.caregiverUuid, receivedCount: state.bookings.length, filteredCount: assignedBookings().length });
      $('dashboardApp').hidden = false;
      renderAll();
    } catch (error) {
      showError(`Dashboard gagal dimuat: ${error.message}`);
    }
  }

  function openProfileEditor() {
    $('profileForm').hidden = false;
    $('profileNotice').className = 'feature-notice';
    $('profileNotice').textContent = 'Silakan ubah data profil dan foto di bawah ini, lalu klik Simpan Perubahan.';
    $('editProfile').disabled = true;
  }

  $('editProfile').addEventListener('click', openProfileEditor);
  $('cancelProfile').addEventListener('click', () => {
    $('profileForm').hidden = true;
    $('editProfile').disabled = false;
    $('profileNotice').className = 'feature-notice';
    $('profileNotice').textContent = 'Profil terhubung dengan server Supabase.';
    renderProfile();
  });

  $('profilePhoto').addEventListener('change', event => {
    const file = event.target.files[0];
    if (file && file.type.startsWith('image/')) {
      const previewUrl = URL.createObjectURL(file);
      const avatarDisplay = $('profileAvatarDisplay');
      if (avatarDisplay) {
        avatarDisplay.innerHTML = `<img src="${escapeHtml(previewUrl)}" alt="Preview" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`;
      }
      $('profileNotice').className = 'feature-notice';
      $('profileNotice').textContent = `Foto dipilih: ${file.name} (${Math.round(file.size / 1024)} KB). Simpan untuk mengunggah.`;
    }
  });

  $('profileForm').addEventListener('submit', async event => {
    event.preventDefault();
    const submitBtn = event.target.querySelector('button[type="submit"]');
    if (submitBtn) submitBtn.disabled = true;

    $('profileNotice').className = 'feature-notice';
    $('profileNotice').textContent = 'Menyimpan perubahan profil...';

    try {
      const c = state.caregivers.find(x => Number(x.id) === session.caregiverId);
      if (!c) throw new Error('Data profil caregiver tidak ditemukan.');

      const formData = new FormData($('profileForm'));
      const patch = {};

      const name = formData.get('name')?.trim();
      if (name !== undefined) patch.name = name || null;

      const role = formData.get('role')?.trim();
      if (role !== undefined) patch.role = role || null;

      const category = formData.get('category')?.trim();
      if (category !== undefined) patch.category = category || null;

      const gender = formData.get('gender')?.trim();
      if (gender !== undefined) patch.gender = gender || null;

      const ageRaw = formData.get('age')?.trim();
      if (ageRaw !== undefined && ageRaw !== '') {
        const parsedAge = parseInt(ageRaw, 10);
        if (isNaN(parsedAge) || parsedAge < 18 || parsedAge > 100) {
          throw new Error('Usia harus berupa angka antara 18 dan 100 tahun.');
        }
        patch.age = parsedAge;
      } else if (ageRaw === '') {
        patch.age = null;
      }

      const priceRaw = formData.get('price_per_shift')?.trim();
      if (priceRaw !== undefined && priceRaw !== '') {
        if (/^-/.test(priceRaw)) {
          throw new Error('Tarif per shift harus berupa nominal positif.');
        }
        const cleanedPrice = priceRaw.replace(/[^0-9]/g, '');
        if (!cleanedPrice || !/^[1-9][0-9]*$/.test(cleanedPrice)) {
          throw new Error('Tarif per shift harus berupa nominal Rupiah bulat positif (minimal Rp1).');
        }
        const parsedPrice = parseInt(cleanedPrice, 10);
        if (isNaN(parsedPrice) || parsedPrice <= 0) {
          throw new Error('Tarif per shift harus berupa nominal positif.');
        }
        if (parsedPrice > 1000000000) {
          throw new Error('Tarif per shift melebihi batas maksimal (Rp1.000.000.000).');
        }
        patch.price_per_shift = parsedPrice;
      } else if (priceRaw === '') {
        patch.price_per_shift = null;
      }

      const city = formData.get('city')?.trim();
      if (city !== undefined) patch.city = city || null;

      const area = formData.get('area')?.trim();
      if (area !== undefined) patch.area = area || null;

      const langRaw = formData.get('languages');
      if (langRaw !== undefined) {
        patch.languages = typeof langRaw === 'string'
          ? langRaw.split(',').map(s => s.trim()).filter(Boolean)
          : [];
      }

      const desc = formData.get('description')?.trim();
      if (desc !== undefined) patch.description = desc || null;

      const photoFile = $('profilePhoto').files[0];
      if (photoFile) {
        if (!photoFile.type.startsWith('image/')) {
          throw new Error('File foto harus berformat gambar (JPG, PNG, atau WebP).');
        }
        if (photoFile.size > 5 * 1024 * 1024) {
          throw new Error('Ukuran file foto maksimal 5 MB.');
        }

        if (session.demo) {
          const previewUrl = URL.createObjectURL(photoFile);
          patch.photo_path = previewUrl;
          c.photoUrl = previewUrl;
        } else {
          $('profileNotice').textContent = 'Mengunggah foto profil ke Storage...';
          const caregiverUuid = c.uuid || session.caregiverUuid;
          if (!caregiverUuid) throw new Error('ID UUID caregiver tidak ditemukan untuk upload Storage.');
          const uploadRes = await window.TemanLansiaSupabase.uploadCaregiverPhoto(caregiverUuid, photoFile);
          patch.photo_path = uploadRes.canonicalPath;
        }
      }

      if (session.demo) {
        Object.assign(c, {
          name: patch.name !== undefined ? patch.name : c.name,
          role: patch.role !== undefined ? patch.role : c.role,
          category: patch.category !== undefined ? patch.category : c.category,
          gender: patch.gender !== undefined ? patch.gender : c.gender,
          age: patch.age !== undefined ? patch.age : c.age,
          city: patch.city !== undefined ? patch.city : c.city,
          area: patch.area !== undefined ? patch.area : c.area,
          languages: patch.languages !== undefined ? patch.languages : c.languages,
          description: patch.description !== undefined ? patch.description : c.description,
          desc: patch.description !== undefined ? patch.description : c.desc,
          price_per_shift: patch.price_per_shift !== undefined ? patch.price_per_shift : c.price_per_shift
        });
        $('profileNotice').className = 'feature-notice success';
        $('profileNotice').textContent = 'Profil berhasil diperbarui (mode demo lokal).';
      } else {
        $('profileNotice').textContent = 'Menyimpan ke server...';
        const updated = await window.TemanLansiaSupabase.updateMyCaregiverProfile(patch);
        if (updated) {
          Object.assign(c, {
            name: updated.name,
            role: updated.role,
            category: updated.category,
            gender: updated.gender,
            age: updated.age,
            city: updated.city,
            area: updated.area,
            languages: updated.languages || [],
            description: updated.description,
            desc: updated.description,
            photo_path: updated.photo_path,
            rating: updated.rating,
            reviews_count: updated.reviews_count,
            price_per_shift: updated.price_per_shift
          });
          sessionStorage.setItem('temanlansia-caregiver-profile', JSON.stringify(c));
        }
        $('profileNotice').className = 'feature-notice success';
        $('profileNotice').textContent = 'Profil berhasil diperbarui dan tersimpan di server.';
      }

      $('profileForm').hidden = true;
      $('editProfile').disabled = false;
      renderSidebarProfile();
      await renderProfile();
    } catch (err) {
      $('profileNotice').className = 'feature-notice error';
      $('profileNotice').textContent = `Gagal menyimpan profil: ${err.message}`;
    } finally {
      if (submitBtn) submitBtn.disabled = false;
    }
  });

  function closeCaregiverSidebar() {
    const sb = $('sidebar');
    const backdrop = $('sidebarBackdrop');
    if (sb) sb.classList.remove('open');
    if (backdrop) backdrop.classList.remove('active');
    if (typeof document !== 'undefined' && document.body && document.body.classList) {
      document.body.classList.remove('sidebar-locked');
    }
  }

  function toggleCaregiverSidebar(e) {
    if (e && typeof e.stopPropagation === 'function') e.stopPropagation();
    const sb = $('sidebar');
    const backdrop = $('sidebarBackdrop');
    if (sb) {
      const willOpen = !sb.classList.contains('open');
      sb.classList.toggle('open', willOpen);
      if (backdrop) backdrop.classList.toggle('active', willOpen);
      if (typeof document !== 'undefined' && document.body && document.body.classList) {
        if (willOpen) {
          document.body.classList.add('sidebar-locked');
        } else {
          document.body.classList.remove('sidebar-locked');
        }
      }
    }
  }

  if ($('menu')) $('menu').addEventListener('click', toggleCaregiverSidebar);
  if ($('sidebarCloseBtn')) $('sidebarCloseBtn').addEventListener('click', closeCaregiverSidebar);
  if ($('sidebarBackdrop')) {
    $('sidebarBackdrop').addEventListener('click', closeCaregiverSidebar);
    if (typeof $('sidebarBackdrop').addEventListener === 'function') {
      $('sidebarBackdrop').addEventListener('touchstart', closeCaregiverSidebar, { passive: true });
    }
  }

  // Tapping anywhere outside the open sidebar (such as the white content area) closes it
  if (typeof document !== 'undefined' && typeof document.addEventListener === 'function') {
    document.addEventListener('click', (e) => {
      const sb = $('sidebar');
      const menu = $('menu');
      if (sb && sb.classList.contains('open')) {
        if (sb.contains && !sb.contains(e.target) && (!menu || (menu.contains && !menu.contains(e.target)))) {
          closeCaregiverSidebar();
        }
      }
    });
  }

  document.querySelectorAll('.nav [data-view]').forEach(b => b.addEventListener('click', () => {
    showView(b.dataset.view);
    closeCaregiverSidebar();
  }));
  $('closeDrawer').addEventListener('click', () => $('drawer').classList.remove('open'));
  $('closeReport').addEventListener('click', () => $('reportModal').classList.remove('open'));

  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        closeCaregiverSidebar();
        if ($('drawer')) $('drawer').classList.remove('open');
        if ($('reportModal')) $('reportModal').classList.remove('open');
        closeLogoutModal();
      }
    });
  }
  $('newReport').addEventListener('click', openReportForm);
  $('calendarDate').addEventListener('change', renderCalendar);
  $('reportDate').addEventListener('change', renderReports);
  $('reportCustomer').addEventListener('change', renderReports);
  $('historyDate').addEventListener('change', renderHistory);
  $('historyCustomer').addEventListener('change', renderHistory);
  $('clearReports').addEventListener('click', () => {
    state.reports = [];
    persistReports();
    renderDashboard();
    renderReports();
    renderHistory();
  });

  function openLogoutModal() {
    const modal = $('logoutModal');
    if (!modal) return;
    modal.classList.add('open');
    const confirmBtn = $('confirmLogout');
    if (confirmBtn && typeof confirmBtn.focus === 'function') confirmBtn.focus();
  }

  function closeLogoutModal() {
    const modal = $('logoutModal');
    if (!modal) return;
    modal.classList.remove('open');
  }

  $('logout').addEventListener('click', () => {
    openLogoutModal();
  });

  const closeLogoutBtn = $('closeLogoutModal');
  if (closeLogoutBtn) closeLogoutBtn.addEventListener('click', closeLogoutModal);

  const cancelLogoutBtn = $('cancelLogout');
  if (cancelLogoutBtn) cancelLogoutBtn.addEventListener('click', closeLogoutModal);

  const logoutModalEl = $('logoutModal');
  if (logoutModalEl) {
    logoutModalEl.addEventListener('click', event => {
      if (event.target === logoutModalEl) closeLogoutModal();
    });
  }

  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('keydown', event => {
      if (event.key === 'Escape' && logoutModalEl && logoutModalEl.classList.contains('open')) {
        closeLogoutModal();
      }
    });
  }

  let isLoggingOut = false;
  const confirmLogoutBtn = $('confirmLogout');
  if (confirmLogoutBtn) {
    confirmLogoutBtn.addEventListener('click', async () => {
      if (isLoggingOut) return;
      isLoggingOut = true;
      confirmLogoutBtn.disabled = true;
      confirmLogoutBtn.textContent = 'Memproses...';
      const cancelBtn = $('cancelLogout');
      if (cancelBtn) cancelBtn.disabled = true;

      try {
        if (window.TemanLansiaSupabase?.signOut) {
          await window.TemanLansiaSupabase.signOut();
        }
        sessionStorage.removeItem('temanlansia-caregiver-profile');
        sessionStorage.removeItem('temanlansia-caregiver-demo');
        location.replace('caregiver-login.html');
      } catch (error) {
        isLoggingOut = false;
        confirmLogoutBtn.disabled = false;
        confirmLogoutBtn.textContent = 'Ya, Keluar';
        if (cancelBtn) cancelBtn.disabled = false;
        closeLogoutModal();
        showError(error.message || 'Logout gagal.');
      }
    });
  }

  $('reportForm').addEventListener('submit', event => {
    event.preventDefault();
    const customer = $('formCustomer').value;
    const booking = customers().find(c => c.patientName === customer);
    if (!booking || !canAccess(session.role, session.caregiverId, booking.caregiverId)) {
      return showError('Akses laporan ditolak. Customer tidak ditugaskan ke caregiver ini.');
    }
    const notes = $('formNotes').value.trim();
    if (!notes) {
      $('formError').textContent = 'Catatan wajib diisi.';
      $('formError').classList.add('show');
      return;
    }
    state.reports.unshift({
      id: `report-${Date.now()}`,
      caregiverId: session.caregiverId,
      customer,
      date: new Date().toISOString().slice(0, 10),
      status: $('formStatus').value,
      notes,
      recordedAt: new Date().toLocaleString('id-ID')
    });
    persistReports();
    $('reportModal').classList.remove('open');
    $('formNotes').value = '';
    renderDashboard();
    renderReports();
    renderHistory();
  });

  load();
})();
