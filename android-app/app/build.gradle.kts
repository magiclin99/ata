import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

/*
 * Upload-key signing. The keystore and its passwords live outside the repo and are never committed. The properties file
 * is found through, in order: Gradle property `ata.signing`, env ATA_SIGNING_PROPERTIES, then
 * ~/ata-secrets/android/signing.properties. Keys: storeFile, storePassword, keyAlias, keyPassword.
 * Without the file the release build is produced unsigned (CI and other machines still build).
 */
val signingProps: Properties? = run {
    val path = (findProperty("ata.signing") as String?)
        ?: System.getenv("ATA_SIGNING_PROPERTIES")
        ?: "${System.getProperty("user.home")}/ata-secrets/android/signing.properties"
    val f = file(path)
    if (f.isFile) Properties().apply { f.inputStream().use { load(it) } } else null
}

android {
    namespace = "io.github.magiclin99.ata"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "io.github.magiclin99.ata"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        // libwebrtc is native. The artifact ships arm64-v8a (16 KB-aligned) and armeabi-v7a; x86/x86_64 are
        // emulator/Chromebook only and are left out. Play delivers one ABI per device from the AAB.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }

        // Reserved voluntary-donation entry. SUPPORT_URL is empty by default, and while it
        // is empty nothing is shown anywhere. Even with a URL, the "Support ATA" row stays hidden unless
        // SHOW_SUPPORT_LINK is true. Keep it false for every Google Play build: Google Play's Payments policy has
        // been enforced against in-app links that send users to outside payment pages, donations included, so the
        // policy must be re-checked before this is ever turned on.
        // A donation never unlocks anything. Override for a non-Play build with
        // -Pata.supportUrl=https://… -Pata.showSupportLink=true.
        buildConfigField("String", "SUPPORT_URL", "\"${(findProperty("ata.supportUrl") as String?).orEmpty()}\"")
        buildConfigField("boolean", "SHOW_SUPPORT_LINK", (findProperty("ata.showSupportLink") as String?)?.toBoolean()?.toString() ?: "false")
    }

    signingConfigs {
        if (signingProps != null) {
            create("upload") {
                storeFile = file(signingProps.getProperty("storeFile"))
                storePassword = signingProps.getProperty("storePassword")
                keyAlias = signingProps.getProperty("keyAlias")
                keyPassword = signingProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("upload")
        }
    }

    bundle {
        // Language splits stay on so each install gets only zh-TW or en strings; ABI and density splits as default.
        language { enableSplit = true }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += listOf("META-INF/*.kotlin_module", "META-INF/versions/**", "DebugProbesKt.bin")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))

    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    implementation(platform("androidx.compose:compose-bom:2025.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.compose.ui:ui-tooling-preview")

    // Pairing QR code: CameraX preview + ZXing decoder, entirely on device (no ML Kit / Play services SDK, which
    // would send Google diagnostics). CAMERA is requested only when the user taps "Scan QR code".
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    implementation("com.google.zxing:core:3.5.4")
    // Google libwebrtc packaged by Stream (org.webrtc API); device-verified in the v1 lab.
    implementation("io.getstream:stream-webrtc-android:1.3.10")

    testImplementation("junit:junit:4.13.2")
}
