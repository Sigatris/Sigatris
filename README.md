# Tarczociąg BT

Aplikacja Flutter do sterowania bezprzewodowym tarczociągiem strzeleckim
przez Bluetooth Classic (SPP/RFCOMM).

## Zawartość repozytorium

```
tarczociag_bt/
├── .github/workflows/build-apk.yml   ← workflow budujący i publikujący APK
├── lib/main.dart                      ← cały kod aplikacji
├── pubspec.yaml                       ← zależności projektu
├── analysis_options.yaml
├── .gitignore
└── README.md
```

### Dlaczego nie ma folderu `android/`?

Folder `android/` (projekty Gradle, `AndroidManifest.xml`, ikony itd.) jest
generowany **automatycznie przy każdym uruchomieniu workflow** komendą
`flutter create`. Zawiera on binarne pliki Gradle Wrappera, które muszą
pochodzić z rzeczywistej instalacji Fluttera dopasowanej do wersji SDK —
ręczne kopiowanie takich plików grozi uszkodzonym/niebudującym się projektem.
Dzięki automatycznemu generowaniu folder jest zawsze świeży i zgodny
z aktualną wersją Fluttera z CI, a workflow sam dokleja do niego wymagane
uprawnienia Bluetooth.

Jeśli chcesz pracować nad częścią natywną (Kotlin/Java) lokalnie w Android
Studio, wygeneruj folder u siebie jednorazowo:

```bash
flutter create --platforms=android --org com.tarczociag .
```

i usuń wpis `/android/` z `.gitignore`, jeśli chcesz go też commitować.

## Uruchomienie lokalnie (opcjonalnie)

```bash
flutter pub get
flutter create --platforms=android --org com.tarczociag .   # tylko za pierwszym razem
flutter run
```

## Budowanie APK przez GitHub Actions

1. Wypchnij repozytorium na GitHub (patrz niżej).
2. Workflow `.github/workflows/build-apk.yml` uruchomi się automatycznie po
   pushu na branch `main` (albo ręcznie: zakładka **Actions** → **Build APK**
   → **Run workflow**).
3. Po zakończeniu (zielony ✔):
   - **Releases** (zakładka w repo) → najnowszy release → sekcja *Assets* →
     pobierz plik `.apk` bezpośrednio na telefon (najwygodniejsze, działa
     w przeglądarce mobilnej bez logowania).
   - albo zakładka **Actions** → ostatni bieg → sekcja *Artifacts* → pobierz
     ZIP z plikiem `.apk` (wymaga zalogowania do GitHub).
4. Zainstaluj pobrany plik `.apk` na telefonie — Android poprosi o zgodę na
   instalację z „nieznanego źródła” (dla przeglądarki lub menedżera plików).

> Domyślnie workflow buduje osobne pliki APK per architektura procesora
> (`--split-per-abi`) — dla większości nowszych telefonów wybierz plik
> zawierający `arm64-v8a` w nazwie. Aby zamiast tego zbudować jeden
> uniwersalny plik pasujący do każdego telefonu, usuń flagę
> `--split-per-abi` w kroku „Zbuduj APK (release)” w pliku workflow.

## Wypchnięcie repozytorium na GitHub

```bash
git init
git add .
git commit -m "Initial commit – Tarczociąg BT"
git branch -M main
git remote add origin https://github.com/<twoj-login>/tarczociag-bt.git
git push -u origin main
```

## Wymagane uprawnienia Bluetooth (dopisywane automatycznie przez workflow)

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
```
