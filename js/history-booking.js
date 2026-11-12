(() => {
  'use strict';

  const state = { bookings: [], status: 'all' };
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
  const money = value => Number(value || 0).toLocaleString('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 });
  const dateTime = value => value ? new Intl.DateTimeFormat('id-ID', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value)) : '—';
  const dateOnly = value => value ? new Intl.DateTimeFormat('id-ID', { dateStyle: 'medium' }).format(new Date(value)) : '—';
  const statusLabel = value => ({ pending: 'Pending', confirmed: 'Confirmed', in_progress: 'In Progress', completed: 'Completed', cancelled: 'Cancelled' }[value] || value || '—');
  const paymentLabel = value => ({ unpaid: 'Belum Dibayar', pending: 'Menunggu Pembayaran', paid_demo: 'Sudah Dibayar (Simulasi)', paid: 'Sudah Dibayar', failed_demo: 'Pembayaran Gagal', refunded_demo: 'Dana Dikembalikan' }[value] || 'Status Pembayaran Belum Tersedia');
  const caregiverPlaceholder = 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2248%22 height=%2248%22 viewBox=%220 0 48 48%22%3E%3Crect width=%2248%22 height=%2248%22 rx=%2224%22 fill=%22%23E5E1DC%22/%3E%3Ccircle cx=%2224%22 cy=%2218%22 r=%227%22 fill=%22%236B6B6B%22/%3E%3Cpath d=%22M11 39c1-8 6-12 13-12s12 4 13 12%22 fill=%22%236B6B6B%22/%3E%3C/svg%3E';
  const caregiverOf = item => Array.isArray(item.caregivers) ? item.caregivers[0] || null : item.caregivers || null;
  const caregiverName = caregiver => caregiver?.name || 'Profil pendamping tidak tersedia';
  const caregiverPhoto = caregiver => caregiver?.photoUrl || caregiver?.photo_path || caregiverPlaceholder;
  const caregiverRole = caregiver => caregiver?.role || (caregiver ? 'Pendamping lansia' : '');

  async function resolveCaregiverPhotos(rows) {
    return Promise.all(rows.map(async item => {
      const caregiver = caregiverOf(item);
      if (!caregiver) {
        console.warn('[TemanLansia History] caregiver profile missing', { bookingId: item.id, caregiverId: item.caregiver_id });
        return item;
      }
      const catalog = Array.isArray(window.caregiversData)
        ? window.caregiversData.find(profile => String(profile.id) === String(caregiver.legacy_caregiver_id))
        : null;
      let photoUrl = caregiver.photo_path || catalog?.image || null;
      if (caregiver.photo_path) {
        try { photoUrl = await window.TemanLansiaSupabase.getCaregiverPhotoUrl(caregiver.photo_path); } catch { /* retain catalog photo */ }
      }
      return { ...item, caregivers: { ...caregiver, name: catalog?.name || caregiver.name, role: catalog?.role || caregiver.role, photoUrl, catalogId: catalog?.id || null } };
    }));
  }

  const caregiverForRender = item => caregiverOf(item);

  function showError(message) {
    $('historyLoading').hidden = true;
    $('historyEmpty').hidden = true;
    $('historyError').hidden = false;
    $('historyError').textContent = message;
  }

  function render() {
    const visible = state.status === 'all' ? state.bookings : state.bookings.filter(item => item.status === state.status);
    $('historyLoading').hidden = true;
    $('historyError').hidden = true;
    $('historyEmpty').hidden = visible.length !== 0;
    $('historyList').innerHTML = visible.map(item => {
      const caregiver = caregiverForRender(item) || {};
      const payment = Array.isArray(item.payments) ? item.payments[0] : item.payments;
      const duration = item.start_at && item.end_at ? `${Math.max(0, Math.round((new Date(item.end_at) - new Date(item.start_at)) / 3600000))} jam` : '—';
      return `<article class="history-card">
        <div class="history-card__top"><div><p class="eyebrow">BOOKING</p><h2>${esc(item.id)}</h2></div><span class="status status--${esc(item.status)}">${esc(statusLabel(item.status))}</span></div>
        <div class="history-main"><img class="caregiver-photo" src="${esc(caregiverPhoto(caregiver))}" alt="Foto ${esc(caregiverName(caregiver))}" onerror="this.onerror=null;this.src='${caregiverPlaceholder}'"><div><h3>${esc(caregiverName(caregiver))}</h3><p class="muted">${esc(caregiverRole(caregiver))}</p><p class="muted">Dipesan ${esc(dateOnly(item.created_at))}</p></div></div>
        <dl class="history-meta"><div><dt>Jadwal</dt><dd>${esc(dateTime(item.start_at))}</dd></div><div><dt>Durasi</dt><dd>${esc(duration)}</dd></div><div><dt>Total</dt><dd>${esc(money(item.total_amount))}</dd></div><div><dt>Pembayaran</dt><dd>${esc(paymentLabel(payment?.status))}</dd></div></dl>
        <button class="detail-btn" type="button" data-detail="${esc(item.id)}">Lihat Detail</button>
      </article>`;
    }).join('');
    $('historyList').querySelectorAll('[data-detail]').forEach(button => button.addEventListener('click', () => openDetail(button.dataset.detail)));
  }

  function openDetail(id) {
    const item = state.bookings.find(row => row.id === id);
    if (!item) return;
    const caregiver = caregiverForRender(item) || {};
    const payment = Array.isArray(item.payments) ? item.payments[0] : item.payments;
    $('detailBody').innerHTML = `<p class="eyebrow">DETAIL PESANAN</p><h2>${esc(item.id)}</h2><div class="history-main"><img class="caregiver-photo" src="${esc(caregiverPhoto(caregiver))}" alt="Foto ${esc(caregiverName(caregiver))}" onerror="this.onerror=null;this.src='${caregiverPlaceholder}'"><div><h3>${esc(caregiverName(caregiver))}</h3><p class="muted">${esc(caregiverRole(caregiver))}</p></div></div><div class="detail-grid"><b>Pendamping</b><span>${esc(caregiverName(caregiver))}</span><b>Status booking</b><span>${esc(statusLabel(item.status))}</span><b>Dibuat</b><span>${esc(dateTime(item.created_at))}</span><b>Shift</b><span>${esc(dateTime(item.start_at))} — ${esc(dateTime(item.end_at))}</span><b>Total</b><span>${esc(money(item.total_amount))}</span><b>Status pembayaran</b><span>${esc(paymentLabel(payment?.status))}</span></div>`;
    $('detailModal').hidden = false;
  }

  async function load() {
    try {
      const session = await window.TemanLansiaSupabase.getSession();
      if (!session.session?.user?.id || session.session?.user?.is_anonymous) {
        window.location.href = `customer-login.html?returnUrl=${encodeURIComponent('history-booking.html')}`;
        return;
      }
      const bookings = await window.TemanLansiaSupabase.getCustomerBookings();
      state.bookings = await resolveCaregiverPhotos(bookings);
      render();
    } catch (error) {
      showError(error.message || 'History booking gagal dimuat.');
    }
  }

  $('statusFilter').addEventListener('change', event => { state.status = event.target.value; render(); });
  $('closeDetail').addEventListener('click', () => { $('detailModal').hidden = true; });
  $('detailModal').addEventListener('click', event => { if (event.target === $('detailModal')) $('detailModal').hidden = true; });
  load();
})();
