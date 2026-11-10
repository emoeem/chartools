import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.chartools.chartools_app"
    // 本机 SDK 只装了 platform android-35 / build-tools 35.0.0，且各镜像
    // （tencent/nju/tuna/huawei）都没有 36 的包、dl.google.com 直连不通，
    // 故从 flutter.compileSdkVersion(36) 降到 35；采集插件同降。
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.chartools.chartools_app"
        // 采集插件（capture_android）声明 minSdk 30：无障碍 + 截屏组合在 30 以下
        // 不可用（见 packages/capture_android/android/build.gradle.kts），宿主必须跟上。
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 上传签名（正式）：CI 从环境变量拿（GitHub Secrets 里的 base64 jks），
        // 本机从 app/android/key.properties（gitignored，密钥本体在仓库外的
        // C:/Users/emo/chartools-keystore/，见其 README——丢了就无法同身份更新）。
        // 两者都没有时回退 debug 签名，保证干净机器上 flutter run --release 仍可用。
        create("upload") {
            val b64 = System.getenv("ANDROID_KEYSTORE_BASE64")
            val propsFile = rootProject.file("key.properties")
            if (b64 != null) {
                val ks = File(rootDir, "chartools-upload.jks")
                ks.writeBytes(Base64.getDecoder().decode(b64))
                storeFile = ks
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            } else if (propsFile.exists()) {
                val props = Properties().apply { propsFile.inputStream().use { load(it) } }
                storeFile = file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (signingConfigs.getByName("upload").storeFile != null)
                signingConfigs.getByName("upload")
            else signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
