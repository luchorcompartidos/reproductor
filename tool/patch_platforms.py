"""Ajustes a las carpetas que genera `flutter create` en GitHub Actions.

Uso: python3 tool/patch_platforms.py android|web
"""
import sys

SCHEME = "com.luchorcompartidos.reproductor"


def patch(path, old, new):
    s = open(path, encoding="utf-8").read()
    if new in s:
        return
    if old not in s:
        sys.exit(f"::error::No encontré el punto a modificar en {path}: {old!r}")
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
    print(f"OK {path}")


def android():
    m = "android/app/src/main/AndroidManifest.xml"
    s = open(m, encoding="utf-8").read()
    if "android.permission.INTERNET" not in s:
        patch(m, "<application", '<uses-permission android:name="android.permission.INTERNET" />\n    <application')
    s = open(m, encoding="utf-8").read()
    import re
    s = re.sub(r'android:label="[^"]*"', 'android:label="Reproductor"', s, count=1)
    open(m, "w", encoding="utf-8").write(s)
    s = open(m, encoding="utf-8").read()
    if "usesCleartextTraffic" not in s:
        # just_audio usa un proxy local (http://127.0.0.1) para mandar el token a Drive
        patch(m, "<application", '<application android:usesCleartextTraffic="true"')
    # Segundo plano (audio_service): permisos, servicio y botones multimedia
    s = open(m, encoding="utf-8").read()
    for perm in ["WAKE_LOCK", "FOREGROUND_SERVICE", "FOREGROUND_SERVICE_MEDIA_PLAYBACK"]:
        if f"android.permission.{perm}\"" not in s:
            patch(m, "<application", f'<uses-permission android:name="android.permission.{perm}" />\n    <application')
            s = open(m, encoding="utf-8").read()
    patch(m, "</application>", AUDIO_SERVICE + "\n    </application>")
    main_activity()
    desugar()
    # Vuelta del inicio de sesión: com.luchorcompartidos.reproductor://oauth
    patch(m, "</activity>", f"""    <meta-data android:name="flutter_deeplinking_enabled" android:value="false" />
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="{SCHEME}" android:host="oauth" />
            </intent-filter>
        </activity>""")


AUDIO_SERVICE = """        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>"""


def main_activity():
    """MainActivity hereda de AudioServiceActivity (requisito de audio_service)."""
    import glob
    files = glob.glob("android/app/src/main/kotlin/**/MainActivity.kt", recursive=True)
    if not files:
        sys.exit("::error::No encontré MainActivity.kt")
    for f in files:
        s = open(f, encoding="utf-8").read()
        s = s.replace("import io.flutter.embedding.android.FlutterActivity",
                      "import com.ryanheise.audioservice.AudioServiceActivity")
        s = s.replace(": FlutterActivity()", ": AudioServiceActivity()")
        if "AudioServiceActivity()" not in s:
            sys.exit(f"::error::No pude adaptar {f}")
        open(f, "w", encoding="utf-8").write(s)
        print(f"OK {f}")


HEAD_SCRIPT = """<script>
  // Android: Google vuelve acá con ?code=...&state=a_... y la página lo reenvía a la app.
  (function () {
    var p = new URLSearchParams(location.search);
    if ((p.get('state') || '').indexOf('a_') !== 0) return;
    window.__mgdCallback = true;
    var u = 'intent://oauth' + location.search +
      '#Intent;scheme=%(s)s;package=%(s)s;end';
    document.addEventListener('DOMContentLoaded', function () {
      document.title = 'Reproductor';
      document.body.innerHTML =
        '<div style="font-family:sans-serif;padding:3em 1.5em;text-align:center">' +
        '<h2>Cuenta autorizada</h2><p>Tocá el botón para volver a la app.</p>' +
        '<p><a href="' + u + '" style="display:inline-block;padding:14px 24px;' +
        'background:#1a73e8;color:#fff;border-radius:24px;text-decoration:none;' +
        'font-size:18px">Volver al Reproductor</a></p></div>';
    });
    location.replace(u);
  })();
</script>
</head>""" % {"s": SCHEME}

BOOT_OLD = '<script src="flutter_bootstrap.js" async></script>'
BOOT_NEW = """<script>
    if (!window.__mgdCallback) {
      var s = document.createElement('script');
      s.src = 'flutter_bootstrap.js';
      s.async = true;
      document.body.appendChild(s);
    }
  </script>"""


SIGNING = """

// Firma fija (la clave llega desde los Secrets del repo)
System.getenv("MGD_KEYSTORE_PATH")?.let { ks ->
    android {
        signingConfigs {
            create("mgd") {
                storeFile = file(ks)
                storePassword = System.getenv("MGD_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MGD_KEY_ALIAS")
                keyPassword = System.getenv("MGD_KEYSTORE_PASSWORD")
            }
        }
        buildTypes {
            getByName("release") { signingConfig = signingConfigs.getByName("mgd") }
        }
    }
}
"""


DESUGAR = """

// Notificaciones (flutter_local_notifications necesita desugaring)
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
    }
}
dependencies {
    "coreLibraryDesugaring"("com.android.tools:desugar_jdk_libs:2.1.4")
}
"""


def desugar():
    g = "android/app/build.gradle.kts"
    s = open(g, encoding="utf-8").read()
    if "isCoreLibraryDesugaringEnabled" not in s:
        open(g, "a", encoding="utf-8").write(DESUGAR)
        print(f"OK {g}")


def signing():
    g = "android/app/build.gradle.kts"
    s = open(g, encoding="utf-8").read()
    if "MGD_KEYSTORE_PATH" not in s:
        open(g, "a", encoding="utf-8").write(SIGNING)
        print(f"OK {g}")


def web():
    i = "web/index.html"
    patch(i, "</head>", HEAD_SCRIPT)
    patch(i, BOOT_OLD, BOOT_NEW)


if __name__ == "__main__":
    {"android": android, "web": web, "signing": signing}[sys.argv[1]]()
