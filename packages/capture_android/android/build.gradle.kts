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
}
