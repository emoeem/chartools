import java.io.File
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing: reads a properties file kept OUTSIDE the repo
// (storeFile / storePassword / keyAlias / keyPassword). Override the path with
// the JEV_KEYSTORE_PROPS env var. Without it, release builds are unsigned.
val releaseProps = Properties().apply {
    System.getenv("JEV_KEYSTORE_PROPS")?.takeIf { it.isNotBlank() }?.let { path ->
        val f = File(path)
        require(f.isFile) { "JEV_KEYSTORE_PROPS does not point to a file: $path" }
        FileInputStream(f).use { load(it) }
    }
}

android {
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
    namespace = "com.jev.probe"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.jev.probe"
        minSdk = 30
        targetSdk = 35
        versionCode = 10
        versionName = "2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // ML Kit's bundled Chinese recognizer ships native libs for every ABI.
        // The target phone (and every phone this can run on: minSdk 30) is
        // arm64, so keep only that one — the other three are dead weight.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        if (releaseProps.isNotEmpty()) {
            create("release") {
                storeFile = file(releaseProps.getProperty("storeFile"))
                storePassword = releaseProps.getProperty("storePassword")
                keyAlias = releaseProps.getProperty("keyAlias")
                keyPassword = releaseProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }

    // Uncompressed, page-aligned .so files: required for the 16 KB page-size
    // devices Android 15+ ships, and it lets the loader mmap the ML Kit natives
    // instead of unpacking them at install time.
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        // 跨进程桥的备用通道是一条 AIDL 绑定（Provider 取不到的机型上用它）。
        // 接口与两条通道共用，见 app/src/main/aidl/…/IBridgeConnection.aidl。
        aidl = true
        // 模块侧报到的版本号用 BuildConfig.VERSION_NAME。它必须在编译期生成：
        // 注入代码跑在目标 App 的进程里，包可见性挡掉了 getPackageInfo，
        // 而查宿主 Context 拿到的是宿主的版本号（两版都错过，见 JevHookEntry）。
        buildConfig = true
    }
}

dependencies {
    // 可选注入层（S2 起）：模块入口类实现 IXposedHookLoadPackage。
    // compileOnly —— 运行期这两个 API 由 Vector/LSPosed 注入到目标进程，
    // 本 App 自己的进程里没有它们，所以永远不能在主进程里加载该入口类。
    // `com.jev.probe.module` 包是唯一 import de.robv.android.xposed 的地方，
    // 其余（bridge / capture / core）两个进程都能安全加载。
    compileOnly("de.robv.android.xposed:api:82")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    // Unit tests run against android.jar, where org.json is a stub that throws
    // "not mocked". The JSON round trip is most of the judgment logic, so the
    // real implementation goes on the test classpath only (never in the APK).
    testImplementation("org.json:json:20240303")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    // 专家库的 2 列网格要它。显式钉版本：此前没人声明，RecyclerView 靠 material
    // 传递解析成 1.0.0→1.1.0（2019 年），网格组件的版本等于由别人的 pom 决定。
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    // On-device OCR. The *bundled* Chinese model (not the play-services variant):
    // it works on phones with no Google Play services and needs no model download.
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")

    // PDF *text layer* extraction (digital PDFs). Pure Java, and the AAR ships
    // zero .so files, so it composes with abiFilters = ["arm64-v8a"] without
    // adding an ABI. BouncyCastle is a compile-scope dependency in its POM that
    // exists only for encrypted/signed PDFs; this app never opens those, and it
    // would pull ~11 MB of jars into the APK, so it is excluded here.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0") {
        exclude(group = "org.bouncycastle")
    }
    // HTML → text. Charset sniffing on malformed real-world markup is the whole
    // value; a hand-rolled tag stripper gets encodings wrong.
    implementation("org.jsoup:jsoup:1.21.1")

    // HTTP. Replaces the bare HttpURLConnection in HttpJson for one concrete
    // reason: Call.cancel() really closes the socket, while Future.cancel(true)
    // only interrupts the thread — a wedged read used to hold its round's thread
    // until the read timeout. okhttp-sse is the same client's SSE front end,
    // used by the opt-in streaming candidate path.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:okhttp-sse:4.12.0")
    // MockWebServer gives HttpJson's retry / status / cancel rules a real server
    // to talk to on the JVM. Test classpath only.
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")

    // Unit tests run on the JVM, where android.util.Xml is a "not mocked" stub.
    // kxml2 is the parser Android's Xml.newPullParser() actually wraps, so the
    // DOCX/ODT/EPUB/PPTX/XLSX extractors are exercised for real in tests.
    // Test classpath only — nothing here reaches the APK.
    testImplementation("net.sf.kxml:kxml2:2.3.0")
    testImplementation("xmlpull:xmlpull:1.1.3.1")
}

// tools/jev/eval_aiming.py drives the live half of the aiming evaluation through
// this module's own tests, so the prompts it posts are exactly the prompts the app
// builds (one assembler, in ReplyPrompt). `-Daiming.dump=<path>` has to be forwarded
// to the test JVM by hand: Gradle's own -D only reaches the daemon, and a dump that
// silently never happened would make the live run look like it tested the app when
// it did not.
// tools/jev/eval_roleplay.py does the same thing for the multi-turn role-play
// suite, but its rounds are not known until the driver has seen how the previous
// one was answered. So it hands over a batch of rounds and takes back the two
// halves: -Droleplay.in / -Droleplay.out. Same reasoning as the dump above —
// forwarded by hand, because a replay that silently never happened would let the
// live run report on prompts nobody sent.
// Its --ledger arm needs a second prompt that also has exactly one copy in the
// app (LedgerPrompt), so -Dledger.in / -Dledger.out is the same hand-over for the
// session ledger. Two properties, one test file, no second assembler.
tasks.withType<Test>().configureEach {
    // ChatAppsRegistryTest 从这里定位模块内的 res / manifest，钳住注册表与
    // xposed_scope / <queries> 之间的同步（同 global/core 的 jev.fixtures 先例）。
    systemProperty("jev.moduleDir", projectDir.absolutePath)
    System.getProperty("aiming.dump")?.let { systemProperty("aiming.dump", it) }
    System.getProperty("roleplay.in")?.let { systemProperty("roleplay.in", it) }
    System.getProperty("roleplay.out")?.let { systemProperty("roleplay.out", it) }
    System.getProperty("ledger.in")?.let { systemProperty("ledger.in", it) }
    System.getProperty("ledger.out")?.let { systemProperty("ledger.out", it) }
    // tools/jev/eval_kb_effect.py: 「注入了知识库之后回复会不会变」的实况 A/B。
    // 它需要 app 自己的检索（ContextBuilder.matchNotes）和拼装（ReplyPrompt）各出一份
    // 带笔记 / 不带笔记的提示词 —— 自己拼一份就会在 app 的提示词改了之后继续通过。
    System.getProperty("kbeffect.kb")?.let { systemProperty("kbeffect.kb", it) }
    System.getProperty("kbeffect.in")?.let { systemProperty("kbeffect.in", it) }
    System.getProperty("kbeffect.out")?.let { systemProperty("kbeffect.out", it) }
    // Optional fourth arm: one pre-scanned 「领域卡」 note instead of the raw BM25
    // hits, to test whether a summary beats pasting chunks. Absent = three arms.
    System.getProperty("kbeffect.summary")?.let { systemProperty("kbeffect.summary", it) }
    // A dump run is a request for fresh output, and Gradle does not track the
    // values of system properties as task inputs: without this the second dump
    // in the same build is UP-TO-DATE and the caller quietly reads a stale file.
    if (System.getProperty("aiming.dump") != null ||
        System.getProperty("roleplay.in") != null ||
        System.getProperty("ledger.in") != null ||
        System.getProperty("kbeffect.in") != null
    ) {
        outputs.upToDateWhen { false }
    }
}
