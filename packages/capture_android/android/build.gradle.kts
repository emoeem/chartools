group = "dev.chartools.capture_android"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        // 国内镜像优先（dl.google.com / repo1.maven.org 本机直连超时），原仓库兜底。
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }

    dependencies {
        // 与 app/android/settings.gradle.kts 保持一致（AGP 8.13.0，Build Tools 35.0.0）。
        classpath("com.android.tools.build:gradle:8.13.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        // 国内镜像优先（同 buildscript）。
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.chartools.capture_android"

    // 与宿主 App 保持一致：本机只有 android-35 / build-tools 35.0.0 可用
    // （镜像无 36 包、dl.google.com 直连不通），见 app/android/app/build.gradle.kts。
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    // M0 桥 AIDL：AGP 8 起默认关闭（aidl=false），IBridgeConnection.aidl 编译需要。
    // （owner 批准的一次性例外：本文件原不在 M0 接收端写手的独占清单内，仅此
    // 一项，其余配置一律未动。）
    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        // 旧仓库 minSdk 30：无障碍 + MediaProjection 的组合在 30 以下不可用。
        minSdk = 30
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            // fix(kimi-review 循环)：ConfigureReplayTest 等测试触到 android.util.Log /
            // SystemClock 等 framework 桩——单测环境没有真实实现，缺这个开关就是
            // "Method ... not mocked" RuntimeException。
            isReturnDefaultValues = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 旧仓库同款离线中文 OCR（APK 体积 +15MB 左右）。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
    // 真实 org.json 只上测试类路径（legacy cn/app/build.gradle.kts:102-105 同款）；
    // M0 桥 Payload 往返测试需要（单测跑在 mockable android.jar 上，org.json 是
    // 桩，SnapshotConfidenceContractTest 尾注记录过这堵墙）。owner 批准的单行例外。
    testImplementation("org.json:json:20240303")
}
