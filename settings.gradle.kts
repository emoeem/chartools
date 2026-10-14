pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // legacy Xposed API (`de.robv.android.xposed:api:82`) 只发在官方仓库，
        // 这两个聚合源都没有。它只是 compileOnly，运行期由 Vector 注入。
        maven("https://api.xposed.info/")
    }
}

rootProject.name = "jev-android"
include(":app")
