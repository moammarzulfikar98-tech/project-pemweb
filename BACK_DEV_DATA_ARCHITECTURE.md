# DATA ARCHITECTURE — TemanLansia (fase prototype)
**Owner:** @back-dev | **Status:** Sesuai kesepakatan tim (user utama = keluarga/pengasuh)

---

## 1. Prinsip dasar

- **Sumber data:** JSON file lokal dulu (`data/*.json`). Bukan embed hardcode di `js/app.js`.
- **Fase berikutnya:** pindah ke Supabase (Auth + Postgres + Storage) kalau activity logging real-time + role separation dibutuhkan.
- **User utama:** keluarga/pengasuh lansia. Caregiver & admin = role opsional, tidak over-engineer dulu.
- **12 vs 4 caregiver:** jangan render 12 thumbnail sampai data caregiver-nya tersinkron. File gambar saja ≠ data caregiver.

---

## 2. Skema data (JSON)

### 2.1 `data/caregivers.json`

```json
{
  "caregivers": [
    {
      "id": 1,
      "name": "Siti Rahayu, S.Kep",
      "age": 32,
      "gender": "Wanita",
      "location": "Jakarta",
      "areaDetail": "Tebet, Jakarta Selatan",
      "coords": { "lat": -6.2297, "lng": 106.8559 },
      "skillType": "Medis",
      "languages": ["Jawa", "Sunda"],
      "rating": 4.9,
      "reviewsCount": 128,
      "pricePerShift": 280000,
      "photoUrl": "images/caregiver-siti.jpg",
      "tagline": "...",
      "bio": "...",
      "skills": ["BPJS", "Pertolongan Pertama"],
      "certifications": ["Doc. Sertifikasi"]
    }
  ]
}
```

### 2.2 `data/activities.json`

```json
{
  "activities": [
    {
      "id": "act_<timestamp>_<random>",
      "caregiverId": 1,
      "lansiaName": "Budi Santoso",
      "activityDate": "2026-11-03T07:00:00+07:00",
      "time": "07:00",
      "bp": "120/80",
      "pulse": 72,
      "spo2": 98,
      "glucose": 110,
      "meds": "Tidak ada",
      "portion": "Setengah porsi",
      "notes": "..."
    }
  ]
}
```

### 2.3 `data/bookings.json`

```json
{
  "bookings": [
    {
      "id": "book_<timestamp>_<random>",
      "caregiverId": 1,
      "lansiaName": "Budi Santoso",
      "date": "2026-11-05",
      "shift": "Pagi (07:00 - 15:00)",
      "status": "pending",
      "totalPrice": 280000
    }
  ]
}
```

### 2.4 `data/users.json` (opsional, untuk role management)

```json
{
  "users": [
    {
      "id": 1,
      "role": "family",
      "name": "Ahmad",
      "email": "ahmad@mail.com",
      "passwordHash": "<bcrypt>",
      "caregiverId": null
    }
  ]
}
```

> **Catatan:** `passwordHash` menggunakan bcrypt. Jangan pernah simpan plaintext.

---

## 3. Penanganan data sensitif

| Item | Status | Alasan |
|---|---|---|
| API key Google Maps (`AIzaSy...`) | 🔴 Hapus dari kode | Bisa dibaca klien, risiko keamanan & kepatutan. Ganti Leaflet + OSM. |
| Nomor rekening bank (BCA 8820-192-331) | 🔴 Jangan di klien | Data payment/financier seharusnya di backend. Fase ini placeholder saja. |
| Health data (BP, nadi, gula) | 🔴 Jangan di DOM only | Simpan ke JSON/DB dengan timestamp + ID caregiver + hash sesi. |
| Photo caregiver | ⚪ Di `data/caregivers.json` | Hanya path `images/caregiver-x.jpg`, bukan binary. |

---

## 4. Validasi data

### 4.1 Health vital (clinical range)

| Parameter | Range clinical |
|---|---|
| Tekanan darah (S/D) | 70–140 / 40–90 |
| Nadi | 50–120 ppm |
| SpO2 | 88–100% |
| Gula darah | 70–200 mg/dL (puasa) |

Variance parameter: BP / Nadi / SpO2 / Gula / Meds / Portion / Notes.

---

## 5. Log aktivitas (fase production)

1. **Input caregiver** — form harus punya dropdown/choice (bukan generate acak).
2. **Timestamp real** — `new Date().toISOString()` dengan offset `+07:00`.
3. **Link ke caregiver & lansia** — `caregiverId` + `lansiaName` dari input user.
4. **Hash sesi** — `SHA-256(sessionId + lansiaName + caregiverId)` untuk trace.
5. **Simpan ke file** — `data/activities.json` (append), bukan append DOM.

```js
// Contoh: reason log activity ke JSON, bukan ke DOM
function logActivity(payload) {
  const entry = { id: makeId(), ...payload, recordedAt: new Date().toISOString() };
  activities.push(entry);
  writeFile("data/activities.json", JSON.stringify(activities, null, 2));
}
```

---

## 6. Rekomendasi database (fase berikutnya)

| Kebutuhan | Pilihan | Alasan |
|---|---|---|
| UI prototype | JSON + Leaflet | Cepat, tanpa backend |
| Activity logging real-time | Supabase (Postgres + Realtime) | Auto timestamp, access control |
| Role separation (family/caregiver/admin) | Supabase Auth | JWT session, RBAC |
| Storage foto | Supabase Storage | Files CRUD, private policy |

> **Rekomendasi:** JSON dulu → Supabase saat ada persyaratan persetujuan data / real-time activity.

---

## 7. Tindak lanjut

1. **Kliring 12 vs 4 caregiver** — data caregiver mana yang asli? (back-dev)  
2. **Frontend** — `data/caregivers.json`, `data/activities.json`, `data/bookings.json` + fetch + fallback.  
3. **Peta** — Leaflet + OSM + marker dari `coords`.  
4. **Booking flow** — step 1 caregiver, step 2 shift, step 3 konfirmasi + validasi shift valid.  
5. **CSS** — pindahkan class Tailwind custom dari `<style>` inline ke `css/style.css`.

---

## 8. File yang dibuat/diubah

### Dibuat
- `data/caregivers.json`
- `data/activities.json`
- `data/bookings.json`
- `data/users.json` (opsional)

### Diubah
- `index.html` — hapus API key Google Maps, ganti Leaflet/OSM
- `js/app.js` — load dari JSON, fallback array default
- `css/style.css` — pindahkan class Tailwind custom

---

*Report by @back-dev — data architecture & security review.*
