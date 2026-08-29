plugins {
    id("com.android.library")
}

val pluginName = "RaceGlyphNearby"
val pluginPackageName = "com.raceglyph.nearby"

android {
    namespace = pluginPackageName
    compileSdk = 36

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        minSdk = 24
        manifestPlaceholders["godotPluginName"] = pluginName
        manifestPlaceholders["godotPluginPackageName"] = pluginPackageName
        buildConfigField("String", "GODOT_PLUGIN_NAME", "\"$pluginName\"")
        setProperty("archivesBaseName", pluginName)
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("org.godotengine:godot:4.7.1.stable")
    implementation("com.google.android.gms:play-services-nearby:19.4.0")
}
