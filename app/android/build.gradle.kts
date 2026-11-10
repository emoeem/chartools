allprojects {
    repositories {
        // 国内镜像优先（dl.google.com / repo1.maven.org 本机直连超时），原仓库兜底。
        // Flutter 引擎构件（io.flutter:*）只在这里有镜像，aliyun google 不收
        // 这个 group（实测 404）——与 flutter 工具自身配置的 storage.flutter-io.cn 一致。
        maven("https://storage.flutter-io.cn/download.flutter.io")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    // pub 缓存里的插件各自在 buildscript 里写死 google()/mavenCentral()：
    // dl.google.com / repo1.maven.org 本机直连超时，把 aliyun 镜像插到最前面
    // （先于插件自带的仓库生效），原仓库留作兜底。与 settings.gradle.kts 的
    // pluginManagement 镜像同一批。
    buildscript {
        repositories {
            maven("https://maven.aliyun.com/repository/google")
            maven("https://maven.aliyun.com/repository/public")
            maven("https://maven.aliyun.com/repository/gradle-plugin")
        }
    }
    // 本机 SDK 只装了 platform android-35（镜像无 36 的包、dl.google.com
    // 直连不通），而 pub 缓存插件的 android{} 跟 flutter.compileSdkVersion(36)
    // 走。与 :app「compileSdk 降到 35」（app/build.gradle.kts 注释）、采集插件
    // 同降（capture_android/build.gradle.kts）一致，把库子项目的 compileSdk
    // 压回 35。afterEvaluate 必须在下面 evaluationDependsOn 把 :app 提前
    // 评估之前注册，所以和上面的配置合在同一个 subprojects 块里。
    afterEvaluate {
        val android = extensions.findByName("android")
            as? com.android.build.gradle.LibraryExtension
        if (android != null && (android.compileSdk ?: 0) > 35) {
            android.compileSdk = 35
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
