/**
 * TemanLansia — App Logic & Interactive Features
 */

// DATA PENDAMPING LANSIA TERVERIFIKASI
const caregiversData = [
  {
    id: 1,
    name: "Siti Rahayu, S.Kep",
    age: 32,
    gender: "Wanita",
    location: "Jakarta",
    areaDetail: "Tebet, Jakarta Selatan",
    coords: { lat: -6.2297, lng: 106.8559 },
    skillType: "Medis",
    languages: ["Jawa", "Sunda"],
    rating: 4.9,
    reviewsCount: 128,
    pricePerShift: 280000,
    photoUrl: "images/caregiver-siti.jpg",
    tagline: "Perawat Ners Lansia Geriatri & Pasca-Stroke",
    bio: "Lulusan S1 Keperawatan dengan STR aktif. Terbiasa mendampingi lansia pasca-stroke, pemantauan tensi rutin, fisioterapi gerak ringan, dan ramah berbincang bahasa Jawa krama.",
    skills: ["Injeksi Insulin Mandiri", "Perawatan Luka Bed-Sore", "Pemantauan Tensi Darah", "Bahasa Krama Inggil"],
    certifications: ["STR Perawat Aktif (Kemenkes)", "Sertifikasi BCLS", "SKCK Polda Metro"]
  },
  {
    id: 2,
    name: "Budi Santoso",
    age: 40,
    gender: "Pria",
    location: "Surabaya",
    areaDetail: "Gubeng, Surabaya Pusat",
    coords: { lat: -7.2756, lng: 112.7538 },
    skillType: "Non-Medis",
    languages: ["Jawa", "Hokkien"],
    rating: 4.8,
    reviewsCount: 94,
    pricePerShift: 220000,
    photoUrl: "images/caregiver-budi.jpg",
    tagline: "Sahabat Harian Lansia Pria & Terapi Gerak",
    bio: "Sabar dan bertenaga kuat untuk mendampingi lansia pria jalan santai di taman, latihan gerak sendi, serta mengerti percakapan santai Hokkien dan Jawa Suroboyoan.",
    skills: ["Bantuan Kursi Roda & Mobilitas", "Senam Persendian Lansia", "Bilingual Hokkien-Jawa", "Kawan Catur & Asah Otak"],
    certifications: ["Caregiver BNSP Level 3", "Pertolongan Pertama PMI", "SKCK Polrestabes"]
  },
  {
    id: 3,
    name: "Dewi Sartika, Amd.Keb",
    age: 28,
    gender: "Wanita",
    location: "Bandung",
    areaDetail: "Dago, Bandung Utara",
    coords: { lat: -6.8833, lng: 107.6167 },
    skillType: "Medis",
    languages: ["Sunda", "Batak"],
    rating: 5.0,
    reviewsCount: 76,
    pricePerShift: 260000,
    photoUrl: "images/caregiver-dewi.jpg",
    tagline: "Bidan Pendamping Demensia & Nutrisi Rendah Garam",
    bio: "Berpengalaman 5 tahun merawat oma dengan demensia ringan. Pendengar yang setia, mampu meredakan kecemasan lansia lewat sapaan Sunda yang halus dan pengaturan menu bergizi.",
    skills: ["Stimulasi Kognitif Lansia", "Menu Diet Rendah Natrium", "Manajemen Higienitas", "Sapaan Santun Sunda"],
    certifications: ["Ijazah Kebidanan Terdaftar", "Geriatric Care BNSP", "SKCK Polda Jabar"]
  },
  {
    id: 4,
    name: "Andi Tenriwali",
    age: 35,
    gender: "Wanita",
    location: "Medan",
    areaDetail: "Medan Baru, Kota Medan",
    coords: { lat: 3.5852, lng: 98.6675 },
    skillType: "Non-Medis",
    languages: ["Bugis", "Batak"],
    rating: 4.9,
    reviewsCount: 88,
    pricePerShift: 210000,
    photoUrl: "images/caregiver-andi.jpg",
    tagline: "Caregiver Sahabat Hati & Pendamping Ibadah",
    bio: "Berjiwa hangat dan penuh empati. Fokus menemani opa/oma yang kerap merasa kesepian di rumah, membacakan buku, menemani ibadah, serta menguasai percakapan bahasa Batak dan Bugis.",
    skills: ["Teman Cerita & Doa", "Memasak Makanan Lembut", "Bilingual Bugis-Batak", "Pengawasan Obat Terjadwal"],
    certifications: ["Pelatihan Elderly Emotional Care", "K3 Rumah Tangga", "SKCK Terverifikasi"]
  }
];

// STATE MANAGEMENT
let currentCaregiver = caregiversData[0];
let bookingStep = 1;
let selectedShiftTitle = "Shift Pagi (07:00 - 15:00)";
let shiftMultiplier = 1.0;

// GOOGLE MAPS STATE
let googleMap = null;
let mapMarkers = [];

// Helper Format Rupiah
function formatRupiah(num) {
  return new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(num);
}

// 1. RENDER DAFTAR PENDAMPING (KATALOG)
function renderCaregivers(list) {
  const grid = document.getElementById('caregiversGrid');
  const noResults = document.getElementById('noResults');
  const counter = document.getElementById('resultsCount');

  if (!grid) return;
  grid.innerHTML = '';
  if (counter) counter.innerText = `Menampilkan ${list.length} pendamping aktif`;

  if (list.length === 0) {
    if (noResults) noResults.classList.remove('hidden');
    renderMapCaregiverMiniList([]);
    return;
  }
  if (noResults) noResults.classList.add('hidden');

  list.forEach(item => {
    const isMed = item.skillType === 'Medis';
    const card = document.createElement('div');
    card.className = "bg-white rounded-3xl p-4 sm:p-5 border border-stone-200/90 shadow-sm hover:shadow-bento hover:-translate-y-1 transition duration-200 flex flex-col justify-between cursor-pointer group";

    card.onclick = (e) => {
      if (e.target.tagName !== 'BUTTON' && !e.target.closest('button')) {
        focusMapOnCaregiver(item.id);
      }
    };

    const langBadges = item.languages.map(l => 
      `<span class="text-[10px] bg-stone-100 text-stone-700 px-2 py-0.5 rounded font-medium">
        <i class="fa-solid fa-comment-dots text-[9px] text-teal-600 mr-1"></i>${l}
      </span>`
    ).join('');

    card.innerHTML = `
      <div>
        <div class="relative mb-3.5">
          <img src="${item.photoUrl}" alt="${item.name}" class="w-full h-44 object-cover rounded-2xl">
          <span class="absolute top-2.5 left-2.5 px-2.5 py-0.5 rounded-full text-[10px] font-bold shadow ${isMed ? 'bg-teal-800 text-white' : 'bg-stone-800 text-white'}">
            ${isMed ? '<i class="fa-solid fa-stethoscope mr-1"></i> Medis' : '<i class="fa-solid fa-hand-holding-heart mr-1"></i> Sahabat Harian'}
          </span>
          <span class="absolute bottom-2.5 right-2.5 bg-white/95 backdrop-blur px-2 py-0.5 rounded-lg text-[10px] font-bold text-stone-800 shadow-sm">
            <i class="fa-solid fa-location-dot text-brand-teal mr-1"></i> ${item.location}
          </span>
        </div>

        <div class="space-y-1.5">
          <div class="flex items-center justify-between">
            <h3 class="font-bold text-stone-900 text-sm">${item.name}</h3>
            <span class="text-xs text-stone-400 font-semibold">${item.age} th</span>
          </div>
          <p class="text-xs text-brand-teal font-medium line-clamp-1">${item.tagline}</p>
          
          <div class="flex items-center gap-1.5 text-xs text-stone-500 pt-1">
            <span class="text-amber-500 font-bold"><i class="fa-solid fa-star"></i> ${item.rating}</span>
            <span>(${item.reviewsCount} review)</span>
            <span class="text-emerald-600 font-semibold ml-auto text-[11px]"><i class="fa-solid fa-shield-check"></i> SKCK</span>
          </div>

          <div class="pt-2">
            <span class="text-[10px] uppercase font-bold text-stone-400 block mb-1">Bahasa Daerah:</span>
            <div class="flex flex-wrap gap-1">${langBadges}</div>
          </div>
        </div>
      </div>

      <div class="mt-4 pt-3 border-t border-stone-100">
        <div class="flex items-baseline justify-between mb-3">
          <span class="text-[10px] text-stone-400 font-mono">Tarif Shift</span>
          <div>
            <span class="text-sm font-extrabold text-stone-900">${formatRupiah(item.pricePerShift)}</span>
            <span class="text-[10px] text-stone-500">/shift</span>
          </div>
        </div>
        
        <div class="grid grid-cols-2 gap-2">
          <button onclick="openProfileModal(${item.id})" class="w-full py-1.5 rounded-xl border border-stone-200 hover:bg-stone-50 text-stone-700 text-xs font-bold transition">
            Profil & CV
          </button>
          <button onclick="startBookingFlow(${item.id})" class="w-full py-1.5 rounded-xl bg-brand-teal hover:bg-brand-teal-dark text-white text-xs font-bold transition shadow-sm">
            Pesan
          </button>
        </div>
      </div>
    `;

    grid.appendChild(card);
  });

  renderMapCaregiverMiniList(list);
  updateMapMarkers(list);
}

// 2. RENDER DAFTAR SIDEBAR PETA
function renderMapCaregiverMiniList(list) {
  const container = document.getElementById('mapCaregiversList');
  const statusText = document.getElementById('mapStatusText');
  if (!container) return;

  container.innerHTML = '';
  if (statusText) statusText.innerText = `${list.length} Titik Siaga`;

  if (list.length === 0) {
    container.innerHTML = `<p class="text-xs text-stone-400 text-center py-4">Tidak ada pendamping di area filter ini.</p>`;
    return;
  }

  list.forEach(item => {
    const row = document.createElement('div');
    row.className = "p-2.5 rounded-xl border border-stone-200 hover:border-brand-teal bg-white hover:bg-teal-50/40 transition cursor-pointer flex items-center justify-between text-xs";
    row.onclick = () => focusMapOnCaregiver(item.id);

    row.innerHTML = `
      <div class="flex items-center gap-2.5">
        <img src="${item.photoUrl}" alt="${item.name}" class="w-9 h-9 rounded-lg object-cover">
        <div>
          <p class="font-bold text-stone-900">${item.name}</p>
          <p class="text-[10px] text-stone-500"><i class="fa-solid fa-map-pin text-brand-teal"></i> ${item.areaDetail}</p>
        </div>
      </div>
      <button onclick="event.stopPropagation(); startBookingFlow(${item.id})" class="px-2.5 py-1 bg-stone-900 hover:bg-brand-teal text-white text-[10px] font-bold rounded-lg transition">
        Pilih
      </button>
    `;
    container.appendChild(row);
  });
}

// 3. FILTERING LOGIC
function applyFilters() {
  const kw = document.getElementById('filterKeyword')?.value.toLowerCase().trim() || '';
  const loc = document.getElementById('filterLocation')?.value || 'ALL';
  const lang = document.getElementById('filterLanguage')?.value || 'ALL';
  const skill = document.getElementById('filterSkill')?.value || 'ALL';
  const gender = document.getElementById('filterGender')?.value || 'ALL';

  const filtered = caregiversData.filter(item => {
    const matchKw = item.name.toLowerCase().includes(kw) || 
                    item.tagline.toLowerCase().includes(kw) || 
                    item.bio.toLowerCase().includes(kw) ||
                    item.skills.some(s => s.toLowerCase().includes(kw));
    const matchLoc = (loc === 'ALL') || (item.location === loc);
    const matchLang = (lang === 'ALL') || (item.languages.includes(lang));
    const matchSkill = (skill === 'ALL') || (item.skillType === skill);
    const matchGender = (gender === 'ALL') || (item.gender === gender);

    return matchKw && matchLoc && matchLang && matchSkill && matchGender;
  });

  renderCaregivers(filtered);
}

function resetFilters() {
  const kw = document.getElementById('filterKeyword');
  const loc = document.getElementById('filterLocation');
  const lang = document.getElementById('filterLanguage');
  const skill = document.getElementById('filterSkill');
  const gender = document.getElementById('filterGender');

  if (kw) kw.value = '';
  if (loc) loc.value = 'ALL';
  if (lang) lang.value = 'ALL';
  if (skill) skill.value = 'ALL';
  if (gender) gender.value = 'ALL';

  applyFilters();
}

// 4. GOOGLE MAPS API INTEGRATION
function loadGoogleMapsWithKey() {
  const input = document.getElementById('gmapsApiKeyInput');
  const apiKey = input ? input.value.trim() : '';

  if (!apiKey) {
    alert('Silakan masukkan Google Maps API Key Anda terlebih dahulu.');
    return;
  }

  const fallback = document.getElementById('gmapFallback');
  if (fallback) fallback.classList.add('hidden');

  const existingScript = document.getElementById('gmapsScriptTag');
  if (existingScript) existingScript.remove();

  const script = document.createElement('script');
  script.id = 'gmapsScriptTag';
  script.src = `https://maps.googleapis.com/maps/api/js?key=${apiKey}&callback=initGoogleMap`;
  script.async = true;
  script.defer = true;
  script.onerror = () => {
    alert('Gagal memuat Google Maps. Periksa apakah API Key Anda valid dan mengizinkan Maps JavaScript API.');
    if (fallback) fallback.classList.remove('hidden');
  };
  document.head.appendChild(script);
}

window.initGoogleMap = function() {
  const mapDiv = document.getElementById('gmapContainer');
  const fallback = document.getElementById('gmapFallback');
  if (fallback) fallback.classList.add('hidden');
  if (!mapDiv) return;

  const defaultCenter = { lat: -6.2088, lng: 106.8456 };

  googleMap = new google.maps.Map(mapDiv, {
    zoom: 11,
    center: defaultCenter,
    mapTypeControl: false,
    streetViewControl: false,
    fullscreenControl: true,
    styles: [
      { featureType: "poi", elementType: "labels", stylers: [{ visibility: "off" }] }
    ]
  });

  updateMapMarkers(caregiversData);
};

function updateMapMarkers(list) {
  if (!googleMap || typeof google === 'undefined' || !google.maps) return;

  mapMarkers.forEach(m => m.setMap(null));
  mapMarkers = [];

  const bounds = new google.maps.LatLngBounds();

  list.forEach(caregiver => {
    const marker = new google.maps.Marker({
      position: caregiver.coords,
      map: googleMap,
      title: caregiver.name,
      animation: google.maps.Animation.DROP
    });

    const infoWindow = new google.maps.InfoWindow({
      content: `
        <div style="font-family: sans-serif; padding: 4px; max-width: 200px;">
          <strong style="font-size: 13px; color: #1C1917;">${caregiver.name}</strong>
          <p style="font-size: 11px; color: #0D9488; margin: 2px 0;">${caregiver.tagline}</p>
          <p style="font-size: 11px; color: #666;">${caregiver.areaDetail}</p>
          <div style="margin-top: 6px;">
            <button onclick="startBookingFlow(${caregiver.id})" style="background:#0D9488; color:#fff; border:none; padding:4px 8px; border-radius:6px; font-size:10px; font-weight:bold; cursor:pointer;">
              Pesan (${formatRupiah(caregiver.pricePerShift)})
            </button>
          </div>
        </div>
      `
    });

    marker.addListener('click', () => {
      infoWindow.open(googleMap, marker);
    });

    marker.caregiverId = caregiver.id;
    marker.infoWindow = infoWindow;
    mapMarkers.push(marker);
    bounds.extend(caregiver.coords);
  });

  if (list.length > 0) {
    googleMap.fitBounds(bounds);
    if (list.length === 1) googleMap.setZoom(13);
  }
}

function focusMapOnCaregiver(id) {
  const caregiver = caregiversData.find(c => c.id === id);
  if (!caregiver) return;

  const section = document.getElementById('gmapSection');
  if (section) section.scrollIntoView({ behavior: 'smooth' });

  if (googleMap && typeof google !== 'undefined') {
    googleMap.panTo(caregiver.coords);
    googleMap.setZoom(14);
    const targetMarker = mapMarkers.find(m => m.caregiverId === id);
    if (targetMarker) {
      targetMarker.infoWindow.open(googleMap, targetMarker);
    }
  } else {
    alert(`Lokasi ${caregiver.name}:\n${caregiver.areaDetail} (${caregiver.location})\nKoordinat: Lat ${caregiver.coords.lat}, Lng ${caregiver.coords.lng}`);
  }
}

function simulateInteractiveMap() {
  const container = document.getElementById('gmapContainer');
  const fallback = document.getElementById('gmapFallback');
  if (fallback) fallback.classList.add('hidden');
  if (!container) return;

  container.innerHTML = `
    <div class="relative w-full h-full min-h-[440px]">
      <iframe 
        width="100%" 
        height="100%" 
        style="min-height:440px; border:0; border-radius:1rem;" 
        src="https://www.openstreetmap.org/export/embed.html?bbox=106.75%2C-6.35%2C106.95%2C-6.15&amp;layer=mapnik" 
        loading="lazy">
      </iframe>
      <div class="absolute bottom-3 left-3 bg-white/95 backdrop-blur px-3 py-1.5 rounded-xl border border-stone-200 text-[10px] font-bold text-stone-800 shadow">
        <i class="fa-solid fa-map text-brand-teal mr-1"></i> Preview Peta Wilayah Jabodetabek
      </div>
    </div>
  `;
}

// 5. MODAL DETAIL PROFIL & RESUME
function openProfileModal(id) {
  const item = caregiversData.find(c => c.id === id);
  if (!item) return;

  currentCaregiver = item;
  const priceLabel = document.getElementById('modalProfilePrice');
  const bookBtn = document.getElementById('modalBookBtn');
  const container = document.getElementById('modalProfileContent');

  if (priceLabel) priceLabel.innerText = `${formatRupiah(item.pricePerShift)} / shift`;
  if (bookBtn) {
    bookBtn.onclick = () => {
      closeProfileModal();
      startBookingFlow(item.id);
    };
  }

  if (container) {
    container.innerHTML = `
      <div class="flex items-start gap-4">
        <img src="${item.photoUrl}" alt="${item.name}" class="w-20 h-20 rounded-2xl object-cover ring-2 ring-brand-teal shadow">
        <div class="space-y-1">
          <div class="flex items-center gap-2">
            <h4 class="font-extrabold text-stone-900 text-base">${item.name}</h4>
            <span class="text-[10px] font-bold px-2 py-0.5 rounded-full bg-teal-100 text-brand-teal-dark">${item.age} th</span>
          </div>
          <p class="text-xs font-semibold text-brand-teal">${item.tagline}</p>
          <p class="text-xs text-stone-500"><i class="fa-solid fa-map-pin text-stone-400"></i> ${item.areaDetail} &bull; ${item.gender}</p>
        </div>
      </div>

      <div>
        <h5 class="text-[11px] font-bold uppercase tracking-wider text-stone-400 mb-1.5">Ringkasan Pengalaman</h5>
        <p class="text-xs text-stone-700 leading-relaxed bg-stone-50 p-3 rounded-2xl border border-stone-200">${item.bio}</p>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs">
        <div>
          <h5 class="text-[11px] font-bold uppercase tracking-wider text-stone-400 mb-1.5">Keahlian Medis & Asuhan</h5>
          <ul class="space-y-1 text-stone-700">
            ${item.skills.map(s => `<li class="flex items-center gap-1.5"><i class="fa-solid fa-check text-emerald-600 text-[10px]"></i> ${s}</li>`).join('')}
          </ul>
        </div>
        <div>
          <h5 class="text-[11px] font-bold uppercase tracking-wider text-stone-400 mb-1.5">Legalitas & Sertifikat</h5>
          <ul class="space-y-1 text-stone-700">
            ${item.certifications.map(c => `<li class="flex items-center gap-1.5"><i class="fa-solid fa-shield-halved text-brand-teal text-[10px]"></i> ${c}</li>`).join('')}
          </ul>
        </div>
      </div>

      <div class="p-3 bg-teal-50 border border-teal-200 rounded-2xl flex items-center justify-between text-xs">
        <div>
          <span class="font-bold text-teal-900 block">Bahasa Daerah Percakapan:</span>
          <span class="text-teal-700">${item.languages.join(', ')}</span>
        </div>
        <i class="fa-solid fa-comments text-brand-teal text-lg"></i>
      </div>
    `;
  }

  const modal = document.getElementById('profileModal');
  if (modal) modal.classList.remove('hidden');
}

function closeProfileModal() {
  const modal = document.getElementById('profileModal');
  if (modal) modal.classList.add('hidden');
}

// 6. INTERACTIVE 3-STEP BOOKING FLOW
function startBookingFlow(caregiverId) {
  const item = caregiversData.find(c => c.id === caregiverId);
  if (item) currentCaregiver = item;

  const img = document.getElementById('bookingCaregiverImg');
  const name = document.getElementById('bookingCaregiverName');
  const rate = document.getElementById('bookingCaregiverRate');
  const dateInput = document.getElementById('bookDate');

  if (img) img.src = currentCaregiver.photoUrl;
  if (name) name.innerText = currentCaregiver.name;
  if (rate) rate.innerText = `${formatRupiah(currentCaregiver.pricePerShift)} / shift`;

  const tomorrow = new Date();
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (dateInput) dateInput.value = tomorrow.toISOString().split('T')[0];

  bookingStep = 1;
  updateStepperView();
  calculateBookingCost();

  const modal = document.getElementById('bookingModal');
  if (modal) modal.classList.remove('hidden');
}

function closeBookingModal() {
  const modal = document.getElementById('bookingModal');
  if (modal) modal.classList.add('hidden');
}

function selectShift(element, shiftName, multiplier) {
  document.querySelectorAll('.shift-option').forEach(el => {
    el.classList.remove('border-brand-teal', 'bg-teal-50/40');
    el.classList.add('border-stone-200');
  });
  element.classList.add('border-brand-teal', 'bg-teal-50/40');
  element.classList.remove('border-stone-200');
  selectedShiftTitle = shiftName;
  shiftMultiplier = multiplier;
  calculateBookingCost();
}

function calculateBookingCost() {
  const durationSelect = document.getElementById('bookDurationDays');
  const days = parseInt(durationSelect ? durationSelect.value : 1);
  const base = currentCaregiver.pricePerShift;
  let subtotal = base * shiftMultiplier * days;

  if (days === 7) subtotal *= 0.95;
  if (days === 30) subtotal *= 0.88;

  const fee = 15000;
  const total = subtotal + fee;

  const nameInput = document.getElementById('elderName');
  const summaryName = document.getElementById('summaryElderName');
  const summaryShift = document.getElementById('summaryShift');
  const summaryDays = document.getElementById('summaryDays');
  const summarySubtotal = document.getElementById('summarySubtotal');
  const summaryTotal = document.getElementById('summaryTotal');

  if (summaryName) summaryName.innerText = (nameInput && nameInput.value) ? nameInput.value : "Belum diisi";
  if (summaryShift) summaryShift.innerText = selectedShiftTitle;
  if (summaryDays) summaryDays.innerText = `${days} Hari`;
  if (summarySubtotal) summarySubtotal.innerText = formatRupiah(subtotal);
  if (summaryTotal) summaryTotal.innerText = formatRupiah(total);
}

function navigateStep(direction) {
  if (direction === 1) {
    if (bookingStep === 1) {
      const dateVal = document.getElementById('bookDate')?.value;
      if (!dateVal) {
        alert('Silakan pilih tanggal pendampingan.');
        return;
      }
    } else if (bookingStep === 2) {
      const nameVal = document.getElementById('elderName')?.value;
      const ageVal = document.getElementById('elderAge')?.value;
      if (!nameVal || !ageVal) {
        alert('Mohon isi nama dan usia lansia.');
        return;
      }
      calculateBookingCost();
    }
  }

  bookingStep += direction;
  updateStepperView();
}

function updateStepperView() {
  const s1 = document.getElementById('stepContent1');
  const s2 = document.getElementById('stepContent2');
  const s3 = document.getElementById('stepContent3');
  const prevBtn = document.getElementById('prevStepBtn');
  const nextBtn = document.getElementById('nextStepBtn');
  const submitBtn = document.getElementById('submitOrderBtn');

  if (s1) s1.classList.toggle('hidden', bookingStep !== 1);
  if (s2) s2.classList.toggle('hidden', bookingStep !== 2);
  if (s3) s3.classList.toggle('hidden', bookingStep !== 3);

  if (prevBtn) prevBtn.classList.toggle('hidden', bookingStep === 1);
  if (nextBtn) nextBtn.classList.toggle('hidden', bookingStep === 3);
  if (submitBtn) submitBtn.classList.toggle('hidden', bookingStep !== 3);

  for (let i = 1; i <= 3; i++) {
    const tab = document.getElementById(`stepTab${i}`);
    if (tab) {
      if (i === bookingStep) {
        tab.className = "py-1.5 border-b-2 border-brand-teal text-brand-teal font-bold";
      } else if (i < bookingStep) {
        tab.className = "py-1.5 border-b-2 border-emerald-600 text-emerald-600 font-bold";
      } else {
        tab.className = "py-1.5 border-b-2 border-stone-200 text-stone-400 font-medium";
      }
    }
  }
}

function handleBookingSubmit(e) {
  e.preventDefault();
  const elder = document.getElementById('elderName')?.value || 'Lansia';
  const method = document.querySelector('input[name="paymentMethod"]:checked')?.value || 'Virtual Account';
  alert(`Pemesanan Berhasil!\n\nPendamping: ${currentCaregiver.name}\nUntuk: ${elder}\nPembayaran: ${method}\n\nInstruksi transfer telah dikirimkan.`);
  closeBookingModal();
  document.getElementById('bookingForm')?.reset();
}

// 7. SIMULASI LIVE ACTIVITY LOG
function simulateAddLog() {
  const stream = document.getElementById('activityStream');
  if (!stream) return;

  const now = new Date();
  const timeStr = now.toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' }) + ' WIB';

  const samples = [
    {
      badge: "Camilan Siang",
      color: "bg-teal-100 text-teal-800",
      text: "Ibu menghabiskan sepiring buah pepaya potong segar dan segelas air putih hangat."
    },
    {
      badge: "Terapi Gerak",
      color: "bg-blue-100 text-blue-800",
      text: "Latihan rentang gerak jari tangan dan peregangan kaki ringan selama 15 menit tanpa keluhan nyeri."
    },
    {
      badge: "Istirahat Siang",
      color: "bg-purple-100 text-purple-800",
      text: "Ibu beristirahat tidur siang dengan nyaman di kamar setelah dibantu membersihkan wajah."
    }
  ];

  const chosen = samples[Math.floor(Math.random() * samples.length)];
  const card = document.createElement('div');
  card.className = "p-3.5 rounded-2xl bg-teal-50/70 border border-teal-300 text-xs space-y-1.5 animate-in fade-in slide-in-from-top-2";
  card.innerHTML = `
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="font-mono font-bold text-stone-800 text-[11px]">${timeStr}</span>
        <span class="px-2 py-0.5 rounded ${chosen.color} font-semibold text-[10px]">${chosen.badge}</span>
      </div>
      <span class="text-[10px] text-emerald-600 font-bold"><i class="fa-solid fa-bolt"></i> Baru Saja</span>
    </div>
    <p class="text-[11px] text-stone-700">${chosen.text}</p>
  `;

  stream.insertBefore(card, stream.firstChild);
}

// 8. SOS & MOBILE NAV TOGGLES
function toggleSosModal(show) {
  const modal = document.getElementById('sosModal');
  if (modal) modal.classList.toggle('hidden', !show);
}

function toggleMobileNav() {
  const nav = document.getElementById('mobileNav');
  const icon = document.getElementById('navMenuIcon');
  if (!nav) return;

  nav.classList.toggle('hidden');
  if (icon) {
    if (nav.classList.contains('hidden')) {
      icon.className = "fa-solid fa-bars text-lg";
    } else {
      icon.className = "fa-solid fa-xmark text-lg";
    }
  }
}

// 9. CAREGIVER TOOLKIT & SHIFT COMMAND LOGIC
const TARGET_PATIENT_LOCATION = {
  lat: -6.2297,
  lng: 106.8559,
  address: "Jl. Tebet Barat Dalam No. 14, Jakarta Selatan"
};

let shiftSeconds = 3 * 3600 + 42 * 60 + 15; // default 03:42:15 for live feel
let shiftTimerInterval = null;

function startShiftTimer() {
  const display = document.getElementById('shiftTimerDisplay');
  if (!display) return;

  if (shiftTimerInterval) clearInterval(shiftTimerInterval);

  shiftTimerInterval = setInterval(() => {
    shiftSeconds++;
    const h = String(Math.floor(shiftSeconds / 3600)).padStart(2, '0');
    const m = String(Math.floor((shiftSeconds % 3600) / 60)).padStart(2, '0');
    const s = String(shiftSeconds % 60).padStart(2, '0');
    display.innerText = `${h}:${m}:${s}`;
  }, 1000);
}

function calculateDistanceMeters(lat1, lon1, lat2, lon2) {
  const R = 6371e3;
  const rad = (deg) => deg * (Math.PI / 180);
  const dLat = rad(lat2 - lat1);
  const dLon = rad(lon2 - lon1);
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(rad(lat1)) * Math.cos(rad(lat2)) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return Math.round(R * c);
}

function performGpsCheckin() {
  const badge = document.getElementById('presenceBadge');
  const note = document.getElementById('presenceNote');
  const btn = document.getElementById('btnGpsCheckin');

  if (btn) btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin mr-1"></i> Memvalidasi GPS...';

  if (!navigator.geolocation) {
    simulatePresenceSuccess(badge, note, btn, 22);
    return;
  }

  navigator.geolocation.getCurrentPosition(
    (pos) => {
      const dist = calculateDistanceMeters(pos.coords.latitude, pos.coords.longitude, TARGET_PATIENT_LOCATION.lat, TARGET_PATIENT_LOCATION.lng);
      if (dist <= 150) {
        simulatePresenceSuccess(badge, note, btn, dist);
      } else {
        const textDist = dist > 1000 ? `${(dist / 1000).toFixed(1)} km` : `${dist} m`;
        simulatePresenceSuccess(badge, note, btn, 18, `GPS Aktif (${textDist} dari pos). Mode Demo Ekspo: Presensi disetujui di lokasi.`);
      }
    },
    (err) => {
      simulatePresenceSuccess(badge, note, btn, 16, "GPS browser offline/ditolak. Mode Demo Ekspo: Presensi berhasil disetujui.");
    },
    { timeout: 5000 }
  );
}

function simulatePresenceSuccess(badge, note, btn, meters, customNote = null) {
  if (badge) {
    badge.className = "text-[10px] font-bold px-2 py-0.5 rounded-full bg-emerald-100 text-emerald-800 flex items-center gap-1";
    badge.innerHTML = `<i class="fa-solid fa-circle-check text-[9px]"></i> Hadir (${meters} m)`;
  }
  if (btn) {
    btn.className = "w-full py-2.5 bg-emerald-700 text-white text-xs font-bold rounded-xl shadow-sm transition flex items-center justify-center gap-2 cursor-default";
    btn.innerHTML = `<i class="fa-solid fa-check"></i> <span>Presensi Terverifikasi</span>`;
    btn.disabled = true;
  }
  if (note) {
    note.className = "text-[10px] text-emerald-700 font-medium text-center";
    note.innerText = customNote || `Verifikasi geofence berhasil. Pendamping berada dalam radius toleransi tugas (${meters} meter).`;
  }
}

function handleShiftCheckout() {
  const confirmCheckout = confirm("Apakah Anda yakin ingin menyelesaikan shift ini?\n\nSemua rekap vital dan log hari ini akan dikunci dan dikirim ke keluarga untuk konfirmasi pelepasan dana escrow.");
  if (!confirmCheckout) return;

  if (shiftTimerInterval) clearInterval(shiftTimerInterval);

  const display = document.getElementById('shiftTimerDisplay');
  const badge = document.getElementById('presenceBadge');
  const btn = document.getElementById('btnGpsCheckin');

  if (display) display.classList.add('text-stone-400');
  if (badge) {
    badge.className = "text-[10px] font-bold px-2 py-0.5 rounded-full bg-stone-200 text-stone-700";
    badge.innerText = "Shift Selesai";
  }
  if (btn) {
    btn.className = "w-full py-2.5 bg-stone-300 text-stone-600 text-xs font-bold rounded-xl cursor-not-allowed";
    btn.innerHTML = "Shift Telah Ditutup";
    btn.disabled = true;
  }

  alert("Shift berhasil diselesaikan!\n\nLaporan shift telah diarsipkan. Honor shift Rp 280.000 telah masuk ke antrean escrow.");
}

function switchCaregiverTab(tabId) {
  const tabs = ['vitals', 'protocol', 'wallet'];
  tabs.forEach(t => {
    const btn = document.getElementById(`caregiverTab-${t}`);
    const pane = document.getElementById(`caregiverPane-${t}`);
    if (btn) {
      if (t === tabId) {
        btn.className = "pb-2 border-b-2 border-brand-teal text-brand-teal flex items-center gap-1.5 whitespace-nowrap font-bold";
      } else {
        btn.className = "pb-2 border-b-2 border-transparent text-stone-500 hover:text-stone-800 flex items-center gap-1.5 whitespace-nowrap font-medium";
      }
    }
    if (pane) {
      pane.classList.toggle('hidden', t !== tabId);
    }
  });
}

function submitCaregiverLog(e) {
  e.preventDefault();

  const category = document.getElementById('vitalCategory')?.value || 'Pemeriksaan Vital';
  const time = document.getElementById('vitalTime')?.value || '11:45 WIB';
  const bp = document.getElementById('vitalBP')?.value || '120/80';
  const pulse = document.getElementById('vitalPulse')?.value || '76';
  const glucose = document.getElementById('vitalGlucose')?.value || '110';
  const spo2 = document.getElementById('vitalSpO2')?.value || '98';
  const portion = document.querySelector('input[name="mealPortion"]:checked')?.value || 'Habis';
  const notes = document.getElementById('vitalNotes')?.value || 'Kondisi stabil dan nyaman.';

  const med1 = document.getElementById('medCheck1')?.checked ? 'Candesartan 8mg (Diminum)' : '';
  const med2 = document.getElementById('medCheck2')?.checked ? 'Vitamin D3 (Diminum)' : '';
  const medList = [med1, med2].filter(Boolean).join(', ') || 'Tanpa obat oral pada jam ini';

  const stream = document.getElementById('activityStream');
  if (!stream) return;

  const card = document.createElement('div');
  card.className = "p-3.5 rounded-2xl bg-teal-50 border-2 border-brand-teal/80 text-xs space-y-2 shadow-sm animate-in fade-in slide-in-from-top-3 duration-300";
  card.innerHTML = `
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="font-mono font-bold text-brand-teal-dark text-[11px]">${time}</span>
        <span class="px-2 py-0.5 rounded bg-brand-teal text-white font-bold text-[10px]">${category}</span>
      </div>
      <span class="text-[10px] text-emerald-700 font-bold flex items-center gap-1">
        <i class="fa-solid fa-circle-check"></i> Baru Saja Diinput
      </span>
    </div>

    <div class="grid grid-cols-3 gap-2 text-center">
      <div class="bg-white p-2 rounded-xl border border-teal-100">
        <span class="text-[10px] text-stone-400 block">Tekanan Darah</span>
        <span class="font-bold text-brand-teal font-mono text-xs">${bp} mmHg</span>
      </div>
      <div class="bg-white p-2 rounded-xl border border-teal-100">
        <span class="text-[10px] text-stone-400 block">Nadi / SpO2</span>
        <span class="font-bold text-stone-800 font-mono text-xs">${pulse} bpm &bull; ${spo2}%</span>
      </div>
      <div class="bg-white p-2 rounded-xl border border-teal-100">
        <span class="text-[10px] text-stone-400 block">Gula Darah</span>
        <span class="font-bold text-stone-800 font-mono text-xs">${glucose} mg/dL</span>
      </div>
    </div>

    <div class="text-[11px] text-stone-700 space-y-0.5 bg-white/70 p-2 rounded-lg border border-teal-100">
      <p><strong class="text-stone-900">Obat & Makan:</strong> ${medList} &bull; Porsi: ${portion}</p>
      <p><strong class="text-stone-900">Catatan Caregiver:</strong> ${notes}</p>
    </div>
  `;

  stream.insertBefore(card, stream.firstChild);

  // Scroll to stream smoothly
  document.getElementById('live-log')?.scrollIntoView({ behavior: 'smooth' });

  alert('Laporan berhasil disimpan!\n\nData tanda vital langsung disinkronkan ke Buku Catatan Digital & pesan WhatsApp keluarga lansia.');
}

function handleCaregiverPayout() {
  const nominal = "Rp 3.360.000";
  const bank = "BCA (8820-192-331 a.n. Siti Rahayu)";
  const confirmPayout = confirm(`Konfirmasi penarikan honor:\n\nJumlah: ${nominal}\nRekening Tujuan: ${bank}\nBiaya Transfer: Rp 0 (Bebas Biaya)\n\nLanjutkan proses pencairan?`);
  if (!confirmPayout) return;

  alert(`Penarikan Berhasil Diajukan!\n\nDana ${nominal} sedang diproses secara real-time ke rekening ${bank}.\nEstimasi masuk: 5 - 15 menit.`);
}

// 10. INITIAL LOAD
document.addEventListener('DOMContentLoaded', () => {
  renderCaregivers(caregiversData);
  startShiftTimer();
});
