# 🧹 Image Cleaner

> *Your phone gallery is a mess. Let's fix that.*

Built this because I had **20k+ photos** on my phone and zero motivation to delete them manually. So I automated it. 

---

## 📱 Download

👉 **[Grab the APK from Releases](../../releases/latest)** — sideload it, done.

> Works on Android. Install unknown apps must be enabled.

---

## 🤔 What does it do?

Your gallery is full of:
- 📸 The same photo taken 6 times because you weren't sure which one was good
- 🌫️ Blurry shots you forgot to delete
- 🌑 Dark photos where you accidentally tapped the shutter
- 🗑️ OTP screenshots, discount offers, "click here to claim your prize" junk

**Image Cleaner finds all of that and lets you bulk delete it in seconds.**

---

## ✨ Features

| Feature | How it works |
|---|---|
| 🔍 Duplicate detection | pHash + Hamming distance — finds near-identical photos |
| 🌫️ Blur detection | Laplacian variance — same math camera apps use |
| 🌑 Dark image detection | Average pixel brightness check |
| 🗑️ Junk screenshot detection | OCR via Google ML Kit + keyword matching |
| ⚡ Fast scanning | Runs in isolates, batched processing, Hive cache |
| 🗂️ Smart caching | Already-scanned images are skipped next time |

---

## 🛠️ Tech Stack

```
Flutter + Dart
├── photo_manager          — gallery access
├── google_mlkit_text_recognition  — OCR for junk detection  
├── image                  — pHash + blur math
├── hive_flutter           — local scan cache
└── photo_manager_image_provider   — thumbnail rendering
```

---

## 🚀 Build from source

```bash
git clone https://github.com/vinoth12345678910/Image-cleaner.git
cd Image-cleaner
flutter pub get
flutter build apk --release
# APK → build/app/outputs/flutter-apk/app-release.apk
```

Tested on:
- Samsung SM-E156B, Android 16 (API 36), arm64
- Flutter 3.41.6 stable

---

## 📸 How to use

1. Install APK → open app
2. Grant gallery permission
3. Tap **Scan All Images**
4. Wait (4000 images ≈ 2–3 mins first scan, instant after that thanks to cache)
5. Switch between tabs — Duplicates / Bad Quality / Junk
6. Tap images to select → hit Delete
7. Done 🎉

---

## 🧠 How the duplicate detection works

```
Every image → resized to 8x8 → greyscale → 64-bit hash
Two images → Hamming distance ≤ 10 → considered duplicates
First in group = kept automatically, rest = flagged for deletion
```

No cloud, no API calls, all on-device.

---

## ⚠️ Disclaimer

This app **permanently deletes** photos from your gallery. It asks for confirmation before deleting anything, but once gone, they're gone. Maybe back up first if you're paranoid (you should be).

---

## 📄 License

Do whatever you want with it. MIT.

```
MIT License — go wild
```
