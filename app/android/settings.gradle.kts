pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // 国内镜像优先：dl.google.com / repo1.maven.org 本机直连超时（curl 000），
        // maven.aliyun.com 实测可达。原仓库保留为兜底。
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 从 9.1.0 降到 8.13.0：AGP 9.x 固定要用 Build Tools 36.0.0，本机只有
    // 35.0.0，且 dl.google.com 直连不通、各镜像（tencent/nju/tuna/bfsu/huawei/
    // aliyun/sjtu/ustc/pku）均无 36 的包；AGP 8.13.0 默认即 35.0.0。
    id("com.android.application") version "8.13.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
